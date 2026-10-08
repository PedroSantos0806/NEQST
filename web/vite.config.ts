import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

/**
 * O Vite só entrega ao navegador variáveis com prefixo VITE_. Como na
 * Vercel elas acabaram nomeadas sem o prefixo, injetamos as três
 * explicitamente, aceitando os dois nomes.
 *
 * É uma lista fechada de propósito: ligar um prefixo genérico como
 * `SUPABASE_` exporia qualquer variável com esse começo — inclusive uma
 * SUPABASE_SERVICE_ROLE_KEY, que ignora o RLS e ficaria legível no
 * bundle que todo mundo baixa.
 */
export default defineConfig(({ mode }) => {
  const fileEnv = loadEnv(mode, process.cwd(), "");

  const pick = (...names: string[]) =>
    names.map((name) => process.env[name] ?? fileEnv[name]).find(Boolean) ?? "";

  return {
    plugins: [react()],
    define: {
      "import.meta.env.VITE_SUPABASE_URL": JSON.stringify(
        pick("VITE_SUPABASE_URL", "SUPABASE_URL"),
      ),
      "import.meta.env.VITE_SUPABASE_ANON_KEY": JSON.stringify(
        pick("VITE_SUPABASE_ANON_KEY", "SUPABASE_ANON_KEY"),
      ),
      "import.meta.env.VITE_VAPID_PUBLIC_KEY": JSON.stringify(
        pick("VITE_VAPID_PUBLIC_KEY", "VAPID_PUBLIC_KEY"),
      ),
    },
    build: { outDir: "dist", sourcemap: true },
    server: { port: 5173 },
  };
});
