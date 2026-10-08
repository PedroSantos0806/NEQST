/**
 * Upload de fotos da quadra (Sprint 2).
 *
 * POST /functions/v1/court-photo
 *   { courtId, contentType?, caption? }
 *   -> { photoId, uploadUrl, storagePath, token }
 *
 *   Devolve uma URL assinada de upload. O arquivo vai direto do device
 *   para o Storage, sem passar pela função — o que mantém o custo e o
 *   tempo de resposta baixos no 3G, e funciona igual na web e no app.
 *
 * POST /functions/v1/court-photo?action=confirm
 *   { photoId, sizeBytes?, width?, height? }
 *   -> marca a foto como enviada e a coloca na fila de moderação.
 *
 * GET /functions/v1/court-photo?courtId=<uuid>
 *   -> fotos aprovadas, já com URL assinada de leitura.
 *
 * GET /functions/v1/court-photo?courtIds=<uuid>,<uuid>,...
 *   -> só as capas, assinadas, para a lista de quadras e o mapa de calor
 *      (evita uma chamada por quadra na tela inicial).
 */
import { ApiError, json, postgrestError, readJson, serve } from "../_shared/http.ts";
import { requireUser, serviceClient } from "../_shared/supabase.ts";

const BUCKET = "court-photos";
const READ_URL_TTL_SECONDS = 3600;
const UPLOAD_URL_TTL_SECONDS = 300;

const ALLOWED_TYPES: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

interface CreateBody {
  courtId?: string;
  contentType?: string;
  caption?: string | null;
}

interface ConfirmBody {
  photoId?: string;
  sizeBytes?: number;
  width?: number;
  height?: number;
}

interface PhotoRow {
  id: string;
  storage_path: string;
  caption: string | null;
  width: number | null;
  height: number | null;
  is_primary: boolean;
  created_at: string;
}

