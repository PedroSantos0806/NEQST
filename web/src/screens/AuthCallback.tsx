import { useEffect } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Loading } from "../components/ui";
import { useAuth } from "../hooks/useAuth";

/**
 * Volta do OAuth e do link de e-mail. O supabase-js já troca o código
 * pela sessão (detectSessionInUrl); aqui só decidimos para onde ir —
 * inclusive de volta ao QR que a pessoa escaneou antes de logar.
 */
export function AuthCallback() {
  const { session, loading } = useAuth();
  const [params] = useSearchParams();
  const navigate = useNavigate();

  useEffect(() => {
    if (loading) return;

    if (!session) {
      navigate("/entrar", { replace: true });
      return;
    }

    if (params.get("reset") === "1") {
      navigate("/perfil?reset=1", { replace: true });
      return;
    }

    const pending = sessionStorage.getItem("neqst:after-login");
    sessionStorage.removeItem("neqst:after-login");
    navigate(pending ?? "/", { replace: true });
  }, [loading, session, navigate, params]);

  return <Loading what="Entrando" />;
}
