# Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No `ue4ss/UE4SS.log` after starting the game | UE4SS isn't loaded. On Linux, check the Steam launch option `WINEDLLOVERRIDES="dwmapi=n,b" %command%`. Check that `dwmapi.dll` and `ue4ss/` are in `FFRS/Binaries/Win64`. |
| `UE4SS.log` exists but `logs/ffr_ap.log` doesn't | The mod isn't enabled. Look for `FFResonanceAP : 1` in `ue4ss/Mods/mods.txt` and for `enabled.txt` in the mod folder. Re-run `tools/install_proton.sh --mod-only`. |
| Log says `folder marker missing` | The `ipc/`, `state/` or `dumps/` folders are missing. Re-run the installer. |
| UE4SS window is black, or the game crashes at start | Set `GuiConsoleEnabled = 0` in `ue4ss/UE4SS-settings.ini`. The installer already uses `GraphicsAPI = dx11`. |
| Bridge: `Could not find the mod's ipc folder` | Pass `--ipc-dir ".../FFRS/Binaries/Win64/ue4ss/Mods/FFResonanceAP/ipc"`. |
| No **Archipelago Options** button on the title screen | Look for `UI:` lines in `logs/ffr_ap.log`. `could not add the ... button` explains why. |
| Panel status: `Bridge not running` | Start the bridge (`python -m ffr_bridge`), then press Connect again. |
| `connection refused: no slot with this name` | The slot name must equal the `name` in your YAML (case-sensitive). |
| `wrong or missing room password` | Type the room password in the panel and press Connect again. |
| **Disconnected** after restarting the game | Expected: the password isn't saved. Open Archipelago Options, type the password, press Connect. |
| The title menu moves while typing in the panel | Look for `UI: game keys blocked` in the mod log. If it says `keys are NOT blocked`, please report the log. |
| Bridge keeps printing `Reconnecting in N s` | The server is unreachable. Check the address and port (room ports change when a room restarts). Nothing is lost while the bridge waits. |
| Mod log: `INCOMPATIBLE SEED` / bridge: `Mod refuses this seed` | The seed was generated with a different `ff_resonance.apworld` than this mod release. Use matching releases. The mod does nothing for that seed: chests stay vanilla and no items are delivered. |
| A shop doesn't show the progressive gear | Close the shop: lists are only updated while no menu, dialog or shop is open. The mod log shows `SHOPS: weapons tier N ...; n row(s) written`. A `SHOPS: ... FAILED` line disables progressive shops until the game restarts; please report it. |
| A zone's entrance has no Enter prompt | With `zone_locks`, the zone needs its "<Zone> Access" item. The mod log lists `ZONES: n/73 zones unlocked`. If you have the item and the prompt is still missing, report the `ZONES:` lines of the log. |
| Fast travel says "a place you haven't visited yet" for a place you visited | The zone is locked (`zone_locks`): the game's own dialog is reused. |
| Received items don't appear | Items are applied only when you're in control in the field (not during battles, cutscenes, dialogs or menus). Look for `Item delivery waiting (...)` in the mod log. |
| `ITEM delivery stopped: unknown item id` | Mod and seed data don't match. Update the mod to the release matching the seed. |
| `only N of M added ... inventory full` | You already hold the maximum of that item. The excess is lost, as with a normal pickup. |
| A chest gave its normal reward | Either it isn't randomized (key items and artifacts), or it was opened before the mod was linked to a seed. Its check is still sent. |
| Chests show "0 Gil" when playing without Archipelago | Only possible after pressing Connect in this game launch. Restart the game and don't press Connect. |
| No Archipelago popups or system-menu list | Look for `OVERLAY` lines in the mod log. `OVERLAY disabled for this session (...)` gives the reason; please report it. The overlay only shows after Connect, in game (not on the title screen), and `config/overlay.txt` must not say `off`. |
| A received item showed no popup | Items replayed after loading an older save, and items already listed, are not shown again (they're still applied). Items arrive when you're in control in the field, so their popups appear then. |
| Goal not reported | Goal detection uses main story progress ≥ 9000, a value taken from the game's own data that hasn't been confirmed on a real clear yet. Please report the mod log line `Main story progress:` after the credits. |

When reporting a problem, include `logs/ffr_ap.log`, the bridge output and `ue4ss/UE4SS.log`. None of them contain passwords.
