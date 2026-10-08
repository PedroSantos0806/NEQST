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
};

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
};

export const functionsUrl = () => `${env.supabaseUrl}/functions/v1`;
