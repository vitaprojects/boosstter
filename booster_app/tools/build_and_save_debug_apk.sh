#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ROOT="$ROOT_DIR/booster_app"
SAVE_SCRIPT="$APP_ROOT/tools/save_debug_apk.sh"
UPLOAD_SCRIPT="$APP_ROOT/tools/upload_debug_apk_release.sh"
SOURCE_APK="$APP_ROOT/build/app/outputs/flutter-apk/app-debug.apk"
ROOT_APK="$ROOT_DIR/app-debug.apk"

UPLOAD_AFTER_SAVE=true
save_args=()
build_args=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--keep)
			save_args+=("$1" "$2")
			shift 2
			;;
		--no-prune)
			save_args+=("$1")
			shift
			;;
		--no-upload)
			UPLOAD_AFTER_SAVE=false
			shift
			;;
		*)
			build_args+=("$1")
			shift
			;;
	esac
done

echo "[info] Building debug APK..."
cd "$APP_ROOT"
../flutter/bin/flutter build apk --debug "${build_args[@]}"

echo "[info] Saving build artifact..."
"$SAVE_SCRIPT" "${save_args[@]}"

echo "[info] Refreshing workspace APK..."
cp "$SOURCE_APK" "$ROOT_APK"

if [[ "$UPLOAD_AFTER_SAVE" == true ]]; then
	echo "[info] Uploading saved APK to GitHub release..."
	"$UPLOAD_SCRIPT"
fi