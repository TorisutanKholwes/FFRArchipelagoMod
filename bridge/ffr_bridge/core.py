"""Synchronization logic between the Archipelago server and the game mod (no I/O; unit-tested).

Sources of truth:
  * the server for received items (ordered list) and confirmed checks;
  * the mod's game_state.json for locations checked in game (persisted by the mod, so checks made
    while the bridge or server was offline are resent on the next connection).

DeathLink (live only, TD-030): the mod counts game overs in memory (game_state "deaths"); the bridge
sends one Bounce per increment seen after its first observation. Deaths received from the server are
listed in bridge_state "death_link" with ids that restart with every bridge run ("session" changes).
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from . import protocol

PROTOCOL = 1
MAX_MESSAGES = 50
MAX_DEATHS = 20
DEATH_SEND_MAX_AGE = 120  # seconds: an older game over (e.g. while offline) is not sent any more


class Status:
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    CONNECTED = "connected"          # WebSocket open, RoomInfo received, not authenticated yet
    READY = "ready"                  # Connected received: slot authenticated, state in sync
                                     # (the server sends ReceivedItems right after, only if items exist)
    RECONNECTING = "reconnecting"
    ERROR = "error"
    WAITING = "waiting_for_settings"  # no server/slot yet: waiting for the game's options panel


@dataclass
class BridgeCore:
    slot_name: str | None
    status: str = Status.DISCONNECTED
    status_message: str = ""
    seed_name: str | None = None
    slot: int | None = None
    team: int | None = None
    slot_data: dict[str, Any] = field(default_factory=dict)
    received: list[dict[str, int]] = field(default_factory=list)
    server_checked: set[int] = field(default_factory=set)
    missing_locations: set[int] = field(default_factory=set)
    in_flight: set[int] = field(default_factory=set)
    goal_sent: bool = False
    messages: list[dict[str, Any]] = field(default_factory=list)
    message_counter: int = 0
    # DeathLink
    death_link_override: bool | None = None   # --death-link on/off; None follows slot_data
    death_session: int = field(default_factory=lambda: int(time.time() * 1000))
    deaths_in: list[dict[str, Any]] = field(default_factory=list)
    death_counter: int = 0
    death_baseline: int | None = None         # game-over count already handled (sent or skipped)
    last_death_time: float = 0.0              # newest DeathLink time sent or received (echo filter)
    request_seq: int | None = None            # last connect_request.json applied (shown by the mod)

    # --- connection lifecycle -------------------------------------------------

    def set_status(self, status: str, message: str = "") -> None:
        self.status = status
        self.status_message = message

    def on_room_info(self, packet: dict[str, Any]) -> None:
        seed = packet.get("seed_name")
        if self.seed_name is not None and seed != self.seed_name:
            # A different room/seed: everything received so far belongs to another multiworld.
            self.received.clear()
            self.server_checked.clear()
        self.seed_name = seed
        self.set_status(Status.CONNECTED, "room info received")

    def on_connected(self, packet: dict[str, Any]) -> None:
        self.slot = packet["slot"]
        self.team = packet["team"]
        self.slot_data = packet.get("slot_data") or {}
        self.server_checked = set(packet.get("checked_locations", []))
        self.missing_locations = set(packet.get("missing_locations", []))
        self.in_flight.clear()
        self.goal_sent = False
        self.set_status(Status.READY, "slot authenticated")

    @property
    def death_link(self) -> bool:
        """DeathLink active for this connection (YAML option unless overridden on the command line)."""
        if self.death_link_override is not None:
            return self.death_link_override
        return bool(self.slot_data.get("death_link"))

    def on_disconnected(self, reason: str) -> None:
        self.in_flight.clear()
        self.set_status(Status.RECONNECTING if reason else Status.DISCONNECTED, reason)

    # --- items ----------------------------------------------------------------

    def on_received_items(self, packet: dict[str, Any]) -> list[dict[str, Any]]:
        """Apply a ReceivedItems packet. Returns packets to send (a Sync on index mismatch)."""
        index = packet["index"]
        items = packet["items"]
        if index == 0:
            self.received = []
        elif index != len(self.received):
            return [protocol.sync()]
        for it in items:
            self.received.append({
                "item": it["item"], "location": it["location"], "player": it["player"], "flags": it["flags"],
            })
        return []

    # --- locations --------------------------------------------------------------

    def on_room_update(self, packet: dict[str, Any]) -> None:
        confirmed = set(packet.get("checked_locations", []))
        self.server_checked |= confirmed
        self.missing_locations -= confirmed
        self.in_flight -= confirmed

    def game_state_matches(self, game_state: dict[str, Any] | None) -> bool:
        return bool(game_state) and game_state.get("protocol") == PROTOCOL \
            and game_state.get("seed_name") == self.seed_name and game_state.get("slot_name") == self.slot_name

    def packets_for_game_state(self, game_state: dict[str, Any] | None) -> list[dict[str, Any]]:
        """Location checks / goal that the server does not know about yet."""
        if self.status != Status.READY or not self.game_state_matches(game_state):
            return []
        out: list[dict[str, Any]] = []
        local = {int(x) for x in game_state.get("checked") or []}
        new = local - self.server_checked - self.in_flight
        unknown = {x for x in new if self.missing_locations and x not in self.missing_locations}
        if unknown:
            # Not a location of this slot (e.g. mod data newer than the seed); never send them.
            new -= unknown
        if new:
            self.in_flight |= new
            out.append(protocol.location_checks(new))
        if game_state.get("goal") and not self.goal_sent:
            self.goal_sent = True
            out.append(protocol.status_goal())
        out.extend(self._death_packets(game_state))
        return out

    # --- DeathLink ----------------------------------------------------------------

    def _death_packets(self, game_state: dict[str, Any]) -> list[dict[str, Any]]:
        deaths = game_state.get("deaths")
        if not isinstance(deaths, dict) or not isinstance(deaths.get("count"), int):
            return []
        count = deaths["count"]
        if self.death_baseline is None or count < self.death_baseline:
            # First observation in this bridge run, or the game restarted (its counter is in memory).
            self.death_baseline = count
            return []
        if count == self.death_baseline:
            return []
        self.death_baseline = count
        if not self.death_link:
            return []
        died_at = deaths.get("last_time")
        now = time.time()
        if not isinstance(died_at, (int, float)) or now - died_at > DEATH_SEND_MAX_AGE:
            self.add_message("DeathLink: a game over happened while offline; not sent")
            return []
        self.last_death_time = now
        cause = deaths.get("last_cause") or f"{self.slot_name}'s party was wiped out."
        return [protocol.death_bounce(self.slot_name, str(cause), now)]

    def on_bounced(self, packet: dict[str, Any]) -> dict[str, Any] | None:
        """Record a DeathLink from another player. Returns the recorded death, or None if ignored."""
        if protocol.DEATH_LINK_TAG not in (packet.get("tags") or []) or not self.death_link:
            return None
        data = packet.get("data") or {}
        died_at = data.get("time")
        if not isinstance(died_at, (int, float)) or died_at == self.last_death_time:
            return None  # malformed, or our own Bounce echoed back
        self.last_death_time = max(self.last_death_time, died_at)
        self.death_counter += 1
        death = {"id": self.death_counter, "source": str(data.get("source") or "?"),
                 "cause": str(data.get("cause") or "")}
        self.deaths_in.append(death)
        del self.deaths_in[:-MAX_DEATHS]
        self.add_message(f"DeathLink: {death['cause'] or 'killed by ' + death['source']}")
        return death

    # --- messages ---------------------------------------------------------------

    def add_message(self, text: str) -> None:
        self.message_counter += 1
        self.messages.append({"id": self.message_counter, "text": text})
        del self.messages[:-MAX_MESSAGES]

    # --- IPC snapshot -------------------------------------------------------------

    def bridge_state(self) -> dict[str, Any]:
        return {
            "protocol": PROTOCOL,
            "status": self.status,
            "status_message": self.status_message,
            "seed_name": self.seed_name if self.slot is not None else None,
            "slot_name": self.slot_name if self.slot is not None else None,
            "slot": self.slot,
            "team": self.team,
            "slot_data": self.slot_data if self.slot is not None else None,
            "items": self.received,
            "server_checked": sorted(self.server_checked),
            "messages": self.messages,
            "death_link": {"enabled": self.death_link if self.slot is not None else False,
                           "session": self.death_session, "deaths": self.deaths_in},
            "request_seq": self.request_seq,
            "updated": int(time.time()),
        }
