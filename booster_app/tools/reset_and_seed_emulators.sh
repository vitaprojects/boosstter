#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${FIREBASE_PROJECT_ID:-booster-da72c}"
AUTH_HOST="${FIREBASE_AUTH_EMULATOR_HOST:-127.0.0.1:9099}"
FIRESTORE_HOST="${FIRESTORE_EMULATOR_HOST:-127.0.0.1:8080}"
DB_HOST="${FIREBASE_DATABASE_EMULATOR_HOST:-127.0.0.1:9000}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SEED_SCRIPT="$ROOT_DIR/tools/seed_emulators.mjs"

require_up() {
  local name="$1"
  local url="$2"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
  if [[ "$code" == "000" || -z "$code" ]]; then
    echo "[error] $name emulator is not reachable at $url"
    echo "[hint] Start emulators first: firebase emulators:start --only auth,firestore,database"
    exit 1
  fi
}

echo "[info] Checking emulator connectivity..."
require_up "Auth" "http://${AUTH_HOST}/"
require_up "Firestore" "http://${FIRESTORE_HOST}/"
require_up "Realtime Database" "http://${DB_HOST}/.json"

echo "[info] Clearing Auth emulator users..."
curl -sS -X DELETE "http://${AUTH_HOST}/emulator/v1/projects/${PROJECT_ID}/accounts" >/dev/null

echo "[info] Clearing Firestore emulator documents..."
curl -sS -X DELETE "http://${FIRESTORE_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents" >/dev/null

echo "[info] Clearing Realtime Database emulator data..."
curl -sS -X DELETE "http://${DB_HOST}/.json" >/dev/null

echo "[info] Reseeding emulator data..."
node "$SEED_SCRIPT"

echo "[done] Emulator data reset and reseeded."
