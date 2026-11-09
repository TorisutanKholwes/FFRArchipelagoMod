# Compatibility

| Component | Supported / tested |
|---|---|
| Game | FINAL FANTASY RESONANCE, Steam, build of 2026-10-26 (`FFRS-Win64-Shipping.exe`, Unreal Engine 5.6) |
| Platform | Linux + Proton Experimental: **tested**. Windows: **not tested**. |
| UE4SS | `v3.0.1-1217-g4fb9b615` (GitHub release `experimental2`), DEV build |
| Archipelago | 0.6.9 (the `.apworld` declares `minimum_ap_version` 0.6.9) |
| Bridge | Python 3.11+ with `websockets` 13.x (the same version Archipelago uses) |

## Game updates
The mod relies on the game's reflected classes and functions (module `/Script/mucha`). See `TECHNICAL_DECISIONS.md` in the project for the full list. A game update can rename them. The mod logs an error and stops the affected feature rather than guessing:
- If the idle check is unavailable, items are delivered without waiting.
- If notifications are unavailable, they are disabled.
- If item delivery fails, it stops with `delivery_error`.

## Seed / mod matching (`data_version`)
Every release has a **data version**: a fingerprint of all item and location IDs and how they're applied or detected.
- The `.apworld` writes it into each seed's slot data.
- The mod contains the same value (`generated/mappings.lua`) and logs it at startup (`Data version: …`).

On connection the mod compares the two. If they differ, it refuses the seed: chests stay vanilla, no items are delivered, and both the mod log and the bridge report `INCOMPATIBLE SEED`. Seeds generated with world 0.1.x (before data versions existed) are refused for this reason.

## Saves
- The mod never writes to the game's save files.
- Its own per-seed state lives in `state/`.
- Saves sync to Steam Cloud as usual; the mod state does not.
- If you play the same seed on two computers, copy `state/` across.
