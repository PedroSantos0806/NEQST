/**
 * POST   /functions/v1/register-web-push   (versão web)
 * Body:  a PushSubscription do navegador, como vem de
 *        `registration.pushManager.subscribe().toJSON()`:
 *        { endpoint, keys: { p256dh, auth } }
 *
 * DELETE /functions/v1/register-web-push
 * Body:  { endpoint }   — o usuário revogou a permissão ou deslogou
 *
 * GET    /functions/v1/register-web-push
 *        Devolve a chave pública VAPID, que o front precisa para
 *        chamar subscribe({ applicationServerKey }).
 */
import { ApiError, json, readJson, requireEnv, serve } from "../_shared/http.ts";
import { requireUser, serviceClient } from "../_shared/supabase.ts";

interface SubscriptionBody {
  endpoint?: string;
  keys?: { p256dh?: string; auth?: string };
  // Formato achatado também é aceito, por conveniência do front.
  p256dh?: string;
  auth?: string;
}

const B64URL = /^[A-Za-z0-9_-]+$/;

serve(async (req) => {
  // A chave pública VAPID é pública por definição — fica antes do login
  // para o service worker poder se registrar no primeiro acesso.
  if (req.method === "GET") {
    return json({ publicKey: requireEnv("VAPID_PUBLIC_KEY") });
  }

  if (req.method !== "POST" && req.method !== "DELETE") {
    throw new ApiError("METHOD_NOT_ALLOWED", "Use GET, POST ou DELETE nesta rota.", 405);
  }

  const { user } = await requireUser(req);
  const body = await readJson<SubscriptionBody>(req);
  const admin = serviceClient();

  const endpoint = body.endpoint?.trim();
  if (!endpoint || !/^https:\/\//.test(endpoint)) {
    throw new ApiError("INVALID_SUBSCRIPTION", "endpoint da subscription inválido.", 400);
  }

  if (req.method === "DELETE") {
    const { error } = await admin
      .from("web_push_subscriptions")
      .update({ is_active: false })
      .eq("endpoint", endpoint)
      .eq("user_id", user.id);

    if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);
    return json({ endpoint, active: false });
  }

  const p256dh = body.keys?.p256dh ?? body.p256dh;
  const auth = body.keys?.auth ?? body.auth;

  if (!p256dh || !auth || !B64URL.test(p256dh) || !B64URL.test(auth)) {
    throw new ApiError(
      "INVALID_SUBSCRIPTION",
      "As chaves p256dh e auth são obrigatórias em base64url.",
      400,
    );
  }

  // O mesmo navegador pode trocar de conta: o endpoint é a identidade.
  const { data, error } = await admin
    .from("web_push_subscriptions")
    .upsert(
      {
        endpoint,
        user_id: user.id,
        p256dh,
        auth,
        user_agent: req.headers.get("User-Agent")?.slice(0, 300) ?? null,
        is_active: true,
        failure_count: 0,
        last_seen_at: new Date().toISOString(),
      },
      { onConflict: "endpoint" },
    )
    .select("id, endpoint, is_active, created_at")
    .single();

  if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);

  return json(data, 201);
});
