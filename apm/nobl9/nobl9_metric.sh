#!/bin/bash
set -euo pipefail

# --- 1. ENVIRONMENT VARIABLES (edit as needed or export before running) ---
# Required:
#   N9_CLIENT_ID, N9_CLIENT_SECRET, N9_ORG, N9_SLO_PROJECT, N9_SLO_NAME, N9_SLO_OBJECTIVE, N9_METRIC, N9_TIMEFRAME
#
# Example:
# export N9_CLIENT_ID=''
# export N9_CLIENT_SECRET=''
# export N9_ORG='demo'
# export N9_SLO_PROJECT=''
# export N9_SLO_NAME=''
# export N9_SLO_OBJECTIVE=''
# export N9_METRIC='burnRate'
# export N9_TIMEFRAME='now-10m'

# --- Ensure jq is installed ---
if ! command -v jq &>/dev/null; then

  INSTALL_PATH="/usr/local/bin/jq"
  TMP_JQ="/tmp/jq"

  # Try to install to /usr/local/bin/jq, fallback to ~/.local/bin/jq if no sudo
  if [ -w /usr/local/bin ]; then
    curl -fsSL -o "$TMP_JQ" "https://app.harness.io/public/shared/tools/chaos/offline-installer/linux/jq-linux64"
    install -m 755 "$TMP_JQ" "$INSTALL_PATH"
  else
    mkdir -p "$HOME/.local/bin"
    curl -fsSL -o "$HOME/.local/bin/jq" "https://app.harness.io/public/shared/tools/chaos/offline-installer/linux/jq-linux64"
    sudo chmod +x "$HOME/.local/bin/jq"
    export PATH="$HOME/.local/bin:$PATH"
  fi

  # Double check
  if ! command -v jq &>/dev/null; then
    exit 10
  fi
fi

for var in N9_CLIENT_ID N9_CLIENT_SECRET N9_ORG N9_SLO_PROJECT N9_SLO_NAME N9_SLO_OBJECTIVE N9_METRIC N9_TIMEFRAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing env variable: $var" >&2; exit 1
  fi
done

# --- 2. TIME WINDOW PROCESSING ---
TF="$N9_TIMEFRAME"
if [[ "$TF" =~ now-([0-9]+)([smhd]) ]]; then
  AMOUNT="${BASH_REMATCH[1]}"
  UNIT="${BASH_REMATCH[2]}"
else
  echo "Invalid N9_TIMEFRAME format. Use e.g. now-10m, now-1h, now-2d" >&2
  exit 2
fi

# Use GNU date for cross-platform compatibility; fallback to gdate on Mac
DATEBIN=date
if ! date -u +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
    if command -v gdate >/dev/null 2>&1; then
        DATEBIN=gdate
    else
        echo "GNU date or gdate required (brew install coreutils on MacOS)" >&2
        exit 2
    fi
fi

case "$UNIT" in
  s) DELTA="${AMOUNT} seconds" ;;
  m) DELTA="${AMOUNT} minutes" ;;
  h) DELTA="${AMOUNT} hours" ;;
  d) DELTA="${AMOUNT} days" ;;
  *) echo "Invalid unit in N9_TIMEFRAME: $UNIT" >&2; exit 2 ;;
esac

TO_UTC=$($DATEBIN -u +"%Y-%m-%dT%H:%M:%SZ")
FROM_UTC=$($DATEBIN -u -d "$DELTA ago" +"%Y-%m-%dT%H:%M:%SZ")

# --- 3. GET API TOKEN ---
AUTH=$(echo -n "${N9_CLIENT_ID}:${N9_CLIENT_SECRET}" | base64 -w 0)
TOKEN=$(curl -s -X POST "https://app.nobl9.com/api/accessToken" \
  -H "Accept: application/json; version=v1alpha" \
  -H "Organization: ${N9_ORG}" \
  -H "Authorization: Basic ${AUTH}" | jq -r '.access_token')
if [[ "$TOKEN" = "null" || -z "$TOKEN" ]]; then
  echo "Failed to obtain token"; exit 3
fi

# --- 4. FETCH SLOs (LIST ENDPOINT, with TIME WINDOW) ---
API_URL="https://app.nobl9.com/api/v2/slos?project=${N9_SLO_PROJECT}&from=${FROM_UTC}&to=${TO_UTC}"
RESP=$(curl -s -X GET "$API_URL" \
    -H "Accept: application/json; version=v1alpha" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Organization: ${N9_ORG}")

# --- 5. EXTRACT DESIRED METRIC ---
VAL=$(echo "$RESP" | jq -r --arg slo "$N9_SLO_NAME" --arg obj "$N9_SLO_OBJECTIVE" --arg met "$N9_METRIC" '
  .data[]
  | select(.name==$slo)
  | .objectives[]
  | select(.name==$obj)
  | .[$met]
')

if [[ -n "$VAL" && "$VAL" != "null" ]]; then
    echo "$VAL"
else
    echo "SLO/objective/metric not found."; exit 4
fi
