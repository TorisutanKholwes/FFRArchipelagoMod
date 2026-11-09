"""Archipelago network protocol: packet builders and parsers.

Follows ArchipelagoFFResonance/docs/network protocol.md (AP 0.6.9). Only fields documented there
are sent.
"""
from __future__ import annotations

import json
from typing import Any, Iterable

GAME = "Final Fantasy Resonance"
CLIENT_VERSION = {"major": 0, "minor": 6, "build": 9, "class": "Version"}

# items_handling bits: 0b001 items from other worlds, 0b010 own-world items, 0b100 starting inventory.
# The mod empties every randomized chest in game, so even our own items must come from the server.
ITEMS_HANDLING_ALL = 0b111

CLIENT_STATUS_GOAL = 30

DEATH_LINK_TAG = "DeathLink"


def encode(packets: Iterable[dict[str, Any]]) -> str:
    return json.dumps(list(packets), separators=(",", ":"))


def decode(raw: str | bytes) -> list[dict[str, Any]]:
    data = json.loads(raw)
    if not isinstance(data, list) or not all(isinstance(p, dict) and "cmd" in p for p in data):
        raise ValueError("server message is not a list of packets")
    return data


def connect(name: str, uuid: str, password: str | None, tags: Iterable[str] = ()) -> dict[str, Any]:
    return {
        "cmd": "Connect",
        "password": password or "",
        "game": GAME,
        "name": name,
        "uuid": uuid,
        "version": CLIENT_VERSION,
        "items_handling": ITEMS_HANDLING_ALL,
        "tags": sorted(set(tags)),
        "slot_data": True,
    }


def connect_update(tags: Iterable[str]) -> dict[str, Any]:
    return {"cmd": "ConnectUpdate", "tags": sorted(set(tags))}


def death_bounce(source: str, cause: str, time: float) -> dict[str, Any]:
    """A DeathLink Bounce (docs/network protocol.md, "DeathLink")."""
    return {"cmd": "Bounce", "tags": [DEATH_LINK_TAG], "data": {"time": time, "source": source, "cause": cause}}


def location_checks(locations: Iterable[int]) -> dict[str, Any]:
    return {"cmd": "LocationChecks", "locations": sorted(set(locations))}


def status_goal() -> dict[str, Any]:
    return {"cmd": "StatusUpdate", "status": CLIENT_STATUS_GOAL}


def sync() -> dict[str, Any]:
    return {"cmd": "Sync"}


def get_data_package(games: Iterable[str]) -> dict[str, Any]:
    return {"cmd": "GetDataPackage", "games": list(games)}


def render_print_json(packet: dict[str, Any], names: "NameLookup") -> str:
    """Plain-text rendering of a PrintJSON packet (JSONMessagePart list)."""
    out = []
    for part in packet.get("data", []):
        text = part.get("text", "")
        ptype = part.get("type")
        try:
            if ptype == "player_id":
                text = names.player(int(text))
            elif ptype == "item_id":
                text = names.item(int(part.get("player", 0)), int(text))
            elif ptype == "location_id":
                text = names.location(int(part.get("player", 0)), int(text))
        except (TypeError, ValueError):
            pass
        out.append(str(text))
    return "".join(out)


class NameLookup:
    """Resolves player/item/location ids to names using Connected + DataPackage data."""

    def __init__(self) -> None:
        self.players: dict[int, str] = {}
        self.slot_games: dict[int, str] = {}
        self.items: dict[str, dict[int, str]] = {}
        self.locations: dict[str, dict[int, str]] = {}

    def load_connected(self, packet: dict[str, Any]) -> None:
        for p in packet.get("players", []):
            self.players[int(p["slot"])] = p.get("alias") or p.get("name") or str(p["slot"])
        for slot, info in packet.get("slot_info", {}).items():
            self.slot_games[int(slot)] = info.get("game", "")

    def load_data_package(self, packet: dict[str, Any]) -> None:
        for game, data in packet.get("data", {}).get("games", {}).items():
            self.items[game] = {v: k for k, v in data.get("item_name_to_id", {}).items()}
            self.locations[game] = {v: k for k, v in data.get("location_name_to_id", {}).items()}

    def player(self, slot: int) -> str:
        return self.players.get(slot, f"Player {slot}")

    def item(self, slot: int, item_id: int) -> str:
        return self.items.get(self.slot_games.get(slot, ""), {}).get(item_id, f"Item {item_id}")

    def location(self, slot: int, location_id: int) -> str:
        return self.locations.get(self.slot_games.get(slot, ""), {}).get(location_id, f"Location {location_id}")
