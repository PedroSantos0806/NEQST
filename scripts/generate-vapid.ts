#!/usr/bin/env -S deno run
/**
 * Gera o par de chaves VAPID usado pelo Web Push (versão web).
 *
 * Uso:
 *   deno run scripts/generate-vapid.ts
 *
 * Guarde a privada nos secrets do Supabase (VAPID_PRIVATE_KEY) e use a
 * pública no front, em pushManager.subscribe({ applicationServerKey }).
 * Trocar o par invalida todas as subscriptions existentes — os
 * navegadores precisam se registrar de novo.
 */
import { base64UrlEncode } from "../supabase/functions/_shared/bytes.ts";

const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);

const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);

if (!jwk.d) throw new Error("A chave privada não veio na JWK exportada");

console.log("# Chaves VAPID — adicione ao .env e aos secrets do Supabase");
console.log(`VAPID_PUBLIC_KEY=${base64UrlEncode(publicKey)}`);
console.log(`VAPID_PRIVATE_KEY=${jwk.d}`);
console.log("VAPID_SUBJECT=mailto:ops@seu-dominio.com.br");
console.log();
console.log("# A pública também vai no front (applicationServerKey).");
