import { useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { scanCourt } from "../lib/api";
import { getPosition, LocationError } from "../lib/geo";
import { ErrorState, Loading, buttonStyle } from "../components/ui";
import { useAuth } from "../hooks/useAuth";
import { rememberAfterLogin } from "../lib/after-login";

/**
 * Rota /q/:courtId — onde cai quem aponta a câmera do celular para o QR
 * Code impresso na quadra.
 *
 * É o caminho principal de entrada: a pessoa não abriu o app, ela leu um
 * código. Então aqui não há scanner — a URL inteira já é o payload
 * assinado, e basta pedir a localização e validar.
 */
export function ScanLanding() {
  const { courtId } = useParams<{ courtId: string }>();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { session, loading } = useAuth();
  const [error, setError] = useState<{ title: string; detail: string } | null>(null);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    if (loading) return;

    // Sem login não dá para entrar na fila: guardamos para onde voltar.
    if (!session) {
      rememberAfterLogin(window.location.pathname + window.location.search);
      navigate("/entrar", { replace: true });
      return;
    }

    let cancelled = false;

    (async () => {
      try {
        const position = await getPosition();
        const result = await scanCourt({
          payload: window.location.href,
          latitude: position.latitude,
          longitude: position.longitude,
          accuracy: position.accuracy,
          method: params.get("m") === "nfc" ? "nfc" : "qr",
          purpose: "join",
        });

        if (!cancelled) {
          // O token de 30s não sobrevive à navegação; a tela da quadra
          // pede um novo na hora de entrar na fila. O que importa aqui é
          // que a validação passou e sabemos qual quadra é.
          navigate(`/quadra/${result.court.id}`, { replace: true });
        }
      } catch (cause) {
        if (cancelled) return;

        if (cause instanceof LocationError) {
          setError({
            title: "Precisamos da sua localização",
            detail:
              cause.kind === "denied"
                ? "Libere a localização para o site e tente de novo — é assim que confirmamos que você está na quadra."
                : cause.message,
          });
          return;
        }

        const apiError = cause as { code?: string; message?: string };
        if (apiError.code === "TOO_FAR_FROM_COURT") {
          setError({
            title: "Você está longe demais desta quadra",
            detail: "Chegue até a quadra e escaneie de novo. Se estiver no computador, use o celular.",
          });
          return;
        }

        setError({
          title: "Não conseguimos validar este código",
          detail: apiError.message ?? "Tente escanear novamente.",
        });
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [courtId, loading, session, navigate, params, retry]);

  if (error) {
    return (
      <div style={{ padding: "40px 18px" }}>
        <ErrorState title={error.title} detail={error.detail} onRetry={() => { setError(null); setRetry((n) => n + 1); }} />
        <button type="button" className="press" onClick={() => navigate("/")} style={{ ...buttonStyle("ghost"), marginTop: 12 }}>
          Ver os parques
        </button>
      </div>
    );
  }

  return <Loading what="Confirmando que você está na quadra" />;
}
