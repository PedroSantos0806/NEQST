#!/usr/bin/env -S deno run --allow-env --allow-net --allow-write
/**
 * Gera o conteúdo assinado dos QR Codes das quadras (US-02) e, opcionalmente,
 * uma folha HTML pronta para impressão.
 *
 * Uso:
 *   export SUPABASE_URL=...
 *   export SUPABASE_SERVICE_ROLE_KEY=...
 *   export QR_SIGNING_SECRET=...
 *
 *   deno run --allow-env --allow-net scripts/generate-qr.ts
 *   deno run --allow-env --allow-net --allow-write scripts/generate-qr.ts --html qrcodes.html
 *   deno run --allow-env --allow-net scripts/generate-qr.ts --court <uuid>
 *
 * A folha HTML usa a biblioteca `qrcode` via CDN apenas no momento da
 * impressão — nenhum dado sensível sai do navegador.
 */
import { createClient } from "jsr:@supabase/supabase-js@2";
import { buildCourtQrPayload } from "../supabase/functions/_shared/qr.ts";

interface Court {
  id: string;
  slug: string;
  name: string;
  address: string | null;
  qr_secret_version: number;
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    console.error(`✖ Variável de ambiente obrigatória ausente: ${name}`);
    Deno.exit(1);
  }
  return value;
}

function arg(flag: string): string | undefined {
  const index = Deno.args.indexOf(flag);
  return index >= 0 ? Deno.args[index + 1] : undefined;
}

function htmlSheet(items: Array<Court & { payload: string }>): string {
  const cards = items.map((court) => `
    <article class="card">
      <h2>${court.name}</h2>
      <p class="address">${court.address ?? ""}</p>
      <div class="qr" data-payload="${court.payload}"></div>
      <p class="hint">Escaneie com o app NEQST para entrar na fila</p>
      <p class="meta">${court.slug} · v${court.qr_secret_version}</p>
    </article>`).join("\n");

  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>QR Codes das quadras — NEQST</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 24px; background: #fff; color: #111; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 24px; }
  .card { border: 2px solid #111; border-radius: 12px; padding: 20px; text-align: center; page-break-inside: avoid; }
  .card h2 { margin: 0 0 4px; font-size: 20px; }
  .address { margin: 0 0 12px; font-size: 13px; color: #555; }
  .qr { display: flex; justify-content: center; margin: 12px 0; }
  .hint { font-size: 13px; font-weight: 600; margin: 8px 0 0; }
  .meta { font-size: 11px; color: #888; margin: 4px 0 0; font-family: monospace; }
  @media print { body { margin: 0; } .card { border-color: #000; } }
</style>
</head>
<body>
  <h1>NEQST — QR Codes das quadras</h1>
  <div class="grid">
${cards}
  </div>
  <script src="https://cdn.jsdelivr.net/npm/qrcode@1.5.3/build/qrcode.min.js"></script>
  <script>
    for (const node of document.querySelectorAll(".qr")) {
      const canvas = document.createElement("canvas");
      node.appendChild(canvas);
      QRCode.toCanvas(canvas, node.dataset.payload, { width: 220, margin: 1 });
    }
  </script>
</body>
</html>`;
}

async function main(): Promise<void> {
  const secret = env("QR_SIGNING_SECRET");
  const client = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false },
  });

  let query = client
    .from("courts")
    .select("id, slug, name, address, qr_secret_version")
    .order("name");

  const courtId = arg("--court");
  if (courtId) query = query.eq("id", courtId);
  else query = query.eq("is_active", true);

  const { data, error } = await query.returns<Court[]>();
  if (error) {
    console.error(`✖ Falha ao ler as quadras: ${error.message}`);
    Deno.exit(1);
  }
  if (!data || data.length === 0) {
    console.error("✖ Nenhuma quadra encontrada.");
    Deno.exit(1);
  }

  const items = await Promise.all(
    data.map(async (court) => ({
      ...court,
      payload: await buildCourtQrPayload(court.id, court.qr_secret_version, secret),
    })),
  );

  for (const court of items) {
    console.log(`${court.name} (${court.slug}) v${court.qr_secret_version}`);
    console.log(`  ${court.payload}\n`);
  }

  const htmlPath = arg("--html");
  if (htmlPath) {
    await Deno.writeTextFile(htmlPath, htmlSheet(items));
    console.log(`✔ Folha de impressão gerada em ${htmlPath}`);
  }
}

if (import.meta.main) {
  await main();
}
