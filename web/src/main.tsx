import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { App } from "./App";
import { AuthProvider } from "./hooks/useAuth";
import { isConfigured } from "./lib/env";
import { registerServiceWorker } from "./lib/push";
import "./index.css";

const root = createRoot(document.getElementById("root")!);

if (!isConfigured()) {
  // Sem as variáveis o app não tem backend para falar. Melhor dizer o
  // que falta do que mostrar uma tela branca.
  root.render(
    <div style={{ padding: 24, fontFamily: "Archivo, sans-serif", lineHeight: 1.5 }}>
      <h1 style={{ fontSize: 22, marginTop: 0 }}>Falta configurar o backend</h1>
      <p>Defina as variáveis de ambiente do deploy e publique de novo:</p>
      <pre
        style={{
          background: "#F1ECEF",
          padding: 12,
          borderRadius: 8,
          overflowX: "auto",
          fontSize: 13,
        }}
      >
{`VITE_SUPABASE_URL=https://<project-ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<anon public>`}
      </pre>
      <p style={{ fontSize: 14, color: "#5B4F55" }}>
        Na Vercel: Settings › Environment Variables. Depois, Redeploy.
      </p>
    </div>,
  );
} else {
  root.render(
    <StrictMode>
      <BrowserRouter>
        <AuthProvider>
          <App />
        </AuthProvider>
      </BrowserRouter>
    </StrictMode>,
  );

  void registerServiceWorker();
}
