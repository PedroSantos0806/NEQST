import { useEffect, useRef, useState } from "react";
import type { Circle, CircleMarker, Map as LeafletMap } from "leaflet";
import { env } from "../../lib/env";

export interface MapPosition {
  latitude: number;
  longitude: number;
}

/** Brasil inteiro na tela, para quando ainda não há nada marcado. */
export const NO_POSITION = { latitude: -14.235, longitude: -51.925, zoom: 4 };
/** Zoom em que se distingue uma quadra de outra ao lado. */
export const PIN_ZOOM = 18;
const MAX_ZOOM = 19;

interface Options {
  /** Onde o mapa abre. Lido uma vez só, na montagem. */
  start: MapPosition & { zoom: number };
  /** Chamado a cada vez que o centro para de se mover. */
  onSettle: (position: MapPosition) => void;
  radiusMeters?: number | null;
  reference?: MapPosition | null;
}

/**
 * Todo o ciclo de vida do Leaflet num lugar só: criar, destruir, o
 * círculo do raio, o ponto do parque e a ligação entre arrastar o mapa
 * e informar a posição.
 *
 * Fica fora do componente porque é a única parte imperativa da tela —
 * o resto é formulário. Misturados, davam um componente de quase 500
 * linhas onde não se achava nem o mapa nem o formulário.
 *
 * O Leaflet entra por `import()`: quem nunca abre a administração não
 * baixa os 44 kB.
 */
export function useLeafletMap({ start, onSettle, radiusMeters, reference }: Options) {
  const host = useRef<HTMLDivElement>(null);
  const map = useRef<LeafletMap | null>(null);
  const leaflet = useRef<typeof import("leaflet") | null>(null);
  const circle = useRef<Circle | null>(null);
  const referenceDot = useRef<CircleMarker | null>(null);

  // O callback mais recente sem recriar o mapa a cada render do pai.
  const settle = useRef(onSettle);
  useEffect(() => { settle.current = onSettle; }, [onSettle]);

  const [ready, setReady] = useState(false);
  const [broken, setBroken] = useState(false);
  const [tilesBroken, setTilesBroken] = useState(false);
  // O círculo vive num ref (quem manda nele é o Leaflet), mas o botão
  // que o enquadra precisa de um estado para reaparecer.
  const [hasCircle, setHasCircle] = useState(false);

  const opening = useRef(start);

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
          center: [opening.current.latitude, opening.current.longitude],
          zoom: opening.current.zoom,
          zoomControl: true,
          // A roda do mouse rola a página; o mapa tem botões de zoom.
          scrollWheelZoom: false,
          attributionControl: true,
        });

        const tiles = L.tileLayer(env.mapTileUrl, {
          maxZoom: MAX_ZOOM,
          attribution: env.mapTileAttribution,
        });
        tiles.on("tileerror", () => { if (alive) setTilesBroken(true); });
        tiles.addTo(instance);

        // Ligados depois de criar: o `setView` da construção já
        // aconteceu, então ele não é confundido com um arraste.
        instance.on("move", () => circle.current?.setLatLng(instance.getCenter()));
        instance.on("moveend", () => {
          const center = instance.getCenter();
          settle.current({ latitude: center.lat, longitude: center.lng });
        });

        leaflet.current = L;
        map.current = instance;
        setReady(true);
        // O contêiner acabou de ganhar tamanho dentro do formulário.
        setTimeout(() => instance.invalidateSize(), 0);
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
  }, []);

  // O círculo acompanha o campo "raio de proximidade".
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

  /** Leva o centro (e o alfinete) para uma posição. */
  function moveTo(position: MapPosition, zoom = PIN_ZOOM): void {
    const instance = map.current;
    if (!instance) {
      // Sem mapa (não carregou), quem chamou ainda precisa do valor.
      settle.current(position);
      return;
    }
    /*
     * Quem informa a posição é o `moveend`: um caminho só, sempre o
     * centro de verdade depois do arredondamento de pixel.
     *
     * A exceção é o destino que já é o centro atual — o Leaflet não
     * dispara evento nenhum quando nada se mexe. É o caso de "usar a
     * posição do parque" num mapa que já abriu centrado nele: sem
     * isto, o botão não faria nada visível e a quadra continuaria sem
     * alfinete.
     */
    const before = instance.getCenter();
    const targetZoom = Math.max(instance.getZoom(), zoom);
    const still = instance.getZoom() === targetZoom
      && Math.abs(before.lat - position.latitude) < 1e-9
      && Math.abs(before.lng - position.longitude) < 1e-9;

    instance.setView([position.latitude, position.longitude], targetZoom);
    if (still) settle.current(position);
  }

  /** Afasta a câmera até o círculo do raio caber inteiro. */
  function frameRadius(): void {
    const instance = map.current;
    if (instance && circle.current) {
      instance.fitBounds(circle.current.getBounds(), { padding: [12, 12] });
    }
  }

  return { host, broken, tilesBroken, hasCircle, moveTo, frameRadius };
}
