#!/usr/bin/env bash
# Install UE4SS + the FFResonanceAP Lua mod into FINAL FANTASY RESONANCE (Steam, Linux/Proton).
#
# Only ADDS files to <game>/FFRS/Binaries/Win64 (dwmapi.dll, ue4ss/). No game file is modified.
# Uninstall: tools/install_proton.sh --uninstall
#
# Usage:
#   tools/install_proton.sh [--game-dir DIR] [--variant dev|std] [--ue4ss-zip FILE] [--mod-only] [--uninstall]
#
# After installing, set the Steam launch option of the game to:
#   WINEDLLOVERRIDES="dwmapi=n,b" %command%
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_ROOT="$(dirname "$SCRIPT_DIR")"
MOD_SRC="$MOD_ROOT/ue4ss_mod/FFResonanceAP"
CACHE_DIR="$MOD_ROOT/.cache"

# Pinned UE4SS build (RE-UE4SS GitHub release tag "experimental2", supports UE 5.0-5.8).
UE4SS_TAG="experimental2"
UE4SS_BUILD="v3.0.1-1217-g4fb9b615"
declare -A UE4SS_FILE=( [dev]="zDEV-UE4SS_${UE4SS_BUILD}.zip" [std]="UE4SS_${UE4SS_BUILD}.zip" )
declare -A UE4SS_SHA256=(
  [dev]="d55eb130535c8dfb38aa1a37c07251ea47de4942892cfe93085f8bcb2c1bee4f"
  [std]="fbdacd0fae434e23d53b1181f6b085219d7cbf7e2cc8a13a00303f842c38194f"
)

GAME_DIR=""
VARIANT="dev"
UE4SS_ZIP=""
MOD_ONLY=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --game-dir) GAME_DIR="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --ue4ss-zip) UE4SS_ZIP="$2"; shift 2 ;;
    --mod-only) MOD_ONLY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

find_game_dir() {
  local vdf
  for vdf in "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" "$HOME/.steam/steam/steamapps/libraryfolders.vdf"; do
    [[ -f "$vdf" ]] || continue
    while IFS= read -r lib; do
      local cand="$lib/steamapps/common/FINAL FANTASY RESONANCE"
      if [[ -d "$cand/FFRS/Binaries/Win64" ]]; then echo "$cand"; return 0; fi
    done < <(grep -oP '"path"\s+"\K[^"]+' "$vdf")
  done
  return 1
}

[[ -n "$GAME_DIR" ]] || GAME_DIR="$(find_game_dir)" || die "Game not found; pass --game-dir"
WIN64="$GAME_DIR/FFRS/Binaries/Win64"
[[ -f "$WIN64/FFRS-Win64-Shipping.exe" ]] || die "FFRS-Win64-Shipping.exe not found in $WIN64"
echo "Game: $GAME_DIR"

if [[ $UNINSTALL -eq 1 ]]; then
  [[ -d "$WIN64/ue4ss" || -f "$WIN64/dwmapi.dll" ]] || { echo "Nothing to uninstall."; exit 0; }
  echo "Removing $WIN64/dwmapi.dll and $WIN64/ue4ss (mod dumps/logs inside it are deleted too)."
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
  rm -f "$WIN64/dwmapi.dll"
  rm -rf "$WIN64/ue4ss"
  echo "Uninstalled."
  exit 0
fi

