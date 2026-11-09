# Installation

Two parts are installed:
- **The game mod**: UE4SS plus the `FFResonanceAP` Lua mod, installed into the game folder.
- **The bridge**: a small Python program that connects the mod to the Archipelago server.

The randomizer world itself (`ff_resonance.apworld`) is used by whoever generates and hosts the multiworld. See [Archipelago side](#archipelago-side).

## Requirements
- FINAL FANTASY RESONANCE, Steam version (build of 2026-10-26, Unreal Engine 5.6). See [compatibility.md](compatibility.md).
- Python 3.11 or newer, for the bridge.
- Linux: `bash`, `curl`, `unzip`, `sha256sum`.

## Linux / Steam Deck (Proton): tested
1. Extract `FFResonanceAP-<version>.zip` anywhere.
2. Install UE4SS and the mod:
   ```bash
   cd FFResonanceAP-<version>
   bash tools/install_proton.sh          # finds the game in your Steam libraries
   # bash tools/install_proton.sh --game-dir "/path/to/FINAL FANTASY RESONANCE"   if not found
   ```
   The script downloads UE4SS `v3.0.1-1217-g4fb9b615` from its official GitHub release and verifies its SHA-256. It only **adds** `dwmapi.dll` and `ue4ss/` next to `FFRS-Win64-Shipping.exe`; no game file is modified.
3. In Steam, open the game's **Properties → General → Launch Options** and enter:
   ```
   WINEDLLOVERRIDES="dwmapi=n,b" %command%
   ```
4. Install the bridge:
   ```bash
   cd bridge
   python3 -m venv .venv
   .venv/bin/pip install .
   ```
5. Start the game once and check that `ue4ss/Mods/FFResonanceAP/logs/ffr_ap.log` (in the game's `FFRS/Binaries/Win64` folder) contains `FFResonanceAP v<version> starting`.

**Updating:** run `bash tools/install_proton.sh --mod-only` from the new release folder. Your settings, logs and Archipelago state are kept.

**Uninstalling:** run `bash tools/install_proton.sh --uninstall` and remove the Steam launch option.

## Windows: not yet tested
These steps follow UE4SS's standard installation, but nobody has tested them for this project yet.
1. Download `zDEV-UE4SS_v3.0.1-1217-g4fb9b615.zip` from <https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental2>.
2. Extract `dwmapi.dll` and the `ue4ss` folder into `...\FINAL FANTASY RESONANCE\FFRS\Binaries\Win64\` (next to `FFRS-Win64-Shipping.exe`).
3. Copy `ue4ss_mod\FFResonanceAP` from the release into `Win64\ue4ss\Mods\`. Inside it, create the empty folders `logs`, `ipc`, `state` and `dumps`, each containing an empty file named `.keep`.
4. Edit `Win64\ue4ss\Mods\mods.txt` and add the line `FFResonanceAP : 1` above the `Keybinds : 1` line.
5. Install the bridge: `py -m venv .venv` then `.venv\Scripts\pip install .` inside the `bridge` folder.

No Steam launch option is needed on Windows.

## Archipelago side
1. Put `ff_resonance.apworld` into your Archipelago `custom_worlds` folder (Archipelago 0.6.9 or newer).
2. Create a player YAML. The options are listed in [configuration.md](configuration.md).
3. Generate and host as usual.

**Use the `.apworld` from the same release as the mod.** The mod checks the seed's `data_version` and refuses mismatching seeds. See [compatibility.md](compatibility.md).
