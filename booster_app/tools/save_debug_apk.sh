#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ROOT="$ROOT_DIR/booster_app"
SOURCE_APK="$APP_ROOT/build/app/outputs/flutter-apk/app-debug.apk"
SAVED_DIR="$ROOT_DIR/saved-builds"

if [[ ! -f "$SOURCE_APK" ]]; then
  echo "[error] Debug APK not found at: $SOURCE_APK" >&2
  echo "[hint] Build one first: cd $APP_ROOT && ../flutter/bin/flutter build apk --debug" >&2
  exit 1
fi

mkdir -p "$SAVED_DIR"

timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
saved_apk="$SAVED_DIR/app-debug-${timestamp}.apk"
latest_apk="$SAVED_DIR/app-debug-latest.apk"

cp "$SOURCE_APK" "$saved_apk"
cp "$SOURCE_APK" "$latest_apk"

sha256sum "$saved_apk" > "$saved_apk.sha256"
sha256sum "$latest_apk" > "$SAVED_DIR/app-debug-latest.sha256"

echo "[done] Saved timestamped APK: $saved_apk"
echo "[done] Updated latest APK:     $latest_apk"
echo "[info] Checksum:"
cat "$saved_apk.sha256"