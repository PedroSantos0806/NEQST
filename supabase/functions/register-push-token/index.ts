/**
 * POST   /functions/v1/register-push-token   (US-03 — push)
 * Body:  { token: string, platform: "ios"|"android"|"web", deviceName?: string }
 *
 * DELETE /functions/v1/register-push-token
 * Body:  { token: string }   — logout / revogação do device
 */
import { ApiError, errorResponse, handlePreflight, json, readJson } from "../_shared/http.ts";
import { requireUser, serviceClient } from "../_shared/supabase.ts";

interface TokenRequest {
  token?: string;
  platform?: "ios" | "android" | "web";
  deviceName?: string | null;
}

const EXPO_TOKEN_RE = /^(ExponentPushToken\[.+\]|ExpoPushToken\[.+\])$/;

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    if (req.method !== "POST" && req.method !== "DELETE") {
      throw new ApiError("METHOD_NOT_ALLOWED", "Use POST ou DELETE nesta rota.", 405);
    }

    const { user } = await requireUser(req);
    const body = await readJson<TokenRequest>(req);
    const admin = serviceClient();

    if (!body.token || !EXPO_TOKEN_RE.test(body.token)) {
      throw new ApiError("INVALID_PUSH_TOKEN", "Token de push inválido.", 400);
    }

    if (req.method === "DELETE") {
      const { error } = await admin
        .from("push_tokens")
        .update({ is_active: false })
        .eq("token", body.token)
        .eq("user_id", user.id);

      if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);
      return json({ token: body.token, active: false });
    }

    if (!body.platform || !["ios", "android", "web"].includes(body.platform)) {
      throw new ApiError("INVALID_PLATFORM", "platform deve ser ios, android ou web.", 400);
    }

    // Um mesmo device pode trocar de dono (troca de conta no app).
    const { data, error } = await admin
      .from("push_tokens")
      .upsert(
        {
          token: body.token,
          user_id: user.id,
          platform: body.platform,
          device_name: body.deviceName ?? null,
          is_active: true,
          last_seen_at: new Date().toISOString(),
        },
        { onConflict: "token" },
      )
      .select("id, token, platform, is_active")
      .single();

    if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);

    return json(data, 201);
  } catch (error) {
    return errorResponse(error);
  }
});
