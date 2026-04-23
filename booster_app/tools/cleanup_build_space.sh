#!/usr/bin/env bash

set -euo pipefail

DRY_RUN=false
CLEAN_PUB_CACHE=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run)
			DRY_RUN=true
			;;
		--include-pub-cache)
			CLEAN_PUB_CACHE=true
			;;
		-h|--help)
			echo "Usage: $0 [--dry-run] [--include-pub-cache]"
			echo
			echo "Removes reproducible build artifacts and caches to free disk space."
			echo
			echo "  --dry-run            Show what would be removed without deleting files"
			echo "  --include-pub-cache  Also remove ~/.pub-cache (slower next flutter pub get)"
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
	esac
	shift
done

ROOT="/workspaces/boosstter"
APP_ROOT="$ROOT/booster_app"
FLUTTER_CACHE="$ROOT/flutter/bin/cache"
GRADLE_CACHE="/home/codespace/.gradle/caches"
PUB_CACHE="/home/codespace/.pub-cache"

TARGETS=(
	"$APP_ROOT/build"
	"$ROOT/app-debug.apk"
	"$FLUTTER_CACHE"
	"$GRADLE_CACHE"
)

if [[ "$CLEAN_PUB_CACHE" == true ]]; then
	TARGETS+=("$PUB_CACHE")
fi

print_size() {
	local path="$1"
	if [[ -e "$path" ]]; then
		du -sh "$path" 2>/dev/null | awk '{print $1}'
	else
		echo "0B"
	fi
}

echo "Cleanup mode: $([[ "$DRY_RUN" == true ]] && echo 'dry-run' || echo 'delete')"
echo

for target in "${TARGETS[@]}"; do
	printf '%-50s %10s\n' "$target" "$(print_size "$target")"
done

echo

if [[ "$DRY_RUN" == true ]]; then
	echo "No files removed."
	exit 0
fi

for target in "${TARGETS[@]}"; do
	if [[ -e "$target" ]]; then
		rm -rf "$target"
	fi
done

mkdir -p "$FLUTTER_CACHE"

echo "Cleanup complete."
df -h /workspaces /home/codespace | sed -n '1,3p'