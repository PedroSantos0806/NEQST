import { useEffect, useRef, useState } from "react";
import type { Circle, CircleMarker, Map as LeafletMap } from "leaflet";
import { Close, Pin, Search } from "./icons";
import { buttonStyle } from "./ui";
import { env } from "../lib/env";
import { isUsableCoordinate, searchAddress, type GeocodeHit } from "../lib/geocode";

/**
 * O "mapinha" do cadastro: o alfinete fica preso no centro da tela e
 * quem arrasta é o mapa, igual ao aplicativo de corrida. É o gesto que
 * o operador já conhece, e resolve o caso que motivou tudo isto —
 * quadra no meio do parque, longe da rua, onde o endereço serve de
 * referência e só o alfinete diz onde é a quadra de verdade.
 *
 * O círculo desenhado é o raio de proximidade do check-in: dá para ver
 * se ele cobre a quadra inteira ou se vaza para a rua antes de salvar.
 *
 * O mapa é carregado sob demanda (`import()` do Leaflet): quem nunca
 * abre a administração não baixa nada disto. E se o mapa não carregar —
 * rede do parque ruim, provedor de azulejos fora —, os campos de
 * latitude e longitude continuam ali embaixo, então o cadastro nunca
 * depende do mapa para acontecer.
 */

export interface MapPosition {
  latitude: number;
  longitude: number;
}

