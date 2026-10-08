import { createRoot } from "react-dom/client";
import { isConfigured } from "./lib/env";
import "./index.css";

const container = document.getElementById("root")!;

/**
 * Pinta uma tela legível em vez de deixar a página branca. Usa DOM puro
 * porque precisa funcionar mesmo quando o React (ou o módulo do app)
 * falhou ao carregar.
 */
function fatal(title: string, detail: string, extra?: string): void {
  container.innerHTML = "";

  const box = document.createElement("div");
  box.style.cssText =
    "padding:24px;font-family:Archivo,system-ui,sans-serif;line-height:1.5;color:#0A0E0B;max-width:560px";

  const h1 = document.createElement("h1");
  h1.textContent = title;
  h1.style.cssText = "font-size:22px;margin:0 0 8px";

  const p = document.createElement("p");
  p.textContent = detail;
  p.style.cssText = "margin:0 0 12px";

  box.append(h1, p);

  if (extra) {
    const pre = document.createElement("pre");
    pre.textContent = extra;
    pre.style.cssText =
      "background:#F1ECEF;padding:12px;border-radius:8px;overflow-x:auto;font-size:13px;white-space:pre-wrap";
    box.append(pre);
  }

  container.append(box);
}

const CONFIG_HINT = `VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon public>

Também funciona sem o prefixo: SUPABASE_URL / SUPABASE_ANON_KEY.
Na Vercel: Settings › Environment Variables › Redeploy.`;

// Qualquer erro solto depois do boot vira mensagem, não tela branca.
window.addEventListener("error", (event) => {
  if (container.childElementCount === 0) {
    fatal("Algo quebrou ao abrir o app", String(event.message ?? event.error ?? ""));
  }
});
window.addEventListener("unhandledrejection", (event) => {
  if (container.childElementCount === 0) {
    fatal("Algo quebrou ao abrir o app", String(event.reason ?? ""));
  }
});

if (!isConfigured()) {
  // Sem as variáveis não há backend para falar. Nada do app é carregado:
  // o módulo do Supabase lança ao ser criado sem URL/chave.
  fatal(
    "Falta configurar o backend",
    "Defina as variáveis de ambiente do deploy e publique de novo:",
    CONFIG_HINT,
  );
} else {
  const root = createRoot(container);
  import("./boot")
    .then(({ boot }) => boot(root))
    .catch((error: unknown) => {
      fatal("Não foi possível carregar o app", String(error));
    });
}
