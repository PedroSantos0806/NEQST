#!/usr/bin/env bash
#
# As funções publicadas estão de pé?
#
# Responde a pergunta que só aparecia no meio de um teste na quadra:
# publiquei tudo, e tudo subiu? Cada função responde ao preflight
# (OPTIONS) dentro dela mesma, sem JWT — então 204 quer dizer "o worker
# iniciou", e é isso que esta sonda procura.
#
# Nasceu de um 503 em produção: o `scan-court` foi publicado com um
# `index.ts` novo e um `_shared/qr.ts` velho, e o worker nem iniciava.
# Todo request virava 503, inclusive o preflight, e o app só dizia
# "a função respondeu com erro (503)".
#
# Uso:
#   scripts/smoke-functions.sh https://<project-ref>.supabase.co
#   SUPABASE_URL=https://... scripts/smoke-functions.sh
#
set -uo pipefail

BASE="${1:-${SUPABASE_URL:-}}"
if [[ -z "$BASE" ]]; then
  echo "uso: $0 https://<project-ref>.supabase.co" >&2
  exit 2
fi
BASE="${BASE%/}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A lista sai do repositório: escrita à mão, ela envelhece e a função
# esquecida só aparece como 404 no meio de um teste.
mapfile -t FUNCOES < <(
  find "$ROOT/supabase/functions" -mindepth 1 -maxdepth 1 -type d \
    -not -name "_*" -printf "%f\n" | sort
)

echo "▶ ${#FUNCOES[@]} funções em $BASE"
echo

falhas=0
for fn in "${FUNCOES[@]}"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 \
         -X OPTIONS "$BASE/functions/v1/$fn" 2>/dev/null || echo "000")

  case "$code" in
    200|204)
      printf "  ✔ %-24s no ar\n" "$fn" ;;
    503)
      printf "  ✘ %-24s 503 — o worker NÃO inicia\n" "$fn"
      printf "    %-24s   publique de novo TODAS as funções; um deploy\n" ""
      printf "    %-24s   parcial deixa o _shared desatualizado\n" ""
      falhas=$((falhas + 1)) ;;
    404)
      printf "  ✘ %-24s 404 — nunca foi publicada\n" "$fn"
      falhas=$((falhas + 1)) ;;
    000)
      printf "  ✘ %-24s sem resposta (rede ou URL errada)\n" "$fn"
      falhas=$((falhas + 1)) ;;
    *)
      printf "  ? %-24s HTTP %s — veja os logs da função\n" "$fn" "$code"
      falhas=$((falhas + 1)) ;;
  esac
done

echo
if (( falhas )); then
  echo "✘ $falhas função(ões) com problema."
  echo "  Conserto quase sempre: npx supabase functions deploy  (sem argumentos)"
  exit 1
fi
echo "✔ todas as funções responderam ao preflight."
