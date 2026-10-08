/**
 * Configuração que vem do build (Vercel > Settings > Environment Variables).
 * Só chaves públicas: a anon key do Supabase e a chave VAPID pública.
 */
function required(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(
      `Variável ${name} não configurada. Defina-a no ambiente da Vercel (ou no .env local).`,
    );
  }
  return value;
}

export const env = {
  supabaseUrl: required("VITE_SUPABASE_URL", import.meta.env.VITE_SUPABASE_URL),
  supabaseAnonKey: required("VITE_SUPABASE_ANON_KEY", import.meta.env.VITE_SUPABASE_ANON_KEY),
  // Opcional: sem ela o app só não oferece notificações.
  vapidPublicKey: import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined,
};

export function isConfigured(): boolean {
  return Boolean(
    import.meta.env.VITE_SUPABASE_URL && import.meta.env.VITE_SUPABASE_ANON_KEY,
  );
}

export const functionsUrl = () => `${env.supabaseUrl}/functions/v1`;
