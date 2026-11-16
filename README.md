# NEQST CRM

CRM interno do NEQST para a venda B2B (parques, clubes, condomínios, anunciantes) e a implantação dos totens.
Regras do produto, modelo de dados, funis e decisões: **[CLAUDE.md](CLAUDE.md)**.

## O que tem

- **Funis** (tela inicial): kanban dos 4 funis com arrastar e soltar, totais por coluna, alerta de parado,
  campos obrigatórios por etapa, ganho/perda e atualização ao vivo; vista em tabela com filtros.
- **Ficha do negócio**: etapas, atividades, notas e linha do tempo.
- **Contatos, Empresas e Locais** (parques/unidades), com ficha do contato e "Criar negócio".
- **Tarefas**: minhas e do time, atrasadas/hoje/próximas, e negócios sem próxima atividade.

Pausados por enquanto (foco no CRM): Prospecção, Entrada de leads e WhatsApp. O banco e o código das Edge Functions
ficam guardados; veja "Foco atual" no [CLAUDE.md](CLAUDE.md).

## Stack

React + Vite + TypeScript + Tailwind + shadcn/ui · TanStack Query · Supabase (Postgres, Auth, RLS, Realtime,
Edge Functions, Vault).

## Rodar local

```bash
npm install
cp .env.example .env.local   # preencha VITE_SUPABASE_ANON_KEY (chave pública do projeto)
npm run dev                  # http://localhost:5173
```

O banco é o projeto Supabase na nuvem (não há banco local). Acesso ao app só por convite.

## Banco e funções

```bash
npx supabase login
npx supabase link --project-ref <ref-do-projeto>
npm run db:diff     # mostra o que a migration vai mudar
npm run db:push     # aplica migrations + seed
npm run db:types    # regenera src/types/database.ts
npx supabase functions deploy <nome> --remote
```

Segredos (Gemini, Evolution, Meta) ficam só nos secrets das Edge Functions ou no Vault — nunca no repositório.

## Verificação

```bash
npm run typecheck
npm run lint
npm run build
```
