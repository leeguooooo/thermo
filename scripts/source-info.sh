#!/bin/sh
# Sanitized Git metadata for this exact build root, never a surrounding repository.
set -eu
cd "${1:-.}"
ROOT="$(pwd -P)"
COMMIT=unknown
STATE=unknown
BUILD=1
if TOP="$(git rev-parse --show-toplevel 2>/dev/null)" &&
   [ "$(cd "$TOP" && pwd -P)" = "$ROOT" ] &&
   VALUE="$(git rev-parse --verify HEAD 2>/dev/null)"; then
    case "$VALUE" in *[!0-9a-f]*|'') VALUE=unknown ;; esac
    if [ "${#VALUE}" = 40 ] || [ "${#VALUE}" = 64 ]; then
        COMMIT="$VALUE"
        if STATUS="$(git status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)"; then
            STATE=clean
            [ -z "$STATUS" ] || STATE=dirty
        fi
        if COUNT="$(git rev-list --count "$COMMIT" 2>/dev/null)"; then
            case "$COUNT" in *[!0-9]*|'') ;; *) BUILD="$COUNT" ;; esac
        fi
    fi
fi
printf '%s %s %s\n' "$COMMIT" "$STATE" "$BUILD"