serve(async (req) => {
  const url = new URL(req.url);
  const admin = serviceClient();

  // -------------------------------------------------------------------
  // GET — fotos aprovadas de uma quadra, com URL assinada
  // -------------------------------------------------------------------
  if (req.method === "GET") {
    // Capas de várias quadras de uma vez.
    const courtIds = url.searchParams.get("courtIds");
    if (courtIds) {
      const ids = courtIds.split(",").map((id) => id.trim()).filter(Boolean).slice(0, 100);
      if (ids.length === 0) throw new ApiError("COURT_REQUIRED", "Informe courtIds.", 400);

      const { data: courts, error } = await admin
        .from("courts")
        .select("id, cover_photo_path")
        .in("id", ids)
        .not("cover_photo_path", "is", null)
        .returns<Array<{ id: string; cover_photo_path: string }>>();

      if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);

      const paths = (courts ?? []).map((court) => court.cover_photo_path);
      const signedCovers = paths.length > 0
        ? (await admin.storage.from(BUCKET).createSignedUrls(paths, READ_URL_TTL_SECONDS)).data ??
          []
        : [];
      const signedByPath = new Map(signedCovers.map((item) => [item.path ?? "", item.signedUrl]));

      return json({
        covers: Object.fromEntries(
          (courts ?? []).map((court) => [
            court.id,
            signedByPath.get(court.cover_photo_path) ?? null,
          ]),
        ),
        expiresInSeconds: READ_URL_TTL_SECONDS,
      });
    }

    const courtId = url.searchParams.get("courtId");
    if (!courtId) throw new ApiError("COURT_REQUIRED", "Informe courtId ou courtIds.", 400);

    const { data, error } = await admin.rpc("court_photos_page", {
      p_court_id: courtId,
      p_limit: Number(url.searchParams.get("limit") ?? 20),
    });
    if (error) postgrestError(error);

    const photos = (data ?? []) as Array<Record<string, unknown>>;
    const paths = photos.map((photo) => String(photo.storage_path));

    const signed = paths.length > 0
      ? (await admin.storage.from(BUCKET).createSignedUrls(paths, READ_URL_TTL_SECONDS)).data ?? []
      : [];

    const urlByPath = new Map(signed.map((item) => [item.path ?? "", item.signedUrl]));

    return json({
      courtId,
      photos: photos.map((photo) => ({
        ...photo,
        url: urlByPath.get(String(photo.storage_path)) ?? null,
      })),
      expiresInSeconds: READ_URL_TTL_SECONDS,
    });
  }

  if (req.method !== "POST") {
    throw new ApiError("METHOD_NOT_ALLOWED", "Use GET ou POST nesta rota.", 405);
  }

  const { user } = await requireUser(req);

  // -------------------------------------------------------------------
  // POST ?action=confirm — o upload terminou
  // -------------------------------------------------------------------
  if (url.searchParams.get("action") === "confirm") {
    const body = await readJson<ConfirmBody>(req);
    if (!body.photoId) throw new ApiError("PHOTO_ID_REQUIRED", "Informe photoId.", 400);

    const { data: photo, error: readError } = await admin
      .from("court_photos")
      .select("id, user_id, storage_path, is_uploaded")
      .eq("id", body.photoId)
      .maybeSingle<{ id: string; user_id: string; storage_path: string; is_uploaded: boolean }>();

    if (readError) throw new ApiError("DATABASE_ERROR", readError.message, 500);
    if (!photo) throw new ApiError("PHOTO_NOT_FOUND", "Foto não encontrada.", 404);
    if (photo.user_id !== user.id) {
      throw new ApiError("FORBIDDEN", "Esta foto é de outro usuário.", 403);
    }

    // Confia no Storage, não no cliente: só confirma se o objeto existe.
    const folder = photo.storage_path.split("/").slice(0, -1).join("/");
    const fileName = photo.storage_path.split("/").pop() ?? "";
    const { data: listed } = await admin.storage.from(BUCKET).list(folder, {
      search: fileName,
      limit: 1,
    });

    if (!listed || listed.length === 0) {
      throw new ApiError(
        "UPLOAD_NOT_FOUND",
        "O arquivo ainda não chegou ao Storage. Refaça o upload.",
        409,
      );
    }

    const { data: updated, error: updateError } = await admin
      .from("court_photos")
      .update({
        is_uploaded: true,
        size_bytes: body.sizeBytes ?? listed[0].metadata?.size ?? null,
        width: body.width ?? null,
        height: body.height ?? null,
      })
      .eq("id", photo.id)
      .select("id, court_id, status, storage_path")
      .single();

    if (updateError) throw new ApiError("DATABASE_ERROR", updateError.message, 500);

    return json({
      ...updated,
      message: "Foto enviada. Ela aparece no app depois da moderação.",
    });
  }

  // -------------------------------------------------------------------
  // POST — cria a linha e devolve a URL assinada de upload
  // -------------------------------------------------------------------
  const body = await readJson<CreateBody>(req);
  if (!body.courtId) throw new ApiError("COURT_REQUIRED", "Informe courtId.", 400);

  const contentType = body.contentType ?? "image/jpeg";
  const extension = ALLOWED_TYPES[contentType];
  if (!extension) {
    throw new ApiError(
      "UNSUPPORTED_MEDIA_TYPE",
      "Envie JPEG, PNG ou WebP.",
      415,
      { allowed: Object.keys(ALLOWED_TYPES) },
    );
  }

  const { data: court, error: courtError } = await admin
    .from("courts")
    .select("id")
    .eq("id", body.courtId)
    .maybeSingle();

  if (courtError) throw new ApiError("DATABASE_ERROR", courtError.message, 500);
  if (!court) throw new ApiError("COURT_NOT_FOUND", "Quadra não encontrada.", 404);

  const storagePath = `${body.courtId}/${crypto.randomUUID()}.${extension}`;

  const { data: photo, error: insertError } = await admin
    .from("court_photos")
    .insert({
      court_id: body.courtId,
      user_id: user.id,
      storage_path: storagePath,
      content_type: contentType,
      caption: body.caption?.trim() || null,
    })
    .select("id, court_id, storage_path, status, created_at")
    .single<PhotoRow & { court_id: string; status: string }>();

  if (insertError) postgrestError(insertError);

  const { data: upload, error: uploadError } = await admin.storage
    .from(BUCKET)
    .createSignedUploadUrl(storagePath, { upsert: false });

  if (uploadError || !upload) {
    // Sem URL de upload a linha é lixo: remove para não entupir a cota.
    await admin.from("court_photos").delete().eq("id", photo!.id);
    throw new ApiError("STORAGE_ERROR", uploadError?.message ?? "Falha ao preparar o upload.", 500);
  }

  return json({
    photoId: photo!.id,
    courtId: photo!.court_id,
    storagePath,
    uploadUrl: upload.signedUrl,
    token: upload.token,
    contentType,
    expiresInSeconds: UPLOAD_URL_TTL_SECONDS,
    next: "Faça PUT do arquivo em uploadUrl e chame ?action=confirm com o photoId.",
  }, 201);
});
