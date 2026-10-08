/**
 * POST /functions/v1/dispatch-notifications   (US-03 — "Prepare-se!")
 *
 * Worker do outbox: lê as notificações pendentes e entrega em dois
 * canais, porque o NEQST roda em dois lugares:
 *
 *   - app (Play Store / App Store) -> Expo Push API (FCM + APNs)
 *   - web (PWA no navegador)       -> Web Push (RFC 8291 + VAPID)
 *
 * Uma notificação conta como entregue se QUALQUER canal do usuário
 * aceitou — quem usa o app no celular e o site no notebook não recebe
 * duas vezes a mesma cobrança de reenvio.
 *
 * Deve ser chamado por cron (pg_cron) a cada ~10 segundos.
 * Autenticação: header `x-cron-secret` = CRON_SECRET.
 */
import { ApiError, json, requireEnv, requireMethod, serve } from "../_shared/http.ts";
import { type ExpoPushMessage, isUnregisteredTicket, sendExpoPush } from "../_shared/expo.ts";
import { sendWebPush, type VapidKeys, WebPushError } from "../_shared/webpush.ts";
import { serviceClient } from "../_shared/supabase.ts";
import type { OutboxRow, PushTokenRow } from "../_shared/types.ts";

const MAX_BATCH = 200;
const MAX_ATTEMPTS = 5;

interface WebPushRow {
  id: string;
  user_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
}

/** Null quando o projeto não configurou VAPID (ambiente só-app). */
function vapidKeys(): VapidKeys | null {
  const publicKey = Deno.env.get("VAPID_PUBLIC_KEY");
  const privateKey = Deno.env.get("VAPID_PRIVATE_KEY");
  const subject = Deno.env.get("VAPID_SUBJECT");

  if (!publicKey || !privateKey || !subject) return null;
  return { publicKey, privateKey, subject };
}

