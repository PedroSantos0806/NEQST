import { Navigate, Route, Routes, useLocation } from "react-router-dom";
import { Parks } from "./screens/Parks";
import { Park } from "./screens/Park";
import { Court } from "./screens/Court";
import { Profile } from "./screens/Profile";
import { Login } from "./screens/Login";
import { ScanLanding } from "./screens/ScanLanding";
import { AuthCallback } from "./screens/AuthCallback";
import { Loading } from "./components/ui";
import { useAuth } from "./hooks/useAuth";
import type { ReactElement } from "react";

/** Parâmetros que pertencem ao fluxo de login, não à rota. */
const AUTH_PARAMS = ["code", "error", "error_code", "error_description", "state", "type"];

function Protected({ children }: { children: ReactElement }) {
  const { session, loading } = useAuth();
  const location = useLocation();

  if (loading) return <Loading what="Carregando" />;

  if (!session) {
    const params = new URLSearchParams(location.search);
    const cameFromEmailLink = AUTH_PARAMS.some((key) => params.has(key));
    AUTH_PARAMS.forEach((key) => params.delete(key));

    // Sem os parâmetros do link: voltar para cá com um `code` já gasto
    // só repetiria a falha.
    const query = params.toString();
    sessionStorage.setItem("neqst:after-login", location.pathname + (query ? `?${query}` : ""));

    // Chegou com um código de e-mail e mesmo assim não há sessão: o
    // link não pôde ser trocado neste navegador. Vale explicar.
    return <Navigate to={cameFromEmailLink ? "/entrar?motivo=link" : "/entrar"} replace />;
  }

  return children;
}

export function App() {
  return (
    <Routes>
      <Route path="/entrar" element={<Login />} />
      <Route path="/auth/callback" element={<AuthCallback />} />
      {/* O QR impresso aponta para cá */}
      <Route path="/q/:courtId" element={<ScanLanding />} />

      <Route path="/" element={<Protected><Parks /></Protected>} />
      <Route path="/parque/:parkId" element={<Protected><Park /></Protected>} />
      <Route path="/quadra/:courtId" element={<Protected><Court /></Protected>} />
      <Route path="/perfil" element={<Protected><Profile /></Protected>} />

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
