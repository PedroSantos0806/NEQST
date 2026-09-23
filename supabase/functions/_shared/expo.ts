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
      throw new Error(`Expo Push API respondeu ${response.status}: ${text}`);
    }

    const payload = await response.json() as { data?: ExpoPushTicket[] };
    tickets.push(...(payload.data ?? []));
  }

  return tickets;
}
