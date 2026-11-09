# Changelog

## 0.12.0 (world 0.8.0, data version `2717a1b6300c52c7`: seeds from 0.11.0 are refused)
- **Progressive shops** (YAML options `progressive_shops`, on by default, and `progressive_shop_prices`: `full` / `half` (default) / `quarter`):
  - Progressive Weapon Shop ×7, Progressive Armor Shop ×7, Progressive Accessory Shop ×6 (useful items, in place of filler).
  - Each copy adds the next chapter's gear to every shop of that kind: the best weapon or armor of each type, or the accessories that chapter introduces.
  - Shops keep their own stock; only a full shop swaps its cheapest same-type item. Added gear costs the chosen fraction of its price.
  - The shop lists are rewritten in memory while no menu is open, and come back to normal without a Connect. Nothing is written to the save.
- **Spec:** `spec/tools/extract_shops.py` builds `spec/shops.json` (73 equipment shops, tiers per chain) from the in-game DataTable dumps. Item IDs `79_900_001`–`79_900_003`.
- **Research tooling:** `game/shopprobe.lua` (shop write test), only with `config/shop_research.txt` = `on`.

## 0.11.0 (world 0.7.0, data version `18df2ce3c4db7cb5`: seeds from 0.10.0 are refused)
- **Zone locks** (YAML option `zone_locks`, on by default): 73 map zones, each with a "<Zone> Access" item.
  - A locked zone's world-map entrance has no Enter prompt, because its trigger's collision is switched off in memory. Fast travel to it is refused with the game's own dialog.
  - Receiving the item opens the entrance immediately. Nothing is written to the save.
  - The eight chapter-1 zones start unlocked. The world logic follows the story: each chapter needs the zones its story uses. Checks whose place is unknown need every zone and the cleared story.
- **World:** "Story Chapter N Cleared" events; the goal now requires the cleared story (before, it was reachable from the start in logic).
- **Spec:** `spec/tools/extract_zones.py` builds `spec/zones.json` (zones, reach, story steps) from in-game dumps; zone items use IDs `79_000_000 + zone id`.
- **Research tooling:** `game/zoneprobe.lua` (entrance inventory, lock and fast-travel tests), only with `config/zone_research.txt` = `on`.
- **Dev:** `tests/lua/lint_globals.py` reports undefined globals in the mod scripts (a local used above its definition only fails in game).

## 0.10.0 (world 0.6.0, data version `171c914f53d4f185`, unchanged: 0.9.0 seeds work)
- **Archipelago Options on the title screen:** a button opens a panel with Server, Port, Slot name and Password. Connect sends the settings to the bridge, and the panel shows the bridge's state or the server's refusal reason.
  - Server, port and slot are remembered in `config/connection.json`. The password is never saved or logged.
  - While the panel is open, the game doesn't receive keyboard or gamepad input, so typing can't move or trigger the title menu.
- **Connection status under the button:** green "Connected as <slot>" or red "Disconnected".
- **The mod is inactive until Connect:** no seed link is restored at startup, and a bridge connection from an earlier launch is ignored. Saves you load without connecting stay vanilla.
- **Bridge:** start it without arguments, and the settings come from the game. Refusals don't stop it any more; it waits for corrected settings. When the game closes (30 s without update) or restarts, it disconnects and forgets the password. `--slot`/`--server`/`--password` still work.
- **Fixes:** the title-screen research dumps (1–3 s freezes at startup and after Load Game) only run with `config/research.txt` = `on`. JSON `null` values in `bridge_state.json` no longer cause a false "INCOMPATIBLE SEED" error.

