import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { hostInviteOpened, scanCourt } from "../lib/api";
import { getPosition, LocationError } from "../lib/geo";
import { ErrorState, Loading, buttonStyle } from "../components/ui";
import { visitorId } from "../lib/install";

/**
 * Rotas /q/:courtId e /q/h/:code — onde cai quem aponta a câmera do
 * celular para um QR Code.
 *
 *   /q/:courtId  o QR impresso na placa da quadra
 *   /q/h/:code   o QR na tela de alguém que já está na fila, nas quadras
 *                do piloto sem nada na placa (Sprint 5)
 *
 * É o caminho principal de entrada: a pessoa não abriu o app, ela leu um
 * código. Então aqui não há scanner — a URL inteira já é o payload, e
 * basta pedir a localização e validar.
 *
 * E não há login: desde o totem, entrar na fila é digitar nome e
 * sobrenome. O que prova que a pessoa está na quadra é o código
 * impresso mais a localização, que é o que esta tela confirma.
 */
export function ScanLanding() {
  const { courtId, code } = useParams<{ courtId?: string; code?: string }>();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const [error, setError] = useState<{ title: string; detail: string } | null>(null);
  const [retry, setRetry] = useState(0);
  const counted = useRef(false);

  // A abertura do convite conta para o painel do piloto, antes de
  // qualquer login. Falhar aqui não atrapalha ninguém.
  useEffect(() => {
    if (!code || counted.current) return;
    counted.current = true;
    void hostInviteOpened(code, visitorId()).catch(() => undefined);
  }, [code]);

  useEffect(() => {
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
          // o QR impresso já cai na tela de digitar o nome.
          navigate("/fila", {
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

        if (apiError.code === "HOST_INVITE_EXPIRED" || apiError.code === "HOST_QUEUE_CLOSED") {
          setError({
            title: apiError.code === "HOST_INVITE_EXPIRED" ? "Este QR venceu" : "Esta fila já foi encerrada",
            detail: apiError.message ?? "Peça para alguém da fila mostrar o QR de novo.",
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
  }, [courtId, code, navigate, params, retry]);

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