/** Brasil inteiro na tela, para quando ainda não há nada marcado. */
const NO_POSITION = { latitude: -14.235, longitude: -51.925, zoom: 4 };
/** Zoom em que se distingue uma quadra de outra ao lado. */
const PIN_ZOOM = 18;
const MAX_ZOOM = 19;

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
  const host = useRef<HTMLDivElement>(null);
  const map = useRef<LeafletMap | null>(null);
  const leaflet = useRef<typeof import("leaflet") | null>(null);
  const circle = useRef<Circle | null>(null);
  const referenceDot = useRef<CircleMarker | null>(null);
  // O `onChange` mais recente sem recriar o mapa a cada render do pai.
  const report = useRef(onChange);
  report.current = onChange;

  const [ready, setReady] = useState(false);
  const [broken, setBroken] = useState(false);
  const [tilesBroken, setTilesBroken] = useState(false);
  // O círculo vive num ref (o Leaflet manda nele), mas o botão que o
  // enquadra precisa de um estado para reaparecer.
  const [hasCircle, setHasCircle] = useState(false);
  const [busy, setBusy] = useState<"gps" | "search" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [hits, setHits] = useState<GeocodeHit[] | null>(null);
  const [manual, setManual] = useState(false);
  const [latText, setLatText] = useState(latitude != null ? latitude.toFixed(6) : "");
  const [lngText, setLngText] = useState(longitude != null ? longitude.toFixed(6) : "");

  // Onde o mapa abre. Lido uma única vez: depois disso quem manda é o
  // próprio mapa, e reposicionar a cada render tiraria o alfinete do
  // lugar no meio do arraste.
  const start = useRef(
    latitude != null && longitude != null
      ? { latitude, longitude, zoom: PIN_ZOOM }
      : reference
        ? { latitude: reference.latitude, longitude: reference.longitude, zoom: PIN_ZOOM - 1 }
        : NO_POSITION,
  );

  useEffect(() => {
    let alive = true;

    void (async () => {
      try {
        const [module] = await Promise.all([
          import("leaflet"),
          import("leaflet/dist/leaflet.css"),
        ]);
        // O Leaflet é CommonJS: dependendo do empacotador o módulo vem
        // dentro de `default`.
        const L = ((module as { default?: typeof import("leaflet") }).default
          ?? module) as typeof import("leaflet");
        if (!alive || !host.current || map.current) return;

        const instance = L.map(host.current, {
          center: [start.current.latitude, start.current.longitude],
          zoom: start.current.zoom,
          zoomControl: true,
          // A roda do mouse rola a página; o mapa tem botões de zoom.
          scrollWheelZoom: false,
          attributionControl: true,
        });

        const tiles = L.tileLayer(env.mapTileUrl, {
          maxZoom: MAX_ZOOM,
          attribution: env.mapTileAttribution,
        });
        tiles.on("tileerror", () => {
          if (alive) setTilesBroken(true);
        });
        tiles.addTo(instance);

        // Só depois de montar: o `setView` da criação já aconteceu, e
        // assim ele não é confundido com um arraste do operador.
        instance.on("move", () => {
          const center = instance.getCenter();
          circle.current?.setLatLng(center);
        });
        instance.on("moveend", () => {
          const center = instance.getCenter();
          setLatText(center.lat.toFixed(6));
          setLngText(center.lng.toFixed(6));
          report.current({ latitude: center.lat, longitude: center.lng });
        });

        leaflet.current = L;
        map.current = instance;
        setReady(true);
        // O contêiner acabou de ganhar tamanho dentro do formulário.
        setTimeout(() => instance.invalidateSize(), 0);

        // Quadra nova dentro de um parque já cadastrado: ela nasce na
        // posição do parque (era o que o banco fazia calado). Agora
        // isso fica visível, e o operador arrasta dali.
        if (latitude == null && longitude == null && reference) {
          report.current({ latitude: reference.latitude, longitude: reference.longitude });
        }
      } catch {
        if (alive) setBroken(true);
      }
    })();

    return () => {
      alive = false;
      map.current?.remove();
      map.current = null;
      leaflet.current = null;
      circle.current = null;
      referenceDot.current = null;
    };
    // Montagem única de propósito: ver o comentário do `start`.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // O círculo do raio acompanha o campo "raio de proximidade".
  useEffect(() => {
    const instance = map.current;
    const L = leaflet.current;
    if (!ready || !instance || !L) return;

    if (!radiusMeters || !Number.isFinite(radiusMeters) || radiusMeters <= 0) {
      circle.current?.remove();
      circle.current = null;
      setHasCircle(false);
      return;
    }

    if (!circle.current) {
      circle.current = L.circle(instance.getCenter(), {
        radius: radiusMeters,
        color: "#2f4629",
        weight: 1.5,
        fillColor: "#74b69d",
        fillOpacity: 0.18,
        interactive: false,
      }).addTo(instance);
      setHasCircle(true);
    } else {
      circle.current.setRadius(radiusMeters);
    }
  }, [radiusMeters, ready]);

  // O parque aparece como um ponto, para saber de onde a quadra saiu.
  useEffect(() => {
    const instance = map.current;
    const L = leaflet.current;
    if (!ready || !instance || !L || !reference) return;

    referenceDot.current?.remove();
    referenceDot.current = L.circleMarker([reference.latitude, reference.longitude], {
      radius: 5,
      color: "#b13f16",
      weight: 2,
      fillColor: "#b13f16",
      fillOpacity: 1,
      interactive: false,
    }).addTo(instance);

    return () => {
      referenceDot.current?.remove();
      referenceDot.current = null;
    };
  }, [ready, reference?.latitude, reference?.longitude]);

  /** Move o alfinete. Sem mapa, informa o pai direto. */
  function goTo(position: MapPosition, zoom = PIN_ZOOM) {
    setError(null);
    setLatText(position.latitude.toFixed(6));
    setLngText(position.longitude.toFixed(6));
    const instance = map.current;
    if (instance) {
      instance.setView([position.latitude, position.longitude], Math.max(instance.getZoom(), zoom));
      // O `moveend` informa o pai; mas ele não dispara quando o destino
      // é idêntico ao centro atual.
      report.current(position);
    } else {
      report.current(position);
    }
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
    setBusy("search");
    setError(null);
    setHits(null);
    try {
      const found = await searchAddress(query ?? "");
      if (found.length === 0) {
        setError("Não achamos este endereço. Marque a posição no mapa.");
      } else if (found.length === 1) {
        goTo(found[0], PIN_ZOOM - 1);
      } else {
        setHits(found);
      }
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(null);
    }
  }

  function applyManual() {
    const lat = Number(latText.replace(",", "."));
    const lng = Number(lngText.replace(",", "."));
    if (!isUsableCoordinate(lat, lng)) {
      setError("Latitude entre -90 e 90, longitude entre -180 e 180.");
      return;
    }
    goTo({ latitude: lat, longitude: lng });
  }

  const marked = latitude != null && longitude != null;
  const searchable = (query ?? "").trim().length >= 4;

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

        {/* O alfinete não se move: a ponta mira o centro exato do mapa. */}
        {!broken && (
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
                background: "var(--ink)",
                color: "var(--ocre)",
                border: "2px solid var(--chalk)",
                borderRadius: "50% 50% 50% 4px",
                transform: "rotate(-45deg)",
                boxShadow: "0 3px 8px rgba(10,14,11,.4)",
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
                background: "var(--ink)",
                border: "1.5px solid var(--chalk)",
                borderRadius: "50%",
              }}
            />
          </div>
        )}

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
          disabled={busy !== null || !searchable}
          onClick={() => void findAddress()}
          title={searchable ? undefined : "Escreva o endereço acima primeiro"}
          style={{ ...buttonStyle("ghost", busy !== null || !searchable), minHeight: 40, fontSize: 12 }}
        >
          <Search size={14} />
          {busy === "search" ? "Buscando…" : "Buscar endereço"}
        </button>
      </div>

      {(reference || hasCircle) && (
        <div style={{ display: "grid", gridTemplateColumns: reference ? "1fr 1fr" : "1fr", gap: 8 }}>
          {reference && (
            <button
              type="button"
              className="press"
              onClick={() => goTo({ latitude: reference.latitude, longitude: reference.longitude }, PIN_ZOOM - 1)}
              style={{ ...buttonStyle("ghost"), minHeight: 36, fontSize: 12 }}
            >
              Ir ao parque
            </button>
          )}
          {/*
            Um raio de 1 km não cabe na caixa no zoom de marcar
            alfinete: o círculo vira um fundo verde sem sentido. Este
            botão afasta a câmera até ele caber inteiro, para conferir
            se a área do check-in cobre a quadra e não a rua.
          */}
          <button
            type="button"
            className="press"
            disabled={!hasCircle}
            onClick={() => {
              const instance = map.current;
              if (instance && circle.current) instance.fitBounds(circle.current.getBounds(), { padding: [12, 12] });
            }}
            style={{ ...buttonStyle("ghost", !hasCircle), minHeight: 36, fontSize: 12 }}
          >
            Ver o raio inteiro
          </button>
        </div>
      )}

      {hits && (
        <div style={{ display: "flex", flexDirection: "column", gap: 6, padding: 8, background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.25)", borderRadius: 8 }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
            <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".06em", textTransform: "uppercase", color: "var(--green)" }}>
              Qual destes?
            </span>
            <button
              type="button"
              className="press"
              onClick={() => setHits(null)}
              aria-label="Fechar a lista de endereços"
              style={{ display: "flex", width: 26, height: 26, alignItems: "center", justifyContent: "center", background: "transparent", border: "1.5px solid rgba(10,14,11,.2)", borderRadius: 6, color: "var(--ink)" }}
            >
              <Close size={13} />
            </button>
          </div>
          {hits.map((hit) => (
            <button
              key={`${hit.latitude},${hit.longitude}`}
              type="button"
              className="press"
              onClick={() => {
                setHits(null);
                goTo(hit, PIN_ZOOM - 1);
              }}
              style={{ padding: "8px 10px", background: "transparent", border: "1px solid rgba(47,70,41,.2)", borderRadius: 6, fontSize: 12, lineHeight: 1.4, textAlign: "left", color: "var(--ink)" }}
            >
              {hit.label}
            </button>
          ))}
        </div>
      )}

      <p style={{ margin: 0, fontSize: 11, lineHeight: 1.45, color: "var(--muted)" }}>
        {marked
          ? <>Alfinete em <strong>{latitude.toFixed(6)}, {longitude.toFixed(6)}</strong>. Arraste o mapa para ajustar. </>
          : <>Arraste o mapa até {subject === "parque" ? "o parque" : "a quadra"}. </>}
        {subject === "parque"
          ? "É daqui que as quadras novas começam, cada uma com o seu próprio alfinete."
          : "É esta posição que o check-in compara com a do jogador."}
      </p>

      {error && <p role="alert" style={{ margin: 0, fontSize: 12, color: "var(--rust)" }}>{error}</p>}

      {manual
        ? (
          <div style={{ display: "flex", flexDirection: "column", gap: 6, padding: 8, background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.25)", borderRadius: 8 }}>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
              <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 11, fontWeight: 700 }}>
                Latitude
                <input
                  value={latText}
                  onChange={(event) => setLatText(event.target.value)}
                  inputMode="decimal"
                  style={{ width: "100%", height: 40, padding: "0 10px", background: "var(--bg)", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 8, fontSize: 13, color: "var(--ink)" }}
                />
              </label>
              <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 11, fontWeight: 700 }}>
                Longitude
                <input
                  value={lngText}
                  onChange={(event) => setLngText(event.target.value)}
                  inputMode="decimal"
                  style={{ width: "100%", height: 40, padding: "0 10px", background: "var(--bg)", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 8, fontSize: 13, color: "var(--ink)" }}
                />
              </label>
            </div>
            <button
              type="button"
              className="press"
              onClick={applyManual}
              style={{ ...buttonStyle("ghost"), minHeight: 36, fontSize: 12 }}
            >
              Levar o alfinete para estas coordenadas
            </button>
          </div>
        )
        : (
          <button
            type="button"
            className="press"
            onClick={() => setManual(true)}
            style={{ alignSelf: "flex-start", padding: 0, background: "transparent", border: 0, fontSize: 11, fontWeight: 700, textDecoration: "underline", color: "var(--green)" }}
          >
            Digitar as coordenadas
          </button>
        )}
    </div>
  );
}
