/**
 * Integração com a Expo Push API (FCM no Android + APNs no iOS).
 * Docs: https://docs.expo.dev/push-notifications/sending-notifications/
 */

export const EXPO_PUSH_ENDPOINT = "https://exp.host/--/api/v2/push/send";
export const EXPO_PUSH_BATCH_SIZE = 100;

export interface ExpoPushMessage {
  to: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
  sound?: "default" | null;
  priority?: "default" | "normal" | "high";
  channelId?: string;
  ttl?: number;
}

export interface ExpoPushTicket {
  status: "ok" | "error";
  id?: string;
  message?: string;
  details?: { error?: string };
}

export function chunk<T>(items: T[], size = EXPO_PUSH_BATCH_SIZE): T[][] {
  const batches: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    batches.push(items.slice(i, i + size));
  }
  return batches;
}

/** Tokens que a Expo considera permanentemente inválidos. */
export function isUnregisteredTicket(ticket: ExpoPushTicket): boolean {
  return ticket.status === "error" && ticket.details?.error === "DeviceNotRegistered";
}

export async function sendExpoPush(
  messages: ExpoPushMessage[],
  accessToken?: string,
): Promise<ExpoPushTicket[]> {
  if (messages.length === 0) return [];

  const tickets: ExpoPushTicket[] = [];

  for (const batch of chunk(messages)) {
    const response = await fetch(EXPO_PUSH_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "Accept-Encoding": "gzip, deflate",
        ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
      },
      body: JSON.stringify(batch),
    });

    if (!response.ok) {
      const text = await response.text();
      // Os tickets dos lotes JÁ enviados vão no erro.
      //
      // Lançar e perdê-los fazia o retry reenviar o que a Expo já tinha
      // entregue: o aviso chegava duas vezes no mesmo celular. Quem
      // chama decide o que fazer com o pedaço que deu certo.
      throw new ExpoPartialError(
        `Expo Push API respondeu ${response.status}: ${text}`,
        tickets,
      );
    }

    const payload = await response.json() as { data?: ExpoPushTicket[] };
    const batchTickets = payload.data ?? [];

    // A Expo devolve um ticket por mensagem, na ordem. Se vier faltando,
    // casar por índice desloca TODOS os seguintes — e o índice errado
    // desativava o token de push de outro usuário, que simplesmente
    // parava de ser avisado da vez dele. Melhor marcar o lote como
    // indefinido do que atribuir desfecho à pessoa errada.
    if (batchTickets.length !== batch.length) {
      throw new ExpoPartialError(
        `Expo Push API devolveu ${batchTickets.length} tickets para ${batch.length} mensagens`,
        tickets,
      );
    }

    tickets.push(...batchTickets);
  }

  return tickets;
}

/**
 * Falha no meio do envio, carregando o que já deu certo.
 *
 * Sem isto, um 429 no terceiro lote perdia os tickets dos dois
 * primeiros e o retry reenviava o que já havia sido entregue.
 */
export class ExpoPartialError extends Error {
  readonly tickets: ExpoPushTicket[];

  constructor(message: string, tickets: ExpoPushTicket[]) {
    super(message);
    this.name = "ExpoPartialError";
    this.tickets = tickets;
  }
}