## 0.9.0 (world 0.6.0, data version `171c914f53d4f185`)
- **Oblivion Palace:** all 25 safes are now checks. The 6 safes whose reward is Magicite or Adamantite (9, 24, 40, 64, 80, 89 shards) were missing. They keep their vanilla reward and add filler to the pool.
- **New option** `oblivion_palace_useful_safes` (0–25, default 25): only the first N safes, in order of shards needed, can hold progression or useful items. The rest are filler-only (Archipelago excluded locations).
- **Compatibility:** 534 locations. Seeds from 0.8.0 are refused by the data-version guard.
- **DeathLink:** option `death_link` (off by default) and bridge flag `--death-link auto|on|off`. A game over is sent to the other DeathLink players. A received death wipes the party in battle, or at the start of the next battle. The game over it causes isn't echoed back.
- **How it works in game:** an enemy uses an instant-death skill on the whole party, so the game shows its own game-over screen, after your next action (TD-030).
- **Status:** verified in game (send, receive in battle, queue from the field, no echo) and against a real server with two bridges.
- **Tools:** `tools/send_deathlink.py` sends a test death from another slot.

## 0.8.0 (world 0.5.0)
- **New check type:** Tablet Shards collected. Option `tablet_shard_checks` (default every 5th shard, the 99th always included). The count is held shards plus shards handed in at Oblivion Palace, so it's complete without knowing where the shards lie. The shards still work normally for the safes.
- **Compatibility:** 528 locations defined. Seeds from 0.7.0 are refused by the data-version guard.


## 0.7.0 (world 0.4.0, data version `a5298af858f185a1`)
- **New check type:** world-map pickups (93, on by default). Collecting an item lying on the world map sends a check, and you still get the item.
- **Research findings:** the "chests without table entry" in towns are Tablet Shard pickups, which stay vanilla. There's no separate chest category.
- **Stability:** UE4SS hot reload and the dev helper mods are disabled. The research map scans are disabled after they crashed the game during world-map loading.
- **Compatibility:** 429 locations. Seeds from 0.6.0 are refused by the data-version guard.


## 0.6.0 (world 0.3.0, data version `c245b9d57a5fd2a8`)

**New checks**
- Espers (9, on by default).
- Colosseum rank battles (20, off by default).
- Chamber of Arms trials (12 or 24, off by default).

**First logic**
- A Chamber of Arms trial requires its Ancient piece when that piece is found in a randomized chest.

**Names**
- The Oblivion Palace chests are now named after the Tablet Shards they need. The thresholds come from game data, and the IDs are unchanged.

**Mod**
- Detects event flags and Colosseum results.
- Gating research tools are kept as keys; the per-map research scans are opt-in.

**Compatibility**
- 336 locations.
- Seeds from 0.5.0 are refused by the data-version guard.


## 0.5.0: first packaged development preview (world 0.2.0, data version `5b3df4d67654e8a1`)

**Archipelago world**
- 283 locations: 216 chests, 26 Visions, 33 side quests (requests), 8 chapters.
- Options: `goal`, `include_battle_chests`, `vision_checks`, `request_checks`, `chapter_checks`.
- Goal: story complete.

**Game mod**
- Randomized chests give nothing in game; their check is sent.
- Checks are also rebuilt from save data, which covers chests opened offline, Visions owned and requests completed.
- Received items are applied in server order, exactly once across saves, reloads, autosaves, mod reloads and bridge restarts. They're applied only while you're in control in the field, never during battles, cutscenes, dialogs or menus.
- Received items are announced with the game's own "You obtained the following" window.
- Story goal detection (main progress ≥ 9000) and chapter checks.
- Crash-safe state files with backup and recovery.
- Seed compatibility guard (`data_version`).

**Bridge**
- Archipelago client with `ws://` and `wss://` (automatic fallback), password support (asked again when wrong), clear refusal messages, reconnect with backoff, and resend of offline checks.

**Project**
- MIT license. Third-party components are listed in `THIRD_PARTY_NOTICES.md`; none are bundled.

**Not included / known limitations**
- See `KNOWN_ISSUES.md` in the project and [docs/troubleshooting.md](docs/troubleshooting.md).
- No logic gating: everything is reachable from the start.
- Gil and "sent" messages aren't shown in game.
- The goal hasn't been confirmed on a real clear yet.
- Windows installation hasn't been tested.

## Earlier development builds
- **0.1.x:** research spike. UE4SS loading, data dumps, chest replacement experiments.
- **0.2.x:** Archipelago runtime and bridge, first end-to-end run in game.
- **0.3.x:** Vision, request and chapter checks, goal, notifications.
- **0.4.x:** delivery gating, inventory cap, crash-safe state.
