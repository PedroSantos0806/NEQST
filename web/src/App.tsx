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

function Protected({ children }: { children: ReactElement }) {
  const { session, loading } = useAuth();
  const location = useLocation();

  if (loading) return <Loading what="Carregando" />;

  if (!session) {
    sessionStorage.setItem("neqst:after-login", location.pathname + location.search);
    return <Navigate to="/entrar" replace />;
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
