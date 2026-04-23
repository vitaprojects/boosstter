#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ROOT="$ROOT_DIR/booster_app"
SAVE_SCRIPT="$APP_ROOT/tools/save_debug_apk.sh"

echo "[info] Building debug APK..."
cd "$APP_ROOT"
../flutter/bin/flutter build apk --debug "$@"

echo "[info] Saving build artifact..."
"$SAVE_SCRIPT"