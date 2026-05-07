#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/safe_publish.sh [--no-prune] [--apk PATH] [--tag TAG] [--name ASSET_NAME]

Publishes a debug APK asset to a GitHub release using gh CLI.

Options:
  --no-prune       Keep existing release assets (default removes old asset with same name)
  --apk PATH       Path to source APK (default: build/app/outputs/flutter-apk/app-debug.apk)
  --tag TAG        Release tag (default: apk-debug-latest)
  --name NAME      Asset name in release (default: app-debug-latest.apk)
  -h, --help       Show this help
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_APK_REL="build/app/outputs/flutter-apk/app-debug.apk"
APK_PATH="$ROOT_DIR/$DEFAULT_APK_REL"
RELEASE_TAG="apk-debug-latest"
ASSET_NAME="app-debug-latest.apk"
NO_PRUNE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-prune)
      NO_PRUNE=true
      ;;
    --apk)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --apk" >&2; exit 1; }
      if [[ "$1" = /* ]]; then
        APK_PATH="$1"
      else
        APK_PATH="$ROOT_DIR/$1"
      fi
      ;;
    --tag)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --tag" >&2; exit 1; }
      RELEASE_TAG="$1"
      ;;
    --name)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --name" >&2; exit 1; }
      ASSET_NAME="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required but not found in PATH." >&2
  exit 1
fi

cd "$ROOT_DIR"

if [[ ! -f "$APK_PATH" ]]; then
  echo "APK not found at: $APK_PATH" >&2
  echo "Build it first, for example:" >&2
  echo "  ../flutter/bin/flutter build apk --debug" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

# Create release if it does not exist yet.
if ! gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  gh release create "$RELEASE_TAG" --title "$RELEASE_TAG" --notes "Automated debug APK release"
fi

if [[ "$NO_PRUNE" == false ]]; then
  gh release delete-asset "$RELEASE_TAG" "$ASSET_NAME" -y >/dev/null 2>&1 || true
fi

gh release upload "$RELEASE_TAG" "$APK_PATH#$ASSET_NAME" --clobber

echo "Published: $ASSET_NAME"
echo "Tag: $RELEASE_TAG"