serve(async (req) => {
  requireMethod(req, "POST");

  if (req.headers.get("x-cron-secret") !== requireEnv("CRON_SECRET")) {
    throw new ApiError("FORBIDDEN", "Chamada não autorizada.", 403);
  }

  const admin = serviceClient();

  const { data: pending, error: pendingError } = await admin
    .from("notification_outbox")
    .select("id, user_id, entry_id, court_id, type, title, body, data, attempts")
    .eq("status", "pending")
    .lte("scheduled_for", new Date().toISOString())
    .lt("attempts", MAX_ATTEMPTS)
    .order("scheduled_for", { ascending: true })
    .limit(MAX_BATCH)
    .returns<OutboxRow[]>();

  if (pendingError) throw new ApiError("DATABASE_ERROR", pendingError.message, 500);
  if (!pending || pending.length === 0) {
    return json({ processed: 0, sent: 0, failed: 0 });
  }

  const userIds = [...new Set(pending.map((row) => row.user_id))];

  // Canais de cada usuário.
  const [tokensResult, subscriptionsResult] = await Promise.all([
    admin
      .from("push_tokens")
      .select("user_id, token")
      .in("user_id", userIds)
      .eq("is_active", true)
      .returns<PushTokenRow[]>(),
    admin
      .from("web_push_subscriptions")
      .select("id, user_id, endpoint, p256dh, auth")
      .in("user_id", userIds)
      .eq("is_active", true)
      .returns<WebPushRow[]>(),
  ]);

  if (tokensResult.error) throw new ApiError("DATABASE_ERROR", tokensResult.error.message, 500);
  if (subscriptionsResult.error) {
    throw new ApiError("DATABASE_ERROR", subscriptionsResult.error.message, 500);
  }

  const tokensByUser = new Map<string, string[]>();
  for (const row of tokensResult.data ?? []) {
    tokensByUser.set(row.user_id, [...(tokensByUser.get(row.user_id) ?? []), row.token]);
  }

  const subsByUser = new Map<string, WebPushRow[]>();
  for (const row of subscriptionsResult.data ?? []) {
    subsByUser.set(row.user_id, [...(subsByUser.get(row.user_id) ?? []), row]);
  }

  const delivered = new Set<string>();
  const failures = new Map<string, string>();
  const withoutChannel: string[] = [];
  const deadTokens: string[] = [];
  const deadSubscriptions: string[] = [];

  // -------------------------------------------------------------------
  // Canal 1 — Expo Push (app nativo)
  // -------------------------------------------------------------------
  const messages: ExpoPushMessage[] = [];
  const messageOutbox: string[] = [];
  const messageToken: string[] = [];

  for (const row of pending) {
    const tokens = tokensByUser.get(row.user_id) ?? [];
    const subs = subsByUser.get(row.user_id) ?? [];

    if (tokens.length === 0 && subs.length === 0) {
      withoutChannel.push(row.id);
      continue;
    }

    for (const token of tokens) {
      messages.push({
        to: token,
        title: row.title,
        body: row.body,
        sound: "default",
        priority: "high",
        channelId: "queue",
        ttl: 900,
        data: { ...row.data, type: row.type, entryId: row.entry_id, courtId: row.court_id },
      });
      messageOutbox.push(row.id);
      messageToken.push(token);
    }
  }

  if (messages.length > 0) {
    try {
      const tickets = await sendExpoPush(messages, Deno.env.get("EXPO_ACCESS_TOKEN") ?? undefined);

      tickets.forEach((ticket, index) => {
        const outboxId = messageOutbox[index];
        if (ticket.status === "ok") {
          delivered.add(outboxId);
        } else {
          failures.set(outboxId, ticket.message ?? "expo_unknown_error");
          if (isUnregisteredTicket(ticket)) deadTokens.push(messageToken[index]);
        }
      });
    } catch (error) {
      // Expo fora do ar não derruba o canal web: registra e segue.
      console.error("expo_push_failed", error);
      for (const outboxId of messageOutbox) {
        failures.set(outboxId, `expo: ${String(error).slice(0, 200)}`);
      }
    }
  }

  // -------------------------------------------------------------------
  // Canal 2 — Web Push (navegador)
  // -------------------------------------------------------------------
  const vapid = vapidKeys();

  if (vapid) {
    const sends: Array<Promise<void>> = [];

    for (const row of pending) {
      for (const sub of subsByUser.get(row.user_id) ?? []) {
        const payload = JSON.stringify({
          title: row.title,
          body: row.body,
          data: { ...row.data, type: row.type, entryId: row.entry_id, courtId: row.court_id },
        });

        sends.push(
          sendWebPush(sub, payload, vapid)
            .then(() => {
              delivered.add(row.id);
            })
            .catch((error: unknown) => {
              failures.set(row.id, `webpush: ${String(error).slice(0, 200)}`);
              if (error instanceof WebPushError && error.isGone) {
                deadSubscriptions.push(sub.id);
              }
            }),
        );
      }
    }

    await Promise.all(sends);
  } else if (subsByUser.size > 0) {
    console.warn("web_push_skipped: VAPID não configurado neste ambiente");
    for (const row of pending) {
      if ((subsByUser.get(row.user_id) ?? []).length > 0 && !delivered.has(row.id)) {
        failures.set(row.id, "vapid_not_configured");
      }
    }
  }

  // -------------------------------------------------------------------
  // Resultado
  // -------------------------------------------------------------------

  // Entregue em um canal basta: tira da lista de falhas.
  for (const id of delivered) failures.delete(id);

  if (withoutChannel.length > 0) {
    await admin
      .from("notification_outbox")
      .update({ status: "failed", last_error: "no_active_push_channel", attempts: MAX_ATTEMPTS })
      .in("id", withoutChannel);
  }

  if (delivered.size > 0) {
    await admin
      .from("notification_outbox")
      .update({ status: "sent", sent_at: new Date().toISOString() })
      .in("id", [...delivered]);
  }

  for (const [id, message] of failures) {
    await admin.rpc("increment_notification_attempts", { p_ids: [id], p_error: message });
  }

  if (deadTokens.length > 0) {
    await admin.from("push_tokens").update({ is_active: false }).in("token", deadTokens);
  }

  if (deadSubscriptions.length > 0) {
    await admin
      .from("web_push_subscriptions")
      .update({ is_active: false })
      .in("id", deadSubscriptions);
  }

  return json({
    processed: pending.length,
    sent: delivered.size,
    failed: failures.size + withoutChannel.length,
    channels: {
      expo_messages: messages.length,
      web_push_subscriptions: [...subsByUser.values()].reduce((sum, list) => sum + list.length, 0),
      vapid_configured: vapid !== null,
    },
    deactivated: { push_tokens: deadTokens.length, web_push: deadSubscriptions.length },
  });
});
