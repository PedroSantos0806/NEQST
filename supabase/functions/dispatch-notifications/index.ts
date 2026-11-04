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
import {
  ExpoPartialError,
  type ExpoPushMessage,
  type ExpoPushTicket,
  isUnregisteredTicket,
  sendExpoPush,
} from "../_shared/expo.ts";
import {
  PushEndpointError,
  sendWebPush,
  type VapidKeys,
  WebPushError,
} from "../_shared/webpush.ts";
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

  // O lote é RESERVADO, não só lido.
  //
  // Antes era um `select ... status = 'pending'` sem claim nem lease, e
  // o docblock manda chamar de 10 em 10 segundos — enquanto um lote de
  // 200 com fetch para a Expo e N push services leva mais que isso.
  // Duas execuções sobrepostas pegavam as MESMAS linhas e mandavam o
  // mesmo "É a sua vez!" duas vezes. `claim_notifications` usa
  // `for update skip locked`, então cada worker leva um lote diferente.
  const { data: pending, error: pendingError } = await admin
    .rpc("claim_notifications", { p_limit: MAX_BATCH, p_max_attempts: MAX_ATTEMPTS })
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
    /**
     * Cada ticket pertence à mensagem de MESMO índice. Só vale casar
     * enquanto houver ticket: o que sobrar sem ticket fica como falha, e
     * nunca herda o desfecho do vizinho — foi assim que o token de push
     * de um usuário era desativado pelo erro de outro.
     */
    const applyTickets = (tickets: ExpoPushTicket[]) => {
      tickets.forEach((ticket, index) => {
        const outboxId = messageOutbox[index];
        if (outboxId === undefined) return;
        if (ticket.status === "ok") {
          delivered.add(outboxId);
        } else {
          failures.set(outboxId, ticket.message ?? "expo_unknown_error");
          if (isUnregisteredTicket(ticket)) {
            const token = messageToken[index];
            if (token) deadTokens.push(token);
          }
        }
      });

      for (let index = tickets.length; index < messageOutbox.length; index += 1) {
        failures.set(messageOutbox[index], "expo_sem_ticket");
      }
    };

    try {
      applyTickets(await sendExpoPush(messages, Deno.env.get("EXPO_ACCESS_TOKEN") ?? undefined));
    } catch (error) {
      // Expo fora do ar não derruba o canal web: registra e segue.
      console.error("expo_push_failed", error);

      if (error instanceof ExpoPartialError) {
        // O que já foi entregue conta como entregue: reenviar isso
        // seria avisar a mesma pessoa duas vezes.
        applyTickets(error.tickets);
      } else {
        for (const outboxId of messageOutbox) {
          failures.set(outboxId, `expo: ${String(error).slice(0, 200)}`);
        }
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
              // Endpoint fora da allow-list: linha gravada antes da
              // regra existir. Desativa em vez de tentar para sempre.
              if (
                error instanceof WebPushError && error.isGone ||
                error instanceof PushEndpointError
              ) {
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

  // As escritas de desfecho são checadas uma por uma.
  //
  // Antes nenhuma olhava `.error`: se o `status = 'sent'` falhasse, os
  // pushes JÁ tinham saído e as linhas continuavam `pending` com
  // `attempts` intocado — reenvio sem fim, com a resposta HTTP ainda
  // dizendo que deu tudo certo. Agora a falha aparece no log e na
  // resposta, porque é ela que explica o push duplicado de amanhã.
  const writeErrors: string[] = [];

  async function write(what: string, run: Promise<{ error: unknown }>): Promise<void> {
    const { error } = await run;
    if (error) {
      console.error(`outbox_write_failed: ${what}`, error);
      writeErrors.push(what);
    }
  }

  if (withoutChannel.length > 0) {
    await write(
      "sem_canal",
      admin
        .from("notification_outbox")
        .update({ status: "failed", last_error: "no_active_push_channel", attempts: MAX_ATTEMPTS })
        .in("id", withoutChannel),
    );
  }

  if (delivered.size > 0) {
    await write(
      "marcar_enviado",
      admin
        .from("notification_outbox")
        .update({ status: "sent", sent_at: new Date().toISOString() })
        .in("id", [...delivered]),
    );
  }

  for (const [id, message] of failures) {
    await write(
      "contar_tentativa",
      admin.rpc("increment_notification_attempts", { p_ids: [id], p_error: message }),
    );
  }

  if (deadTokens.length > 0) {
    await write(
      "desativar_token",
      admin.from("push_tokens").update({ is_active: false }).in("token", deadTokens),
    );
  }

  if (deadSubscriptions.length > 0) {
    await write(
      "desativar_subscription",
      admin
        .from("web_push_subscriptions")
        .update({ is_active: false })
        .in("id", deadSubscriptions),
    );
  }

  return json({
    processed: pending.length,
    sent: delivered.size,
    failed: failures.size + withoutChannel.length,
    // Vazio é o normal. Com conteúdo, o lote foi entregue mas o estado
    // no banco não acompanhou — é o que causa reenvio.
    write_errors: writeErrors,
    channels: {
      expo_messages: messages.length,
      web_push_subscriptions: [...subsByUser.values()].reduce((sum, list) => sum + list.length, 0),
      vapid_configured: vapid !== null,
    },
    deactivated: { push_tokens: deadTokens.length, web_push: deadSubscriptions.length },
  });
});
