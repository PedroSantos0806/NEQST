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
          // O token vale 30s — tempo de sobra para a navegação seguinte.
          // Levá-lo junto evita pedir uma segunda leitura: quem escaneou
          // o QR impresso já cai na folha de entrar na fila.
          navigate(`/quadra/${result.court.id}`, {
            replace: true,
            state: { scan: result, method: params.get("m") === "nfc" ? "nfc" : "qr" },
          });
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
            // A função diz a que distância você está e qual é o limite;
            // isso ajuda mais do que a frase genérica que havia aqui.
            detail: apiError.message
              ?? "Chegue até a quadra e escaneie de novo. Se estiver no computador, use o celular.",
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
