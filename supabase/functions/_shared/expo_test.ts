import { assert, assertEquals } from "jsr:@std/assert@1";
import { chunk, EXPO_PUSH_BATCH_SIZE, isUnregisteredTicket } from "./expo.ts";

Deno.test("chunk respeita o limite de 100 mensagens por requisição da Expo", () => {
  const messages = Array.from({ length: 250 }, (_, i) => i);
  const batches = chunk(messages, EXPO_PUSH_BATCH_SIZE);

  assertEquals(batches.length, 3);
  assertEquals(batches[0].length, 100);
  assertEquals(batches[2].length, 50);
  assertEquals(batches.flat(), messages);
});

Deno.test("chunk com lista vazia devolve nenhum lote", () => {
  assertEquals(chunk([], 10), []);
});

Deno.test("DeviceNotRegistered marca o token para desativação", () => {
  assert(isUnregisteredTicket({ status: "error", details: { error: "DeviceNotRegistered" } }));
  assert(!isUnregisteredTicket({ status: "error", details: { error: "MessageTooBig" } }));
  assert(!isUnregisteredTicket({ status: "ok", id: "abc" }));
});
