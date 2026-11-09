# Debugging

## Logs
- `ue4ss/Mods/FFResonanceAP/logs/ffr_ap.log` (the mod) records:
  - startup: versions and data version;
  - map changes, with the save object state;
  - `LOAD detected` / `SAVE recorded`;
  - `CHECK <id> recorded (...)` and `ITEM <n> applied`;
  - `Item delivery waiting (reason)`, `Notification shown`;
  - server messages (`AP: ...`).
- The bridge console (or `--log-file`) records connection states, `Sent LocationChecks`, `Received <item> from <player>` and server messages.
- `ue4ss/UE4SS.log` covers UE4SS itself: engine detection, hooks, Lua errors.

## IPC files (`ue4ss/Mods/FFResonanceAP/ipc/`)
- **`bridge_state.json`**, written by the bridge: status, seed and slot, `slot_data`, the full received-item list, server-checked locations, recent messages.
- **`game_state.json`**, written by the mod: checked locations, `applied_index`, `goal`, `main_progress`, `delivery_waiting`, `delivery_error`, `incompatible`, `data_version`.

Both files are complete snapshots written atomically, so they're safe to read at any time.

## Research keys (in game)

| Keys | Output |
|---|---|
| Ctrl+F6 | `dumps/classes.json`: game classes, properties and functions |
| Ctrl+F7 | `dumps/datatables/*.json`: every loaded DataTable |
| Ctrl+F8 | `dumps/snapshots/`: properties of the classes listed in `config/watch_classes.txt` (compare with `tools/diff_snapshots.py`) |
| Ctrl+F9 | Gil, chapter and map in the log, plus `dumps/savedata_*.json` (the live save object) |
| Ctrl+F10 | **Adds 1 Potion** (test of item delivery) |
| Ctrl+F3 | Opens the item-obtained window (display only) |
| Ctrl+H / Ctrl+J | UE4SS header dump / object dump |
| Ctrl+R | Reload all UE4SS mods (when `EnableHotReloadSystem = 1`) |

The dumps contain game data from your own copy. Don't redistribute them.

## Tests (development)
```bash
lua tests/lua/run_tests.lua                       # mod logic (Lua 5.4+)
cd bridge && .venv/bin/python -m pytest -q tests/ # bridge, incl. a real MultiServer if the fork is present
```
