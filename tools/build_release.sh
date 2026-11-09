#!/usr/bin/env bash
# Build the FFResonanceAP release zip (game mod + bridge + install tool + docs).
#
# Usage: tools/build_release.sh [--skip-tests] [--out DIR]
# Output: <out>/FFResonanceAP-<version>.zip   (default out: FFResonanceMod/dist)
#
# The archive keeps the repository layout (ue4ss_mod/, bridge/, tools/, docs/) so that
# tools/install_proton.sh works unchanged from the extracted folder. UE4SS itself is NOT bundled:
# the install script downloads the pinned release and verifies its checksum.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
OUT="$ROOT/dist"
RUN_TESTS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests) RUN_TESTS=0; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

MOD_VERSION="$(grep -oP 'local MOD_VERSION = "\K[^"]+' "$ROOT/ue4ss_mod/FFResonanceAP/Scripts/main.lua")"
BRIDGE_VERSION="$(grep -oP '^version = "\K[^"]+' "$ROOT/bridge/pyproject.toml")"
DATA_VERSION="$(grep -oP 'M.data_version = "\K[0-9a-f]+' "$ROOT/ue4ss_mod/FFResonanceAP/Scripts/generated/mappings.lua")"
[[ -n "$MOD_VERSION" && -n "$BRIDGE_VERSION" && -n "$DATA_VERSION" ]] || die "could not read versions"
[[ "$MOD_VERSION" == "$BRIDGE_VERSION" ]] || die "mod version $MOD_VERSION != bridge version $BRIDGE_VERSION"

if [[ $RUN_TESTS -eq 1 ]]; then
  echo "== Lua tests"
  (cd "$ROOT" && lua tests/lua/run_tests.lua)
  echo "== Lua syntax"
  while IFS= read -r f; do luac -p "$f" || die "syntax error in $f"; done < <(find "$ROOT/ue4ss_mod" -name '*.lua')
  echo "== Bridge unit tests"
  PY="$ROOT/bridge/.venv/bin/python"
  [[ -x "$PY" ]] || die "bridge venv missing (see bridge/README.md) or use --skip-tests"
  (cd "$ROOT/bridge" && "$PY" -m pytest -q tests/test_core.py)
fi

NAME="FFResonanceAP-$MOD_VERSION"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$NAME"
mkdir -p "$PKG/ue4ss_mod/FFResonanceAP" "$PKG/bridge" "$PKG/tools" "$PKG/docs"

# Game mod: scripts and default config only; runtime folders are created by the installer.
cp -r "$ROOT/ue4ss_mod/FFResonanceAP/Scripts" "$ROOT/ue4ss_mod/FFResonanceAP/config" "$PKG/ue4ss_mod/FFResonanceAP/"
# Bridge: package + metadata, no tests/venv/caches.
cp -r "$ROOT/bridge/ffr_bridge" "$ROOT/bridge/pyproject.toml" "$ROOT/bridge/README.md" "$PKG/bridge/"
cp "$ROOT/tools/install_proton.sh" "$PKG/tools/"
cp "$ROOT/docs/"*.md "$PKG/docs/"
cp "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$PKG/"
find "$PKG" -name '__pycache__' -type d -prune -exec rm -rf {} +
printf '%s\n' "mod_version=$MOD_VERSION" "bridge_version=$BRIDGE_VERSION" "data_version=$DATA_VERSION" \
  "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PKG/VERSION.txt"

mkdir -p "$OUT"
rm -f "$OUT/$NAME.zip"
(cd "$STAGE" && python3 -m zipfile -c "$OUT/$NAME.zip" "$NAME")
(cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
echo "Built $OUT/$NAME.zip (data_version $DATA_VERSION)"
