/**
 * POST /functions/v1/dispatch-notifications   (US-03 — "Prepare-se!")
 *
 * Worker do outbox: lê as notificações pendentes, envia via Expo Push
 * (FCM + APNs) e marca o resultado. Deve ser chamado por cron
 * (pg_cron / Supabase Scheduled Function) a cada ~10 segundos.
 *
 * Autenticação: header `x-cron-secret` = CRON_SECRET.
 */
import {
  ApiError,
  errorResponse,
  handlePreflight,
  json,
  requireEnv,
  requireMethod,
} from "../_shared/http.ts";
import { type ExpoPushMessage, isUnregisteredTicket, sendExpoPush } from "../_shared/expo.ts";
import { serviceClient } from "../_shared/supabase.ts";
import type { OutboxRow, PushTokenRow } from "../_shared/types.ts";

const MAX_BATCH = 200;
const MAX_ATTEMPTS = 5;

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
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

    const { data: tokens, error: tokensError } = await admin
      .from("push_tokens")
      .select("user_id, token")
      .in("user_id", userIds)
      .eq("is_active", true)
      .returns<PushTokenRow[]>();

    if (tokensError) throw new ApiError("DATABASE_ERROR", tokensError.message, 500);

    const tokensByUser = new Map<string, string[]>();
    for (const row of tokens ?? []) {
      const list = tokensByUser.get(row.user_id) ?? [];
      list.push(row.token);
      tokensByUser.set(row.user_id, list);
    }

    const messages: ExpoPushMessage[] = [];
    const messageOwner: string[] = []; // índice da mensagem -> id do outbox
    const messageToken: string[] = [];
    const withoutDevice: string[] = [];

    for (const row of pending) {
      const userTokens = tokensByUser.get(row.user_id) ?? [];

      if (userTokens.length === 0) {
        withoutDevice.push(row.id);
        continue;
      }

      for (const token of userTokens) {
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
        messageOwner.push(row.id);
        messageToken.push(token);
      }
    }

    // Sem device registrado não há o que reenviar: encerra sem erro.
    if (withoutDevice.length > 0) {
      await admin
        .from("notification_outbox")
        .update({ status: "failed", last_error: "no_active_push_token", attempts: 1 })
        .in("id", withoutDevice);
    }

    if (messages.length === 0) {
      return json({ processed: pending.length, sent: 0, failed: withoutDevice.length });
    }

    let tickets;
    try {
      tickets = await sendExpoPush(messages, Deno.env.get("EXPO_ACCESS_TOKEN") ?? undefined);
    } catch (error) {
      // Falha da Expo: devolve as notificações para nova tentativa.
      await admin.rpc("increment_notification_attempts", {
        p_ids: [...new Set(messageOwner)],
        p_error: String(error),
      });
      throw new ApiError("PUSH_PROVIDER_ERROR", "Falha ao falar com a Expo Push API.", 502);
    }

    const failedByOutbox = new Map<string, string>();
    const okOutbox = new Set<string>();
    const deadTokens: string[] = [];

    tickets.forEach((ticket, index) => {
      const outboxId = messageOwner[index];
      if (ticket.status === "ok") {
        okOutbox.add(outboxId);
      } else {
        failedByOutbox.set(outboxId, ticket.message ?? "unknown_error");
        if (isUnregisteredTicket(ticket)) deadTokens.push(messageToken[index]);
      }
    });

    // Um ticket ok em qualquer device do usuário já conta como entregue.
    for (const id of okOutbox) failedByOutbox.delete(id);

    if (okOutbox.size > 0) {
      await admin
        .from("notification_outbox")
        .update({ status: "sent", sent_at: new Date().toISOString() })
        .in("id", [...okOutbox]);
    }

    for (const [id, message] of failedByOutbox) {
      await admin.rpc("increment_notification_attempts", { p_ids: [id], p_error: message });
    }

    if (deadTokens.length > 0) {
      await admin.from("push_tokens").update({ is_active: false }).in("token", deadTokens);
    }

    return json({
      processed: pending.length,
      sent: okOutbox.size,
      failed: failedByOutbox.size + withoutDevice.length,
      deactivatedTokens: deadTokens.length,
    });
  } catch (error) {
    return errorResponse(error);
  }
});
