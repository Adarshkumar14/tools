#!/usr/bin/env bash
#
# avgprom_env: Average the current value for a Prometheus query using env vars
#
# Usage:
#   PROM_URL=http://localhost:9090 PROM_QUERY=node_memory_MemFree_bytes ./avgprom_env
#
# Dependencies: curl, jq

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

PROM_URL="${PROM_URL:-}"
PROM_QUERY="${PROM_QUERY:-}"

if [[ -z "$PROM_URL" || -z "$PROM_QUERY" ]]; then
  echo "Usage: PROM_URL=<prometheus_url> PROM_QUERY=<promql_query> $0"
  exit 1
fi

QUERY_URL="${PROM_URL%/}/api/v1/query"
response_json="$(curl -fsS --get "$QUERY_URL" \
  --data-urlencode "query=${PROM_QUERY}" \
  || die "Failed to reach Prometheus at $PROM_URL")"

avg="$(jq -er '
  if .status != "success" then
      halt_error(3)
  else
      .data.result
      | map(.value[1] | tonumber)
      | select(length > 0)
      | (add/length)
  end
'  <<<"$response_json" 2>/dev/null)" || {
    ec=$?; [[ $ec -eq 3 ]] && die "Prometheus error: $(jq -r ".error // .errorType" <<<"$response_json")"
    die "Query \"$PROM_QUERY\" returned no samples"
}

printf '%s\n' "$avg"
