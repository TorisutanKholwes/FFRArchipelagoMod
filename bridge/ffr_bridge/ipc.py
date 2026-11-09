"""Atomic JSON file exchange with the game mod (see ue4ss_mod/.../ap/ipc.lua)."""
from __future__ import annotations

import json
import os
from typing import Any

BRIDGE_STATE = "bridge_state.json"
GAME_STATE = "game_state.json"
CONNECT_REQUEST = "connect_request.json"  # written by the mod's title-screen options panel


def write_json_atomic(path: str, data: Any) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def read_json(path: str) -> Any | None:
    """Read a JSON file written atomically by the other side.

    The Lua side (Windows semantics) removes the target before renaming, so the file can be briefly
    missing; fall back to the `.tmp` sibling. Returns None if nothing valid is available.
    """
    for candidate in (path, path + ".tmp"):
        try:
            with open(candidate, encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            continue
        except (json.JSONDecodeError, UnicodeDecodeError, OSError):
            continue
    return None


class IpcChannel:
    def __init__(self, directory: str) -> None:
        if not os.path.isdir(directory):
            raise FileNotFoundError(f"IPC folder not found: {directory} (install the mod with tools/install_proton.sh)")
        self.directory = directory

    def write_bridge_state(self, state: dict[str, Any]) -> None:
        write_json_atomic(os.path.join(self.directory, BRIDGE_STATE), state)

    def read_game_state(self) -> dict[str, Any] | None:
        data = read_json(os.path.join(self.directory, GAME_STATE))
        return data if isinstance(data, dict) else None

    def consume_connect_request(self) -> dict[str, Any] | None:
        """Read and delete a connection request written by the mod's "Archipelago Options" panel.

        The file can contain the room password, so it is removed as soon as it has been parsed
        (only the copy that was read: a half-written `.tmp` the mod is still renaming is left alone).
        Returns None if there is no complete, well-formed request.
        """
        path = os.path.join(self.directory, CONNECT_REQUEST)
        for candidate in (path, path + ".tmp"):
            try:
                with open(candidate, encoding="utf-8") as f:
                    data = json.load(f)
            except (OSError, json.JSONDecodeError, UnicodeDecodeError):
                continue
            try:
                os.remove(candidate)
            except OSError:
                pass
            return data if is_valid_connect_request(data) else {"invalid": True}
        return None


def is_valid_connect_request(data: Any) -> bool:
    return (isinstance(data, dict)
            and isinstance(data.get("address"), str) and data["address"].strip() != ""
            and isinstance(data.get("slot"), str) and data["slot"].strip() != ""
            and (data.get("password") is None or isinstance(data.get("password"), str))
            and (data.get("game_session") is None or isinstance(data.get("game_session"), str))
            and isinstance(data.get("seq"), int))
