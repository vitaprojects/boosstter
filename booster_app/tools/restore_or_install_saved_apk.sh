#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ROOT="$ROOT_DIR/booster_app"
SAVED_DIR="$ROOT_DIR/saved-builds"
OUTPUT_APK="$APP_ROOT/build/app/outputs/flutter-apk/app-debug.apk"

APK_PATH="$SAVED_DIR/app-debug-latest.apk"
INSTALL=false
DEVICE_ID=""
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apk)
      APK_PATH="$2"
      shift 2
      ;;
    --install)
      INSTALL=true
      shift
      ;;
    --device)
      DEVICE_ID="$2"
      shift 2
      ;;
    --list)
      LIST_ONLY=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--apk /path/to/file.apk] [--install] [--device <adb-id>] [--list]"
      echo
      echo "Restores a saved APK into build output so you can continue without rebuilding."
      echo
      echo "  --apk <path>   Restore a specific APK (default: saved-builds/app-debug-latest.apk)"
      echo "  --install      Also run adb install -r after restore"
      echo "  --device <id>  Optional device id for adb -s"
      echo "  --list         List saved APK backups"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ "$LIST_ONLY" == true ]]; then
  if [[ -d "$SAVED_DIR" ]]; then
    ls -1t "$SAVED_DIR"/app-debug-*.apk 2>/dev/null || true
  else
    echo "[info] No saved-builds directory yet: $SAVED_DIR"
  fi
  exit 0
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "[error] APK not found: $APK_PATH" >&2
  echo "[hint] Save one first with: $APP_ROOT/tools/save_debug_apk.sh" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_APK")"
cp "$APK_PATH" "$OUTPUT_APK"

echo "[done] Restored APK to: $OUTPUT_APK"
echo "[info] Restored checksum:"
sha256sum "$OUTPUT_APK"

if [[ "$INSTALL" == false ]]; then
  exit 0
fi

if ! command -v adb >/dev/null 2>&1; then
  echo "[error] adb not found in PATH; install Android platform-tools first." >&2
  exit 1
fi

adb_args=()
if [[ -n "$DEVICE_ID" ]]; then
  adb_args+=("-s" "$DEVICE_ID")
fi

echo "[info] Installing APK via adb..."
adb "${adb_args[@]}" install -r "$OUTPUT_APK"
echo "[done] Install complete."