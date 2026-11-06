/**
 * GET /functions/v1/queue-status?courtId=<uuid>   (US-03 / US-04)
 * GET /functions/v1/queue-status?slug=<slug>
 *
 * Fallback de polling para quando o WebSocket do Realtime cair.
 * Resposta cacheável por 10s (o app também cacheia a quadra por 60s).
 */
import { ApiError, postgrestError, requireMethod, requireUuid, serve } from "../_shared/http.ts";
import { anonClient } from "../_shared/supabase.ts";

serve(async (req) => {
  requireMethod(req, "GET");

  const url = new URL(req.url);
  const courtIdParam = url.searchParams.get("courtId");
  const slug = url.searchParams.get("slug");

  if (!courtIdParam && !slug) {
    throw new ApiError("COURT_REQUIRED", "Informe courtId ou slug.", 400);
  }

  // Leitura pública: a chave anônima basta. Com service_role, qualquer
  // bug futuro nesta rota passaria por cima de RLS — e esta é uma das
  // três rotas que atendem sem JWT nenhum.
  const client = anonClient();
  let courtId = courtIdParam ? requireUuid(courtIdParam, "courtId") : null;

  if (!courtId && slug) {
    const { data, error } = await client
      .from("courts")
      .select("id")
      .eq("slug", slug)
      .maybeSingle();

    if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);
    if (!data) throw new ApiError("COURT_NOT_FOUND", "Quadra não encontrada.", 404);
    courtId = data.id;
  }

  const { data, error } = await client.rpc("court_queue", { p_court_id: courtId });
  if (error) postgrestError(error);

  // Sem os cabeçalhos de CORS aqui: quem resolve a origem é o wrapper
  // `serve()`, e repetir a constante permissiva neste lugar foi o que
  // deixou outra função respondendo `*` por meses.
  return new Response(JSON.stringify(data), {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=10",
    },
  });
});