install_ue4ss() {
  [[ -n "${UE4SS_FILE[$VARIANT]:-}" ]] || die "--variant must be dev or std"
  if [[ -f "$WIN64/dwmapi.dll" && ! -d "$WIN64/ue4ss" ]]; then
    die "$WIN64/dwmapi.dll exists but is not UE4SS (no ue4ss/ folder). Refusing to overwrite."
  fi
  if [[ -z "$UE4SS_ZIP" ]]; then
    mkdir -p "$CACHE_DIR"
    UE4SS_ZIP="$CACHE_DIR/${UE4SS_FILE[$VARIANT]}"
    if [[ ! -f "$UE4SS_ZIP" ]]; then
      local url="https://github.com/UE4SS-RE/RE-UE4SS/releases/download/${UE4SS_TAG}/${UE4SS_FILE[$VARIANT]}"
      echo "Downloading $url"
      curl -fL --retry 3 -o "$UE4SS_ZIP.part" "$url"
      mv "$UE4SS_ZIP.part" "$UE4SS_ZIP"
    fi
    echo "${UE4SS_SHA256[$VARIANT]}  $UE4SS_ZIP" | sha256sum -c - || die "UE4SS checksum mismatch"
  fi
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  unzip -q "$UE4SS_ZIP" -d "$tmp"
  [[ -f "$tmp/dwmapi.dll" && -d "$tmp/ue4ss" ]] || die "Unexpected UE4SS archive layout"

  if [[ -d "$WIN64/ue4ss" ]]; then
    echo "Existing UE4SS found; updating binaries, keeping settings and mods."
    cp -f "$tmp/dwmapi.dll" "$WIN64/"
    cp -f "$tmp/ue4ss/UE4SS.dll" "$WIN64/ue4ss/"
    [[ -f "$tmp/ue4ss/UE4SS.pdb" ]] && cp -f "$tmp/ue4ss/UE4SS.pdb" "$WIN64/ue4ss/"
  else
    cp -r "$tmp/dwmapi.dll" "$tmp/ue4ss" "$WIN64/"
    # GUI console under Proton: dx11 renders more reliably than the default OpenGL.
    sed -i 's/^GraphicsAPI = opengl/GraphicsAPI = dx11/' "$WIN64/ue4ss/UE4SS-settings.ini"
    # Dev-build helper mods are not needed and add native hooks; one crash coincided with a
    # hot reload that re-installed them (TD-026). Keep them off.
    sed -i 's/^EventViewerMod : 1/EventViewerMod : 0/; s/^KismetDebuggerMod : 1/KismetDebuggerMod : 0/; s/^LineTraceMod : 1/LineTraceMod : 0/' \
      "$WIN64/ue4ss/Mods/mods.txt"
  fi
  echo "UE4SS ($VARIANT, $UE4SS_BUILD) installed."
}

install_mod() {
  local mods="$WIN64/ue4ss/Mods"
  [[ -d "$mods" ]] || die "UE4SS Mods folder not found ($mods). Install UE4SS first (drop --mod-only)."
  local dest="$mods/FFResonanceAP"
  mkdir -p "$dest"
  # Scripts are replaced; runtime folders (dumps, logs, config edits, ipc, state) are preserved.
  rm -rf "$dest/Scripts"
  cp -r "$MOD_SRC/Scripts" "$dest/"
  mkdir -p "$dest/config" "$dest/logs" "$dest/dumps/datatables" "$dest/dumps/snapshots" "$dest/dumps/events" "$dest/dumps/items" "$dest/dumps/zones" "$dest/ipc" "$dest/state"
  touch "$dest/dumps/.keep" "$dest/dumps/zones/.keep" "$dest/ipc/.keep" "$dest/state/.keep" "$dest/enabled.txt"
  for f in "$MOD_SRC"/config/*; do
    [[ -e "$dest/config/$(basename "$f")" ]] || cp "$f" "$dest/config/"
  done
  if ! grep -q '^FFResonanceAP' "$mods/mods.txt"; then
    # Insert before the built-in keybinds comment so Keybinds stays last.
    if grep -q '^; Built-in keybinds' "$mods/mods.txt"; then
      sed -i 's/^; Built-in keybinds/FFResonanceAP : 1\n\n; Built-in keybinds/' "$mods/mods.txt"
    else
      printf '\nFFResonanceAP : 1\n' >> "$mods/mods.txt"
    fi
  fi
  echo "FFResonanceAP mod installed to $dest"
}

[[ $MOD_ONLY -eq 1 ]] || install_ue4ss
install_mod

cat <<EOF

Done. Steam launch option for FINAL FANTASY RESONANCE (Properties > General > Launch Options):
  WINEDLLOVERRIDES="dwmapi=n,b" %command%
Logs:
  $WIN64/ue4ss/UE4SS.log
  $WIN64/ue4ss/Mods/FFResonanceAP/logs/ffr_ap.log
EOF
