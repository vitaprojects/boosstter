#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SAVED_DIR="$ROOT_DIR/saved-builds"
LATEST_APK_LINK="$SAVED_DIR/app-debug-latest.apk"
TAG_PREFIX="apk-debug"
RELEASE_NOTES="Automated debug APK upload."
REPO=""
APK_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --apk)
      APK_PATH="$2"
      shift 2
      ;;
    --tag-prefix)
      TAG_PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--repo <owner/name>] [--apk <path>] [--tag-prefix <prefix>]"
      echo
      echo "Uploads the latest saved debug APK to a GitHub release and prints the direct download URL."
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$APK_PATH" ]]; then
  if [[ ! -L "$LATEST_APK_LINK" && ! -f "$LATEST_APK_LINK" ]]; then
    echo "[error] Latest APK link not found at: $LATEST_APK_LINK" >&2
    echo "[hint] Save one first: $ROOT_DIR/booster_app/tools/save_debug_apk.sh" >&2
    exit 1
  fi
  APK_PATH="$(readlink -f "$LATEST_APK_LINK")"
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "[error] APK file not found at: $APK_PATH" >&2
  exit 1
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null || true)"
fi

if [[ -z "$REPO" ]]; then
  echo "[error] Could not determine GitHub repository. Pass --repo <owner/name>." >&2
  exit 1
fi

apk_name="$(basename "$APK_PATH")"
timestamp="${apk_name#app-debug-}"
timestamp="${timestamp%.apk}"
release_tag="${TAG_PREFIX}-${timestamp//_/-}"
release_title="Debug APK ${timestamp//_/ }"

if gh release view "$release_tag" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$release_tag" "$APK_PATH" --repo "$REPO" --clobber >/dev/null
else
  gh release create "$release_tag" "$APK_PATH" \
    --repo "$REPO" \
    --title "$release_title" \
    --notes "$RELEASE_NOTES" >/dev/null
fi

release_json="$(gh release view "$release_tag" --repo "$REPO" --json url,assets)"
download_url="$(printf '%s' "$release_json" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["assets"][0]["url"] if data["assets"] else "")')"
release_url="$(printf '%s' "$release_json" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["url"])')"

if [[ -z "$download_url" ]]; then
  echo "[error] Release asset upload completed but no asset URL was returned." >&2
  exit 1
fi

echo "[done] Release page:   $release_url"
echo "[done] Download URL:   $download_url"