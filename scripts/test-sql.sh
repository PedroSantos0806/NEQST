#!/usr/bin/env bash
#
# Roda as migrations + os testes funcionais de SQL contra um Postgres
# descartável. Usado localmente e na CI.
#
# Uso:
#   scripts/test-sql.sh                      # sobe um cluster temporário
#   DATABASE_URL=postgres://... scripts/test-sql.sh   # usa um banco existente
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL_ARGS=(-v ON_ERROR_STOP=1 -q)

if [[ -n "${DATABASE_URL:-}" ]]; then
  run_psql() { psql "$DATABASE_URL" "${PSQL_ARGS[@]}" "$@"; }
else
  PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
  TMPDIR_PG="$(mktemp -d)"
  PORT="${PGPORT:-55432}"

  cleanup() {
    "$PGBIN/pg_ctl" -D "$TMPDIR_PG/data" stop -m immediate >/dev/null 2>&1 || true
    rm -rf "$TMPDIR_PG"
  }
  trap cleanup EXIT

  "$PGBIN/initdb" -D "$TMPDIR_PG/data" -U postgres --auth=trust >/dev/null
  "$PGBIN/pg_ctl" -D "$TMPDIR_PG/data" \
    -o "-p $PORT -k $TMPDIR_PG -c listen_addresses=''" \
    -l "$TMPDIR_PG/pg.log" start >/dev/null

  run_psql() { psql -h "$TMPDIR_PG" -p "$PORT" -U postgres -d neqst "${PSQL_ARGS[@]}" "$@"; }
  psql -h "$TMPDIR_PG" -p "$PORT" -U postgres -d postgres -q -c 'create database neqst;'
fi

echo "▶ stub do ambiente Supabase (auth.users / auth.uid)"
run_psql -f "$ROOT/tests/local/00_supabase_stub.sql" >/dev/null

echo "▶ migrations"
for migration in "$ROOT"/supabase/migrations/*.sql; do
  echo "  · $(basename "$migration")"
  run_psql -f "$migration" >/dev/null
done

echo "▶ testes funcionais"
for test_file in "$ROOT"/tests/local/[1-9]*.sql; do
  run_psql -f "$test_file"
done

echo "✔ SQL OK"
