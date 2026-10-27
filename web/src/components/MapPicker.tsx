import { useRef, useState } from "react";
import { Pin, Search } from "./icons";
import { buttonStyle } from "./ui";
import { AddressResults } from "./map/AddressResults";
import { CoordinateFields } from "./map/CoordinateFields";
import { NO_POSITION, PIN_ZOOM, useLeafletMap, type MapPosition } from "./map/useLeafletMap";
import { searchAddress, type GeocodeHit } from "../lib/geocode";

/**
 * O "mapinha" do cadastro: o alfinete fica preso no centro da tela e
 * quem arrasta é o mapa, igual ao aplicativo de corrida. É o gesto que
 * o operador já conhece, e resolve o caso que motivou tudo isto —
 * quadra no meio do parque, longe da rua, onde o endereço serve de
 * referência e só o alfinete diz onde é a quadra de verdade.
 *
 * Centrar NÃO é marcar. O mapa abre sobre o parque para dar contexto,
 * e enquanto ninguém arrastar, localizar, buscar ou tocar em "usar a
 * posição do parque", a quadra continua sem alfinete e o formulário
 * recusa salvar. O desenho do pino mostra essa diferença.
 *
 * O círculo é o raio de proximidade do check-in: dá para ver se ele
 * cobre a quadra inteira ou se vaza para a rua antes de salvar.
 *
 * Aqui mora só a orquestração. O Leaflet está em `map/useLeafletMap`,
 * a lista de endereços em `map/AddressResults` e a entrada manual em
 * `map/CoordinateFields`.
 */
export type { MapPosition };

