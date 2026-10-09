import { useEffect } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { Loading } from "../components/ui";
import { useAuth } from "../hooks/useAuth";
import { urlAuthError } from "../lib/auth-messages";
import { takeAfterLogin } from "../lib/after-login";

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
      // O Supabase manda o motivo na URL quando o link expirou ou já
      // foi usado; sem motivo, foi a troca do código que não passou
      // neste navegador. Nos dois casos quem explica é a tela de login.
      navigate(urlAuthError() ? `/entrar${window.location.search}` : "/entrar?motivo=link", {
        replace: true,
      });
      return;
    }

    if (params.get("reset") === "1") {
      navigate("/perfil?reset=1", { replace: true });
      return;
    }

    navigate(takeAfterLogin(), { replace: true });
  }, [loading, session, navigate, params]);

  return <Loading what="Entrando" />;
}
