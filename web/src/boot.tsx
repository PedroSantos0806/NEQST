import { StrictMode } from "react";
import type { Root } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { App } from "./App";
import { AuthProvider } from "./hooks/useAuth";
import { registerServiceWorker } from "./lib/push";

/**
 * Sobe o app de verdade. Fica num módulo separado para o main.tsx poder
 * decidir se carrega isto — nada que toque o Supabase é importado
 * quando falta configuração.
 */
export function boot(root: Root): void {
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