export function MapPicker({
  latitude,
  longitude,
  onChange,
  radiusMeters,
  reference,
  query,
  subject = "quadra",
  height = 260,
}: {
  latitude: number | null;
  longitude: number | null;
  onChange: (position: MapPosition) => void;
  /** Raio do check-in, desenhado em volta do alfinete. */
  radiusMeters?: number | null;
  /** O que está sendo marcado — muda só o texto dos botões. */
  subject?: "quadra" | "parque";
  /** Posição conhecida de referência (o parque), para orientar. */
  reference?: (MapPosition & { label: string }) | null;
  /** O endereço digitado no formulário, usado pelo botão de busca. */
  query?: string;
  height?: number;
}) {
  const [busy, setBusy] = useState<"gps" | "search" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [hits, setHits] = useState<GeocodeHit[] | null>(null);
  const searching = useRef<AbortController | null>(null);

  const marked = latitude != null && longitude != null;
  const searchable = (query ?? "").trim().length >= 4;

  const { host, broken, tilesBroken, hasCircle, moveTo, frameRadius } = useLeafletMap({
    // Onde abrir, decidido uma vez: a posição já marcada, senão o
    // parque, senão o Brasil inteiro.
    start: marked
      ? { latitude, longitude, zoom: PIN_ZOOM }
      : reference
        ? { latitude: reference.latitude, longitude: reference.longitude, zoom: PIN_ZOOM - 1 }
        : NO_POSITION,
    onSettle: onChange,
    radiusMeters,
    reference,
  });

  function goTo(position: MapPosition, zoom = PIN_ZOOM) {
    setError(null);
    moveTo(position, zoom);
  }

  async function useMyLocation() {
    setBusy("gps");
    setError(null);
    try {
      const { getPosition } = await import("../lib/geo");
      const position = await getPosition();
      goTo({ latitude: position.latitude, longitude: position.longitude });
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function findAddress() {
    const controller = new AbortController();
    searching.current = controller;
    setBusy("search");
    setError(null);
    setHits(null);
    try {
      const found = await searchAddress(query ?? "", { signal: controller.signal });
      if (found.length === 0) {
        setError("Não achamos este endereço. Marque a posição no mapa.");
      } else if (found.length === 1) {
        goTo(found[0], PIN_ZOOM - 1);
      } else {
        setHits(found);
      }
    } catch (cause) {
      // Cancelamento é escolha de quem está usando, não falha a relatar.
      if ((cause as Error).name !== "AbortError") setError((cause as Error).message);
    } finally {
      searching.current = null;
      setBusy(null);
    }
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      <div
        style={{
          position: "relative",
          height,
          overflow: "hidden",
          background: "var(--mauve)",
          border: "1.5px solid rgba(47,70,41,.3)",
          borderRadius: 10,
        }}
      >
        <div ref={host} style={{ position: "absolute", inset: 0 }} aria-label="Mapa da posição" />
        {!broken && <CenterPin marked={marked} />}

        {(broken || tilesBroken) && (
          <p
            style={{
              position: "absolute",
              inset: 0,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              margin: 0,
              padding: 16,
              zIndex: 600,
              background: "rgba(230,221,226,.92)",
              fontSize: 12,
              lineHeight: 1.5,
              textAlign: "center",
              color: "var(--muted)",
            }}
          >
            {broken
              ? "O mapa não carregou. Use a minha localização ou digite as coordenadas abaixo — o cadastro funciona sem ele."
              : "Os blocos do mapa não carregaram (rede). O alfinete continua valendo: use a localização ou as coordenadas abaixo."}
          </p>
        )}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
        <button
          type="button"
          className="press"
          disabled={busy !== null}
          onClick={() => void useMyLocation()}
          style={{ ...buttonStyle("ghost", busy !== null), minHeight: 40, fontSize: 12 }}
        >
          {busy === "gps" ? "Localizando…" : subject === "parque" ? "Estou no parque" : "Estou na quadra"}
        </button>
        <button
          type="button"
          className="press"
          disabled={busy === "gps" || (busy === null && !searchable)}
          onClick={() => {
            if (busy === "search") searching.current?.abort();
            else void findAddress();
          }}
          title={searchable ? undefined : "Escreva o endereço acima primeiro"}
          style={{ ...buttonStyle("ghost", busy === "gps" || (busy === null && !searchable)), minHeight: 40, fontSize: 12 }}
        >
          {busy !== "search" && <Search size={14} />}
          {busy === "search" ? "Cancelar busca" : "Buscar endereço"}
        </button>
      </div>

      {(reference || hasCircle) && (
        <div style={{ display: "grid", gridTemplateColumns: reference ? "1fr 1fr" : "1fr", gap: 8 }}>
          {reference && (
            <button
              type="button"
              className="press"
              onClick={() => goTo({ latitude: reference.latitude, longitude: reference.longitude }, PIN_ZOOM - 1)}
              style={{ ...buttonStyle(marked ? "ghost" : "dark"), minHeight: 36, fontSize: 12 }}
            >
              {/*
                Quadra que fica mesmo na entrada do parque continua a um
                toque — a diferença é que agora é um toque, e não o
                silêncio de quem só apertou Salvar.
              */}
              {marked ? "Ir ao parque" : "Usar a posição do parque"}
            </button>
          )}
          {/*
            Um raio de 1 km não cabe na caixa no zoom de marcar
            alfinete: o círculo vira um fundo verde sem sentido. Este
            botão afasta a câmera até ele caber inteiro.
          */}
          <button
            type="button"
            className="press"
            disabled={!hasCircle}
            onClick={frameRadius}
            style={{ ...buttonStyle("ghost", !hasCircle), minHeight: 36, fontSize: 12 }}
          >
            Ver o raio inteiro
          </button>
        </div>
      )}

      {hits && (
        <AddressResults
          hits={hits}
          onClose={() => setHits(null)}
          onPick={(hit) => { setHits(null); goTo(hit, PIN_ZOOM - 1); }}
        />
      )}

      <p style={{ margin: 0, fontSize: 11, lineHeight: 1.45, color: "var(--muted)" }}>
        {marked
          ? <>Alfinete em <strong>{latitude.toFixed(6)}, {longitude.toFixed(6)}</strong>. Arraste o mapa para ajustar. </>
          : <>Ainda <strong>sem alfinete</strong>: arraste o mapa até {subject === "parque" ? "o parque" : "a quadra"}. </>}
        {subject === "parque"
          ? "É daqui que as quadras novas começam, cada uma com o seu próprio alfinete."
          : "É esta posição que o check-in compara com a do jogador."}
      </p>

      {error && <p role="alert" style={{ margin: 0, fontSize: 12, color: "var(--rust)" }}>{error}</p>}

      <CoordinateFields latitude={latitude} longitude={longitude} onApply={goTo} />
    </div>
  );
}

/**
 * O alfinete não se move: a ponta mira o centro exato do mapa.
 *
 * Vazado e tracejado enquanto nada está marcado — centrar o mapa no
 * parque não é escolher a posição, e um pino cheio no meio da tela
 * fazia parecer que já estava resolvido.
 */
function CenterPin({ marked }: { marked: boolean }) {
  return (
    <div
      aria-hidden="true"
      style={{
        position: "absolute",
        left: "50%",
        top: "50%",
        transform: "translate(-50%, -50%)",
        pointerEvents: "none",
        zIndex: 500,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
      }}
    >
      <span
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          width: 34,
          height: 34,
          marginBottom: 2,
          background: marked ? "var(--ink)" : "rgba(10,14,11,.25)",
          color: marked ? "var(--ocre)" : "var(--chalk)",
          border: marked ? "2px solid var(--chalk)" : "2px dashed var(--chalk)",
          borderRadius: "50% 50% 50% 4px",
          transform: "rotate(-45deg)",
          boxShadow: marked ? "0 3px 8px rgba(10,14,11,.4)" : "none",
        }}
      >
        <span style={{ display: "flex", transform: "rotate(45deg)" }}>
          <Pin size={17} />
        </span>
      </span>
      <span
        style={{
          width: 6,
          height: 6,
          marginTop: 12,
          background: marked ? "var(--ink)" : "transparent",
          border: marked ? "1.5px solid var(--chalk)" : "1.5px dashed var(--chalk)",
          borderRadius: "50%",
        }}
      />
    </div>
  );
}
