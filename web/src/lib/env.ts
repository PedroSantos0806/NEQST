/**
 * Configuração que vem do build (Vercel › Settings › Environment Variables).
 *
 * Nada aqui lança no import: se as variáveis faltarem, o app precisa
 * conseguir renderizar a tela que explica o que falta. Lançar no topo
 * do módulo derrubava o bundle inteiro antes do primeiro render — e o
 * resultado era uma página em branco, que não diz nada a ninguém.
 */
const raw = {
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL as string | undefined,
  supabaseAnonKey: import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined,
  vapidPublicKey: import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined,
  mapTileUrl: import.meta.env.VITE_MAP_TILE_URL as string | undefined,
  mapTileAttribution: import.meta.env.VITE_MAP_TILE_ATTRIBUTION as string | undefined,
  playStoreUrl: import.meta.env.VITE_PLAY_STORE_URL as string | undefined,
};

/**
 * Azulejos do mapa. O padrão é o OpenStreetMap, que não pede chave: o
 * mapa aparece num deploy novo sem configurar nada. Quem quiser imagem
 * de satélite (ajuda a achar a quadra dentro do parque) troca as duas
 * variáveis no deploy — a atribuição é exigência de licença dos dois.
 */
const OSM_TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const OSM_ATTRIBUTION = "© colaboradores do OpenStreetMap";

export function isConfigured(): boolean {
  return Boolean(raw.supabaseUrl && raw.supabaseAnonKey);
}

function required(name: string, value: string | undefined): string {
  if (!value) throw new Error(`Variável ${name} não configurada no build.`);
  return value;
}

export const env = {
  get supabaseUrl() {
    return required("SUPABASE_URL", raw.supabaseUrl);
  },
  get supabaseAnonKey() {
    return required("SUPABASE_ANON_KEY", raw.supabaseAnonKey);
  },
  get vapidPublicKey() {
    return raw.vapidPublicKey;
  },
  get mapTileUrl() {
    return raw.mapTileUrl || OSM_TILES;
  },
  get mapTileAttribution() {
    return raw.mapTileAttribution || OSM_ATTRIBUTION;
  },
  /** Link do app na Play Store. Sem ele, o convite oferece só instalar o site. */
  get playStoreUrl() {
    return raw.playStoreUrl || null;
  },
};

export const functionsUrl = () => `${env.supabaseUrl}/functions/v1`;
