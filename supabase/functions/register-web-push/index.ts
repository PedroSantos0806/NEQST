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
import { PushEndpointError, requirePushEndpoint } from "../_shared/webpush.ts";

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

  let endpoint: string;
  try {
    endpoint = requirePushEndpoint(body.endpoint);
  } catch (cause) {
    if (cause instanceof PushEndpointError) {
      throw new ApiError(
        "INVALID_SUBSCRIPTION",
        "endpoint da subscription não é de um serviço de push conhecido.",
        400,
      );
    }
    throw cause;
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
  //
  // Mas o endpoint sozinho não prova que a chamada vem DAQUELE
  // navegador — ele aparece em log, em banco, em captura de rede. Quem
  // soubesse o endpoint de outra pessoa reescrevia o user_id para si: a
  // vítima parava de receber "É a sua vez!" e perdia a vaga, e as
  // notificações do atacante chegavam no aparelho dela.
  //
  // As chaves p256dh/auth são o segredo do aparelho, e `subscribe()` com
  // a mesma applicationServerKey devolve sempre as mesmas: a troca de
  // conta legítima apresenta chaves idênticas, e quem só tem o endpoint
  // não tem como apresentá-las.
  const { data: existing, error: lookupError } = await admin
    .from("web_push_subscriptions")
    .select("user_id, p256dh, auth")
    .eq("endpoint", endpoint)
    .maybeSingle();

  if (lookupError) throw new ApiError("DATABASE_ERROR", lookupError.message, 500);

  if (existing && existing.user_id !== user.id) {
    if (existing.p256dh !== p256dh || existing.auth !== auth) {
      throw new ApiError(
        "SUBSCRIPTION_NOT_YOURS",
        "Esta inscrição de push é de outro aparelho.",
        403,
      );
    }
  }

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
