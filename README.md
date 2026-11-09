# FFResonanceMod: game-side Archipelago mod for FINAL FANTASY RESONANCE

**Players:** see [docs/install.md](docs/install.md), [docs/configuration.md](docs/configuration.md), [docs/troubleshooting.md](docs/troubleshooting.md), [docs/compatibility.md](docs/compatibility.md), [docs/debugging.md](docs/debugging.md) and [CHANGELOG.md](CHANGELOG.md).

This is the game-side half of the Final Fantasy Resonance × Archipelago integration. The Archipelago World lives separately in `../ArchipelagoFFResonance/worlds/ff_resonance/`.

> **Status: release 0.9.0 (development preview).**
> - **Works in game:** randomized chests are emptied and reported; world-map pickup, Tablet Shard, Vision, side-quest and Esper checks are detected; items from the multiworld are delivered and announced with the game's own "You obtained" window; delivery stays exactly-once across saves, reloads, autosaves and bridge restarts.
> - **Implemented but not yet observed in play:** chapter, Colosseum and Chamber of Arms checks, and story-completion goal detection.
>
> See `../DEVELOPMENT_STATUS.md` and `../KNOWN_ISSUES.md`.

## Architecture
- **UE4SS Lua mod** (`ue4ss_mod/FFResonanceAP/`): runs inside the game via [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). It reads game state through Unreal reflection and will apply items.
- **Bridge** (`bridge/`, see `bridge/README.md`): a standalone Python client that speaks the Archipelago WebSocket protocol and exchanges JSON files with the Lua mod (`ipc/`).

Background is in `../TECHNICAL_DECISIONS.md`.

## Requirements
- FINAL FANTASY RESONANCE (Steam, Windows build). Tested environment: Linux + Proton Experimental. The game build is from 2026-10-26 and runs Unreal Engine 5.6.
- RE-UE4SS `v3.0.1-1217-g4fb9b615` (GitHub release `experimental2`). The install script downloads it and verifies its checksum.
- bash, curl, unzip, sha256sum (for the Linux install script).

## Install (Linux / Proton)
```bash
tools/install_proton.sh            # auto-detects the Steam library; DEV UE4SS build by default
tools/install_proton.sh --mod-only # update only the Lua mod after editing scripts
tools/install_proton.sh --uninstall
```
Then set the game's Steam launch option to:
```
WINEDLLOVERRIDES="dwmapi=n,b" %command%
```
The script only **adds** `dwmapi.dll` and `ue4ss/` to `FFRS/Binaries/Win64/`. No game file is modified.

Windows users can copy `dwmapi.dll` and `ue4ss/` from the UE4SS zip next to `FFRS-Win64-Shipping.exe`, then copy `ue4ss_mod/FFResonanceAP` into `ue4ss/Mods/`. *(Not yet tested on Windows.)*

## Playing
1. Generate a seed that includes a Final Fantasy Resonance slot and host it (locally or on archipelago.gg).
2. Start the bridge with no arguments: `cd bridge && .venv/bin/python -m ffr_bridge`. It waits for settings from the game.
3. Start the game. On the title screen, click **Archipelago Options** (top right) and enter the server, port, slot name and password. Press **Connect**, then **Back**.
   - Under the button, a green **Connected as <slot>** or a red **Disconnected** shows the connection state.
   - Server, port and slot are remembered (`config/connection.json`). The password is never saved: type it again each time you start the game.
   - While the panel is open, the keyboard only types into the fields; the title menu doesn't react.
4. Load your save. **Use a new game or a save that has never been used with another seed.**
5. Open chests, collect Visions, complete side quests, advance the story.
   - A randomized chest shows "0 Gil", and its item goes to its owner.
   - Received items are announced with the game's "You obtained the following" window as soon as you're idle in the field. The window waits while a cutscene, menu or dialog is open.
   - Gil is added silently.
   - To turn the window off, put `off` in `config/notifications.txt`.

**The mod does nothing until you press Connect during the current game launch.** If you start the game and load a save without connecting, the game stays vanilla: no chest is emptied, nothing is delivered. When you quit the game, the bridge disconnects from the server within 30 seconds and forgets the password.

## Research tools (M1)
With the game focused:

| Keys | Action | Output (`ue4ss/Mods/FFResonanceAP/dumps/`) |
|---|---|---|
| Ctrl+F6 | Class discovery: game classes of interest, their properties and functions, live instance counts | `classes.json` |
| Ctrl+F7 | Dump every DataTable in memory | `datatables_index.json`, `datatables/*.json` |
| Ctrl+F8 | Snapshot all properties of live instances of the classes listed in `config/watch_classes.txt` | `snapshots/snapshot_<time>.json` |
| Ctrl+H / Ctrl+J | UE4SS built-ins: C++ header SDK dump / object dump | `ue4ss/CXXHeaderDump`, `ue4ss/UE4SS_ObjectDump.txt` |

To compare two snapshots: `tools/diff_snapshots.py before.json after.json`.

The dumps contain game data extracted from your own copy. Don't redistribute them. Only IDs and names are copied into the project's `spec/`.

## Logs
- `FFRS/Binaries/Win64/ue4ss/UE4SS.log`: UE4SS itself
- `FFRS/Binaries/Win64/ue4ss/Mods/FFResonanceAP/logs/ffr_ap.log`: this mod

## Tests
```bash
lua tests/lua/run_tests.lua    # pure-Lua modules (json, fs, session, save/load classifier, mappings); Lua 5.4+
cd bridge && .venv/bin/python -m pytest -q tests/   # bridge (incl. real MultiServer end-to-end)
```

## Troubleshooting
- **No `UE4SS.log` appears:** the launch option is missing, or `dwmapi.dll` isn't in `Binaries/Win64`.
- **UE4SS starts but the log reports signature/AOB scan failures:** the game is probably Denuvo-protected, and UE4SS may need custom signatures. See `KNOWN_ISSUES.md`.
- **The GUI console crashes or renders black under Proton:** set `GuiConsoleEnabled = 0` in `ue4ss/UE4SS-settings.ini`. The install script already switches `GraphicsAPI` to `dx11`.

## Layout
```
ue4ss_mod/FFResonanceAP/Scripts/   main.lua
  ap/        runtime.lua (game integration), session.lua (exactly-once state), saveevents.lua, ipc.lua,
             connconfig.lua (connection settings, requests, status texts)
  ui/        apmenu.lua (title-screen "Archipelago Options" button, panel, key blocking)
  game/      savewatch.lua (save/load detection), reflect.lua, dump.lua, probe.lua, uidump.lua (research)
  generated/ mappings.lua (from ../spec, do not edit)
  lib/ util/ json, fs (atomic writes), log
ue4ss_mod/FFResonanceAP/config/    watch_classes.txt
bridge/                            ffr_bridge Python package + tests
tools/                             install_proton.sh, build_release.sh, diff_snapshots.py
docs/                              player documentation
tests/lua/                         offline tests
```

## License
MIT (see `LICENSE`). Third-party components, which are not bundled, are listed in `THIRD_PARTY_NOTICES.md`.
