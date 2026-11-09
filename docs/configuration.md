# Configuration

## Player YAML (Archipelago options)
```yaml
name: YourName
game: Final Fantasy Resonance
Final Fantasy Resonance:
  goal: story_complete          # finish the main story
  include_battle_chests: true   # the chest that starts a battle when opened
  pickup_checks: true           # collecting each of the 93 items lying on the world map is a check
  tablet_shard_checks: every_5  # off / every_10 / every_5 / every_3 / every_shard (Tablet Shards collected)
  oblivion_palace_useful_safes: 25  # 0-25: Oblivion Palace safes (in shard order) that may hold progression/useful items
  vision_checks: true           # obtaining each of the 26 Visions is a check
  request_checks: true          # completing each of the 33 side quests (requests) is a check
  chapter_checks: true          # clearing story chapters 1-8 are checks
  esper_checks: true            # obtaining each of the 9 Espers is a check
  colosseum_checks: false       # the 20 Colosseum rank battles (later leagues expect levels 55-99)
  chamber_checks: off           # off / trials (12 level-50 trials) / all (+12 level-75 ultimate trials)
  death_link: false             # share deaths (party wipes) with the other DeathLink players
```
- **Chests:** 216 chests are always randomized. Chests whose original reward is a key item or an artifact keep their reward, so a quest can't break.
- **Oblivion Palace safes:** all 25 are checks. 19 have a randomized reward; the 6 whose reward is Magicite or Adamantite keep it. With `oblivion_palace_useful_safes: N`, only the first N safes (fewest shards needed) can hold progression or useful items.
- **World-map pickups, Tablet Shards, Visions, requests, chapters, Espers, Colosseum, Chamber of Arms:** these keep their normal in-game reward, and their check sends a filler item (potions, ethers, Phoenix Downs, Gil).
- **DeathLink:** your game over (party wiped out in battle) is sent to the other DeathLink players. A death received in battle wipes your party immediately; the game-over screen follows your next action. A death received outside battle is applied when the next battle starts, and dropped if you return to the title screen. Only deaths that happen while the game and the bridge both run are shared.
- **Chamber of Arms logic:** a trial needs its Ancient piece. The pieces found in randomized chests (Katana, Whip, Firearm, Rod, Accessory) are progression items.

## Connection (title screen > Archipelago Options)

| Field | Meaning |
|---|---|
| Server | `archipelago.gg`, `localhost`, an IP address, or an explicit `ws://` / `wss://` address. Without a prefix the bridge tries `ws://` first, then `wss://`. |
| Port | The room's port (1–65535). A port typed in the Server field is used only if this field is empty. |
| Slot name | The `name` from your YAML (16 characters at most, case-sensitive). |
| Password | Room password; leave it empty if the room has none. **Never saved**, never logged. |

- **Connect** saves Server, Port and Slot to `config/connection.json` and sends the settings to the bridge through `ipc/connect_request.json`. The bridge deletes that file as soon as it has read it, so the password doesn't stay on disk.
- The status line in the panel shows the bridge's state: waiting, connecting, connected, or the server's refusal reason (wrong slot name, wrong password...).
- The text under the button shows **Connected as <slot>** (green) or **Disconnected** (red).
- **Activation:** the mod only acts on a connection made with Connect during the current game launch. A bridge connection left over from an earlier launch is ignored.
- **Disconnect on exit:** when the game stops updating `ipc/game_state.json` for 30 s (game closed) or is started again, the bridge disconnects and forgets the password.

## Bridge
```bash
python -m ffr_bridge [--ipc-dir DIR] [--ca-file CERT] [--death-link auto|on|off] [--log-file FILE]
python -m ffr_bridge --slot YourName --server archipelago.gg:12345 [--password PW] ...   # without the in-game panel
```

| Option | Meaning |
|---|---|
| `--server` | With `--slot`: `host:port`, or an explicit `ws://` / `wss://` URL. A bare address tries `ws://` first, then `wss://`. |
| `--slot` | Optional. The `name` from your YAML. Without it, the bridge waits for the settings from the game. Settings sent from the game always replace these. The mod still needs Connect in the game to use the connection. |
| `--password` | With `--slot`: room password. You can also set the `FFR_AP_PASSWORD` environment variable, or answer the prompt; a wrong password is asked for again. The password is never logged. |
| `--ipc-dir` | The mod's `ipc` folder. Only needed if auto-detection fails. |
| `--ca-file` | Extra CA certificate for servers with private TLS certificates. |
| `--death-link` | `auto` (default) follows the YAML `death_link` option; `on` / `off` override it for this session. |
| `--log-file` | Copy of the bridge log. |

## Mod (files in `ue4ss/Mods/FFResonanceAP/`)

| File | Purpose |
|---|---|
| `config/notifications.txt` | `off` disables the "You obtained the following" window for received items. The default is on. |
| `config/watch_classes.txt` | Research only: the classes captured by Ctrl+F8 snapshots. |
| `config/connection.json` | Server, port and slot from the Archipelago Options panel (never the password). |
| `config/shop_research.txt` | `on` runs the shop-write research test (adds chapter-5 items to every chapter-1 shop for that launch). Research only; off by default. |
| `config/zone_research.txt` | `on` enables the zone research module (entrance dumps in `dumps/zones/`, lock/fast-travel tests from `config/zone_lock_test.txt` and `config/zone_fasttravel_test.txt`). Research only; off by default. |
| `config/research.txt` | `on` enables research scans and title-screen UI dumps (slow: they freeze the game for 1–3 s). Off by default. |
| `state/current.json` | The seed the mod was last linked to (information only: the link is not restored at startup). |
| `state/<seed>__<slot>.json` (+ `.bak`) | Per-seed progress: applied items per save, checks, goal. **Don't edit.** |

## Starting a run
- Start a **new game**, or use a save that has never been used with another seed. A save the mod doesn't know counts as having received nothing, so all received items are applied to it.
- Chests opened before the first connection keep their vanilla reward, but their checks are still sent.
