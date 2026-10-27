import { defineConfig } from "vitest/config";

/**
 * Config própria para os testes: o `vite.config.ts` injeta as
 * variáveis do deploy, que não existem aqui. Sem elas o módulo do
 * Supabase lança ao ser importado — de propósito, é o que impede o app
 * de subir meio configurado (ver `main.tsx`).
 *
 * Os valores abaixo são inertes: nenhum teste faz chamada de rede.
 */
export default defineConfig({
  define: {
    "import.meta.env.VITE_SUPABASE_URL": JSON.stringify("https://teste.supabase.co"),
    "import.meta.env.VITE_SUPABASE_ANON_KEY": JSON.stringify("chave-de-teste"),
    "import.meta.env.VITE_VAPID_PUBLIC_KEY": JSON.stringify(""),
    "import.meta.env.VITE_MAP_TILE_URL": JSON.stringify(""),
    "import.meta.env.VITE_MAP_TILE_ATTRIBUTION": JSON.stringify(""),
  },
  test: {
    include: ["src/**/*.test.ts", "src/**/*.test.tsx"],
    // jsdom porque o código testado é de navegador: `window.location`,
    // `sessionStorage` e `fetch` aparecem no caminho real.
    environment: "jsdom",
  },
});
