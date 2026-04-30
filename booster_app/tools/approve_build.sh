#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_ROOT="$ROOT_DIR/booster_app"
BUILD_AND_SAVE_SCRIPT="$APP_ROOT/tools/build_and_save_debug_apk.sh"
UPLOAD_SCRIPT="$APP_ROOT/tools/upload_debug_apk_release.sh"
LATEST_APK_LINK="$ROOT_DIR/saved-builds/app-debug-latest.apk"
LATEST_SHA_FILE="$ROOT_DIR/saved-builds/app-debug-latest.sha256"

REPO=""
COMMIT_MESSAGE=""
TAG_NAME=""
KEEP_COUNT=30
PRUNE=true
PUSH_CHANGES=true

usage() {
  cat <<EOF
Usage: $0 [options]

Automates approved build flow:
1) stage + commit current changes
2) create and push a git tag
3) build + save debug APK
4) upload APK to GitHub Release
5) print a summary with commit/tag/release/checksum

Options:
  --repo <owner/name>       GitHub repo for release upload (default: auto-detect)
  --message <text>          Commit message (default: prompts with a timestamped suggestion)
  --tag <name>              Git tag to create (default: prompts with approved-<timestamp>)
  --keep <count>            Keep newest saved APK backups (default: 30)
  --no-prune                Do not prune old APK backups
  --no-push                 Skip git push for branch and tag
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --message)
      COMMIT_MESSAGE="$2"
      shift 2
      ;;
    --tag)
      TAG_NAME="$2"
      shift 2
      ;;
    --keep)
      KEEP_COUNT="$2"
      shift 2
      ;;
    --no-prune)
      PRUNE=false
      shift
      ;;
    --no-push)
      PUSH_CHANGES=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[error] Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$KEEP_COUNT" =~ ^[0-9]+$ ]]; then
  echo "[error] --keep must be a non-negative integer" >&2
  exit 1
fi

cd "$ROOT_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[error] Not inside a git repository: $ROOT_DIR" >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" == "HEAD" ]]; then
  echo "[error] Detached HEAD state detected. Checkout a branch first." >&2
  exit 1
fi

default_message="Approved build: $(date +%Y-%m-%d_%H-%M-%S)"
if [[ -z "$COMMIT_MESSAGE" ]]; then
  read -r -p "Commit message [$default_message]: " user_message
  COMMIT_MESSAGE="${user_message:-$default_message}"
fi

default_tag="approved-$(date +%Y-%m-%d-%H%M%S)"
if [[ -z "$TAG_NAME" ]]; then
  read -r -p "Tag name [$default_tag]: " user_tag
  TAG_NAME="${user_tag:-$default_tag}"
fi

if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  echo "[error] Tag already exists: $TAG_NAME" >&2
  exit 1
fi

echo "[info] Staging changes..."
git add -A

has_staged_changes=false
if ! git diff --cached --quiet; then
  has_staged_changes=true
fi

if [[ "$has_staged_changes" == true ]]; then
  echo "[info] Creating commit..."
  git commit -m "$COMMIT_MESSAGE"
else
  echo "[warn] No staged changes detected. Reusing current HEAD commit."
fi

commit_sha="$(git rev-parse HEAD)"

echo "[info] Creating tag: $TAG_NAME"
git tag "$TAG_NAME"

if [[ "$PUSH_CHANGES" == true ]]; then
  echo "[info] Pushing branch and tag to origin..."
  git push origin "$current_branch"
  git push origin "$TAG_NAME"
else
  echo "[warn] Skipping git push (--no-push set)."
fi

save_args=(--keep "$KEEP_COUNT" --no-upload)
if [[ "$PRUNE" == false ]]; then
  save_args+=(--no-prune)
fi

echo "[info] Building and saving debug APK..."
cd "$APP_ROOT"
"$BUILD_AND_SAVE_SCRIPT" "${save_args[@]}"

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null || true)"
fi

if [[ -z "$REPO" ]]; then
  echo "[error] Could not determine GitHub repo. Use --repo <owner/name>." >&2
  exit 1
fi

echo "[info] Uploading APK release to $REPO..."
upload_output="$($UPLOAD_SCRIPT --repo "$REPO")"
printf '%s\n' "$upload_output"

release_url="$(printf '%s\n' "$upload_output" | awk -F':   ' '/Release page/ {print $2}')"
download_url="$(printf '%s\n' "$upload_output" | awk -F':   ' '/Download URL/ {print $2}')"
latest_apk_path="$(readlink -f "$LATEST_APK_LINK")"
latest_sha=""
if [[ -f "$LATEST_SHA_FILE" ]]; then
  latest_sha="$(awk '{print $1}' "$LATEST_SHA_FILE")"
fi

echo
echo "[summary] Approved build completed"
echo "[summary] Branch:        $current_branch"
echo "[summary] Commit:        $commit_sha"
echo "[summary] Tag:           $TAG_NAME"
echo "[summary] APK:           $latest_apk_path"
if [[ -n "$latest_sha" ]]; then
  echo "[summary] SHA256:        $latest_sha"
fi
if [[ -n "$release_url" ]]; then
  echo "[summary] Release page:  $release_url"
fi
if [[ -n "$download_url" ]]; then
  echo "[summary] Download URL:  $download_url"
fi
