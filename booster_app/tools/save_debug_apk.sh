#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ROOT="$ROOT_DIR/booster_app"
SOURCE_APK="$APP_ROOT/build/app/outputs/flutter-apk/app-debug.apk"
SAVED_DIR="$ROOT_DIR/saved-builds"
KEEP_COUNT=10
PRUNE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP_COUNT="$2"
      shift 2
      ;;
    --no-prune)
      PRUNE=false
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--keep <count>] [--no-prune]"
      echo
      echo "Saves the current debug APK to /saved-builds with checksum metadata."
      echo
      echo "  --keep <count>  Keep only the newest <count> timestamped backups (default: 10)"
      echo "  --no-prune      Do not delete old timestamped backups"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$KEEP_COUNT" =~ ^[0-9]+$ ]]; then
  echo "[error] --keep must be a non-negative integer" >&2
  exit 1
fi

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

# Keep latest as a symlink to avoid duplicating large APK files.
ln -sfn "$(basename "$saved_apk")" "$latest_apk"

(
  cd "$SAVED_DIR"
  sha256sum "$(basename "$saved_apk")" > "$(basename "$saved_apk").sha256"
  sha256sum "$(basename "$latest_apk")" > "app-debug-latest.sha256"
)

# Fail early if file corruption is detected immediately after save.
saved_hash="$(sha256sum "$saved_apk" | awk '{print $1}')"
latest_hash="$(sha256sum "$latest_apk" | awk '{print $1}')"
if [[ "$saved_hash" != "$latest_hash" ]]; then
  echo "[error] Latest APK hash mismatch after save" >&2
  exit 1
fi

if [[ "$PRUNE" == true && "$KEEP_COUNT" -gt 0 ]]; then
  mapfile -t old_backups < <(ls -1t "$SAVED_DIR"/app-debug-20*.apk 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) || true)
  for old_apk in "${old_backups[@]}"; do
    rm -f "$old_apk" "$old_apk.sha256"
  done
fi

echo "[done] Saved timestamped APK: $saved_apk"
echo "[done] Updated latest APK:     $latest_apk"
echo "[info] Checksum:"
cat "$saved_apk.sha256"
if [[ "$PRUNE" == true ]]; then
  echo "[info] Retention: keeping newest $KEEP_COUNT timestamped backups"
fi