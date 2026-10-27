import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { hostInviteOpened, scanCourt } from "../lib/api";
import { getPosition, LocationError } from "../lib/geo";
import { ErrorState, Loading, buttonStyle } from "../components/ui";
import { QrIcon } from "../components/icons";
import { useAuth } from "../hooks/useAuth";
import { rememberAfterLogin } from "../lib/after-login";
import { installOption, playStoreUrl, promptInstall, visitorId } from "../lib/install";

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
 */
export function ScanLanding() {
  const { courtId, code } = useParams<{ courtId?: string; code?: string }>();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { session, loading } = useAuth();
  const [error, setError] = useState<{ title: string; detail: string } | null>(null);
  const [retry, setRetry] = useState(0);
  const counted = useRef(false);
  const isInvite = Boolean(code);

  // A abertura do convite conta para o painel do piloto, antes de
  // qualquer login. Falhar aqui não atrapalha ninguém.
  useEffect(() => {
    if (!code || counted.current) return;
    counted.current = true;
    void hostInviteOpened(code, visitorId()).catch(() => undefined);
  }, [code]);

  useEffect(() => {
    if (loading) return;

    // Sem login não dá para entrar na fila. No QR da placa vai direto
    // para o login; no convite, a tela de boas-vindas oferece instalar
    // o app antes.
    if (!session) {
      if (!isInvite) {
        rememberAfterLogin(window.location.pathname + window.location.search);
        navigate("/entrar", { replace: true });
      }
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
  }, [courtId, code, isInvite, loading, session, navigate, params, retry]);

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

  if (!loading && !session && isInvite) {
    return (
      <InviteWelcome
        onContinue={() => {
          rememberAfterLogin(window.location.pathname);
          navigate("/entrar");
        }}
      />
    );
  }

  return <Loading what="Confirmando que você está na quadra" />;
}

/**
 * Quem escaneou o QR na tela de alguém e ainda não tem conta. Oferece o
 * app antes do login: o convite espera 10 minutos.
 */
function InviteWelcome({ onContinue }: { onContinue: () => void }) {
  const [option, setOption] = useState(installOption);
  const store = playStoreUrl();

  async function install() {
    await promptInstall();
    setOption(installOption());
  }

  return (
    <div className="screen fade" style={{ display: "flex", flexDirection: "column", gap: 18, padding: "36px 18px 28px" }}>
      <span style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 56, height: 56, background: "var(--green)", color: "var(--chalk)", borderRadius: 14 }}>
        <QrIcon size={28} />
      </span>

      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <span className="bb" style={{ fontSize: 44, lineHeight: 0.92, color: "var(--green)" }}>
          Chamaram você para a fila
        </span>
        <span style={{ fontSize: 15, lineHeight: 1.45 }}>
          Quem está na fila desta quadra organiza a vez pelo NEQST. Entre com o seu e-mail
          e pegue o seu lugar — você acompanha a vez pelo celular e recebe o aviso quando
          a quadra liberar.
        </span>
      </div>

      <button type="button" className="press" onClick={onContinue} style={{ ...buttonStyle("primary"), minHeight: 56, fontSize: 16 }}>
        Entrar na fila
      </button>

      {option === "prompt" && (
        <button type="button" className="press" onClick={() => void install()} style={buttonStyle("dark")}>
          Instalar o app no celular
        </button>
      )}

      {option === "ios" && (
        <p style={{ margin: 0, padding: "10px 12px", background: "var(--chalk)", borderRadius: 10, fontSize: 13, lineHeight: 1.45 }}>
          <strong>Quer o app no iPhone?</strong> Toque em Compartilhar e depois em
          “Adicionar à Tela de Início”. Dá para fazer isso depois, também.
        </p>
      )}

      {store && option !== "installed" && (
        <a href={store} target="_blank" rel="noopener noreferrer" className="press" style={{ ...buttonStyle("ghost"), textDecoration: "none" }}>
          Baixar na Play Store
        </a>
      )}

      <p style={{ margin: 0, fontSize: 12, lineHeight: 1.45, color: "var(--muted)" }}>
        O QR vale 10 minutos — tempo de criar a conta. Na hora de entrar, o app confere que
        você está mesmo na quadra.
      </p>
    </div>
  );
}
