#!/usr/bin/env bash
# Lance le serveur de conformité, exécute les tests StaminaKit sur le simulateur, arrête le serveur.
#   scripts/test.sh [udid-du-simulateur]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/../stamina-sdk-conformance/server.js"
UDID="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import sys,json; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for v in d.values() for x in v if x["state"]=="Booted"))')}"
PORT="${CONFORMANCE_PORT:-4999}"
DD="${DERIVED_DATA:-/tmp/staminakit-dd}"

node "$CONF" --port "$PORT" > /tmp/stamina-conformance.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1

cd "$ROOT"
xcodebuild test -scheme StaminaKit -destination "id=$UDID" -derivedDataPath "$DD" \
  STAMINA_CONFORMANCE_URL="http://127.0.0.1:$PORT" 2>&1 | tee /tmp/staminakit-test.log \
  | grep -E "Test Case .* (passed|failed|skipped)|error:|TEST (SUCCEEDED|FAILED)|Executed" || true
grep -q "TEST SUCCEEDED" /tmp/staminakit-test.log
