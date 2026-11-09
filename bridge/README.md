# ffr_bridge

Connects the FFResonanceAP game mod to an Archipelago server. The mod can't open network sockets (UE4SS Lua), so this small Python program speaks the Archipelago WebSocket protocol and exchanges JSON files with the mod.

## Requirements
- Python 3.11 or newer
- `websockets` (13.x is tested; it's the version Archipelago itself uses)

## Setup
```bash
cd FFResonanceMod/bridge
python3 -m venv .venv            # or: uv venv --python 3.13 .venv
.venv/bin/pip install -e .       # add ".[test]" for the tests
```

## Usage
```bash
.venv/bin/python -m ffr_bridge            # settings come from the game: title screen > Archipelago Options
.venv/bin/python -m ffr_bridge --slot YourSlotName --server archipelago.gg:38281   # command-line settings
```

Without `--slot`, the bridge waits (`waiting_for_settings`) for `ipc/connect_request.json`, written by the mod's options panel. It contains the address, slot, password, a sequence number and the game's launch id. The bridge deletes the file right after reading it. A new request replaces the current connection. A refusal (wrong slot or password) is shown in the game, and the bridge waits for corrected settings instead of exiting. When the game that sent the settings closes (no `game_state.json` update for 30 s) or is restarted (new launch id), the bridge disconnects and forgets the password.

| Option | Meaning |
|---|---|
| `--server` | `host:port`, `ws://host:port` or `wss://host:port`. A bare address tries `ws://` first and switches to `wss://` if the server only speaks TLS. Default `localhost:38281`. |
| `--slot` | Optional: your slot (player) name from your YAML. Without it, the settings come from the game. |
| `--password` | Room password. Can also be set with the `FFR_AP_PASSWORD` environment variable, or is prompted for when the room needs one (and asked again if it was wrong, in an interactive terminal). Never logged. |
| `--ipc-dir` | The mod's `ipc` folder. It's auto-detected in Steam libraries (`.../FFRS/Binaries/Win64/ue4ss/Mods/FFResonanceAP/ipc`). |
| `--ca-file` | Extra CA certificate for `wss://` servers with private certificates. |
| `--death-link` | `auto` (default) follows the YAML `death_link` option; `on`/`off` override it. |
| `--log-file` | Also write the log to a file. |

You can start the bridge before or after the game, and you can stop and restart it at any time. While it's offline, received items wait on the server, and chests you open are kept by the mod. Everything is synchronized on the next connection.

## How it works
- **Server to game:** the full, server-ordered list of received items goes into `ipc/bridge_state.json`. The mod applies the items it hasn't applied yet.
- **Names and messages:** each received item carries `item_name`, `sender` and `location_name` (data packages of every game in the room). `events` lists hints about our items or our world (compact text) and chat, with ids that restart with each connection: `epoch` changes with them. `messages` keeps every server message for the logs.
- **Game to server:** the bridge reads `ipc/game_state.json`, which holds all chests the mod has detected as opened. It sends a `LocationChecks` packet for any the server doesn't know yet, and a `StatusUpdate` (goal) once the mod reports the goal.
- **Connection states:** `connecting`, `connected`, `ready`, then `reconnecting` (exponential backoff from 2 s up to 60 s) when the connection drops. The state becomes `error` (no retry) when the server refuses the slot, for example because of a wrong slot name or password. With command-line settings the bridge then exits; with settings from the game it waits for new ones. `waiting_for_settings` means no settings yet, or the game was closed.

## Tests
```bash
.venv/bin/python -m pytest -q tests/
```
- `tests/test_core.py`: protocol and synchronization logic.
- `tests/test_integration.py`: a real `MultiServer` from the Archipelago fork (`FFR_AP_FORK`, default `../../ArchipelagoFFResonance`, which needs its `.venv`). It covers:
  - password authentication
  - checks confirmed by the server
  - items received from another player
  - a socket drop followed by a reconnect
  - a server save and restart, with a check made while the server was offline
  - the goal
  - automatic `ws://` → `wss://` fallback against a TLS server

  The test is skipped when the fork isn't present.
