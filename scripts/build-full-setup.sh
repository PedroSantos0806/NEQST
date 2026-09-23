#!/usr/bin/env bash
#
# Concatena as migrations num único arquivo, pronto para colar no
# SQL Editor do Supabase (Dashboard > SQL Editor > New query).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/db/full_setup.sql"

{
  cat <<'HEADER'
-- =====================================================================
-- NEQST — script único de criação do banco (Sprint 1)
--
-- GERADO AUTOMATICAMENTE por scripts/build-full-setup.sh.
-- Não edite este arquivo: altere supabase/migrations/*.sql e rode o
-- script novamente.
--
-- Como usar:
--   Supabase Dashboard > SQL Editor > New query > cole tudo > Run.
--   Ou:  psql "$DATABASE_URL" -f db/full_setup.sql
--
-- É idempotente: pode ser executado mais de uma vez no mesmo projeto.
-- =====================================================================

HEADER

  for migration in "$ROOT"/supabase/migrations/*.sql; do
    printf '\n\n-- ####################################################################\n'
    printf -- '-- Origem: supabase/migrations/%s\n' "$(basename "$migration")"
    printf -- '-- ####################################################################\n\n'
    cat "$migration"
  done
} > "$OUTPUT"

echo "✔ $OUTPUT ($(wc -l < "$OUTPUT") linhas)"
