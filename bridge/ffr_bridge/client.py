"""Asynchronous Archipelago client loop for the bridge.

Lifecycle: [WAITING (no settings yet)] -> CONNECTING -> CONNECTED (RoomInfo) -> READY (Connected: authenticated)
           ; on loss -> RECONNECTING (exponential backoff) ;
           on ConnectionRefused -> ERROR (no automatic retry: the slot name/password/game must be fixed).

Settings come from the command line or from ipc/connect_request.json, written by the mod's
"Archipelago Options" panel on the title screen (TD-032). A new request replaces the current connection.
"""
from __future__ import annotations

import asyncio
import logging
import time
import ssl
import urllib.parse
from typing import Any, Callable

import websockets

from . import protocol
from .core import BridgeCore, Status
from .ipc import IpcChannel

log = logging.getLogger("ffr_bridge")

DEFAULT_PORT = 38281
RECONNECT_MIN = 2.0
RECONNECT_MAX = 60.0
IPC_INTERVAL = 0.5
GAME_TIMEOUT = 30.0  # seconds without a game_state.json update before the game counts as closed


class ConnectionRefused(Exception):
    """The server rejected the slot connection (not retried)."""


class RetryNow(Exception):
    """Reconnect immediately (e.g. after the user entered a new password)."""


# ConnectionRefused error codes (docs/network protocol.md) -> actionable message.
REFUSAL_MESSAGES = {
    "InvalidSlot": "no slot with this name in the room (check the slot name against your YAML 'name')",
    "InvalidGame": "this slot is not a Final Fantasy Resonance slot",
    "IncompatibleVersion": "the server's Archipelago version is incompatible with this client",
    "InvalidPassword": "wrong or missing room password",
    "InvalidItemsHandling": "the server rejected the item handling flags",
}


def game_gone_reason(game_state: dict[str, Any] | None, session: str, now: float,
                     timeout: float = GAME_TIMEOUT) -> str | None:
    """Why the game that sent the connection settings is gone, or None while it is still running.

    The mod rewrites game_state.json at least every 5 s with its per-launch `game_session` id
    (TD-032): a different id means the game was restarted, an old `updated` time means it was closed.
    """
    if game_state is None:
        return "the game was closed (no game state)"
    other = game_state.get("game_session")
    if isinstance(other, str) and other != session:
        return "the game was restarted"
    updated = game_state.get("updated")
    if not isinstance(updated, (int, float)) or now - updated > timeout:
        return "the game was closed"
    return None


def describe_refusal(errors: list[str]) -> str:
    return "; ".join(REFUSAL_MESSAGES.get(e, e) for e in errors) or "no reason given"


def normalize_address(address: str) -> tuple[str, bool]:
    """Return (url, scheme_was_explicit). Bare "host:port" becomes ws://host:port."""
    explicit = "://" in address
    url = address if explicit else f"ws://{address}"
    url = url.replace("archipelago://", "ws://")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("ws", "wss"):
        raise ValueError(f"unsupported scheme {parsed.scheme!r} (use ws:// or wss://)")
    if parsed.port is None:
        url = urllib.parse.urlunparse(parsed._replace(netloc=f"{parsed.netloc}:{DEFAULT_PORT}"))
    return url, explicit


def ssl_context(ca_file: str | None = None) -> ssl.SSLContext:
    """TLS context for wss://. `ca_file` adds a custom CA (self-hosted servers with private certs)."""
    try:
        import certifi  # optional, same CA bundle the Archipelago client uses
        ctx = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        ctx = ssl.create_default_context()
    if ca_file:
        ctx.load_verify_locations(cafile=ca_file)
    return ctx


class BridgeClient:
    def __init__(self, address: str | None, slot_name: str | None, password: str | None, uuid: str, ipc: IpcChannel,
                 password_prompt: Callable[[], str | None] | None = None, ca_file: str | None = None,
                 death_link: bool | None = None, exit_on_refusal: bool = True) -> None:
        """`address`/`slot_name` None = wait for the game's options panel (connect_request.json).

        `exit_on_refusal`: stop run() when the server refuses the slot (command-line use). When False,
        the refusal stays visible as status "error" until the game sends new settings.
        """
        self.url: str | None = None
        self.explicit_scheme = False
        if address is not None and slot_name is not None:
            self.url, self.explicit_scheme = normalize_address(address)
        self._death_link_override = death_link
        self.core = BridgeCore(slot_name=slot_name, death_link_override=death_link)
        if self.url is None:
            self.core.set_status(Status.WAITING, "waiting for settings from the game (Archipelago Options)")
        self.password = password
        self.password_prompt = password_prompt
        self.uuid = uuid
        self.ipc = ipc
        self.ca_file = ca_file
        self.exit_on_refusal = exit_on_refusal
        self.names = protocol.NameLookup()
        self.socket: Any = None
        self.stop_event = asyncio.Event()
        self._wake = asyncio.Event()          # set by stop() and reconfigure(): ends any wait
        self._reconfigured = False
        self.game_session: str | None = None  # launch id of the game that sent the settings
        self._state_dirty = True
        self._last_incompatible: str | None = None
        self._started_at = int(time.time())

    # --- public ---------------------------------------------------------------------

    async def run(self) -> None:
        ipc_task = asyncio.create_task(self._ipc_loop(), name="ipc")
        delay = RECONNECT_MIN
        try:
            while not self.stop_event.is_set():
                if self.url is None:
                    if self.core.status not in (Status.ERROR, Status.WAITING):
                        self.core.set_status(Status.WAITING, "waiting for settings from the game (Archipelago Options)")
                        self._state_dirty = True
                    log.info("Waiting for connection settings from the game (title screen > Archipelago Options)")
                    await self._wait(None)
                    continue
                try:
                    await self._session()
                    delay = RECONNECT_MIN  # clean disconnect after a working session
                except RetryNow:
                    delay = RECONNECT_MIN
                    continue
                except ConnectionRefused as e:
                    self.core.set_status(Status.ERROR, f"connection refused: {e}")
                    self._state_dirty = True
                    if self.exit_on_refusal:
                        log.error("Server refused the connection: %s. Fix the settings and restart the bridge.", e)
                        break
                    log.error("Server refused the connection: %s. Waiting for new settings from the game.", e)
                    await self._wait(None)
                    continue
                except (OSError, asyncio.TimeoutError, websockets.WebSocketException, ValueError) as e:
                    log.warning("Connection problem: %s", e or type(e).__name__)
                if self.stop_event.is_set():
                    break
                if self._consume_reconfigured():
                    delay = RECONNECT_MIN
                    continue
                self.core.on_disconnected(f"reconnecting in {delay:.0f}s")
                self._state_dirty = True
                log.info("Reconnecting in %.0f s", delay)
                await self._wait(delay)
                delay = min(delay * 2, RECONNECT_MAX)
        finally:
            if self.core.status not in (Status.ERROR, Status.WAITING):  # keep the reason visible
                self.core.on_disconnected("")
            self._write_state()
            ipc_task.cancel()

    def stop(self) -> None:
        self.stop_event.set()
        self._wake.set()
        if self.socket is not None:
            asyncio.ensure_future(self.socket.close())

    def reconfigure(self, address: str, slot_name: str, password: str | None, seq: int | None = None,
                    game_session: str | None = None) -> None:
        """Switch to new connection settings (from the game's options panel).

        Raises ValueError for an unusable address; the current connection is then left untouched.
        A fresh BridgeCore is used: items and checks of the previous slot must not leak into the new one.
        """
        url, explicit = normalize_address(address)
        self.url, self.explicit_scheme = url, explicit
        self.password = password or None
        self.password_prompt = None  # the game provides the password; never block on the terminal
        self.core = BridgeCore(slot_name=slot_name, death_link_override=self._death_link_override)
        self.core.request_seq = seq
        self.core.set_status(Status.CONNECTING, url)
        self.game_session = game_session
        self.names = protocol.NameLookup()
        self._state_dirty = True
        self._reconfigured = True
        self._wake.set()
        if self.socket is not None:
            asyncio.ensure_future(self.socket.close())
        log.info("New settings from the game: %s, slot %s, password %s", url, slot_name,
                 "set" if self.password else "none")

    def disconnect_for_game(self, reason: str) -> None:
        """The game that sent the settings is gone: disconnect, forget the password, wait for new settings."""
        log.info("Disconnecting: %s. Enter the password again in the game (Archipelago Options).", reason)
        self.url = None
        self.password = None
        self.game_session = None
        self.core = BridgeCore(slot_name=None, death_link_override=self._death_link_override)
        self.core.set_status(Status.WAITING, f"disconnected: {reason}")
        self.names = protocol.NameLookup()
        self._state_dirty = True
        self._reconfigured = True
        self._wake.set()
        if self.socket is not None:
            asyncio.ensure_future(self.socket.close())

    async def _wait(self, timeout: float | None) -> None:
        """Sleep until stop(), reconfigure() or the timeout."""
        try:
            await asyncio.wait_for(self._wake.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            pass
        if not self.stop_event.is_set():
            self._wake.clear()
            self._consume_reconfigured()

    def _consume_reconfigured(self) -> bool:
        was, self._reconfigured = self._reconfigured, False
        return was

    # --- connection -------------------------------------------------------------------

    async def _open(self) -> Any:
        url = self.url
        try:
            return await self._connect(url)
        except websockets.InvalidMessage:
            # Same fallback as CommonClient: a ws:// handshake answered with TLS -> retry with wss://
            if url.startswith("ws://") and not self.explicit_scheme:
                url = "wss://" + url[len("ws://"):]
                log.info("Retrying with secure WebSocket: %s", url)
                sock = await self._connect(url)
                self.url = url
                return sock
            raise

    async def _connect(self, url: str) -> Any:
        log.info("Connecting to %s", url)
        self.core.set_status(Status.CONNECTING, url)
        self._state_dirty = True
        return await asyncio.wait_for(
            websockets.connect(url, ssl=ssl_context(self.ca_file) if url.startswith("wss://") else None,
                               ping_interval=None, ping_timeout=None, max_size=None),
            timeout=15)

    async def _session(self) -> None:
        self._reconfigured = False
        self.socket = await self._open()
        try:
            if self._reconfigured:  # new settings arrived while this connection was opening
                return
            async for raw in self.socket:
                for packet in protocol.decode(raw):
                    if self._reconfigured:  # never let the old slot's packets touch the new state
                        log.info("Closing the previous connection (new settings)")
                        return
                    await self._handle(packet)
            if not self._reconfigured:
                log.warning("Server closed the connection")
        except websockets.ConnectionClosed as e:
            log.warning("Connection closed: %s", e)
        finally:
            try:
                await self.socket.close()
            except Exception:  # noqa: BLE001 - closing an already broken socket
                pass
            self.socket = None

    async def _send(self, packets: list[dict[str, Any]]) -> None:
        if packets and self.socket is not None:
            await self.socket.send(protocol.encode(packets))
            for p in packets:
                if p["cmd"] == "LocationChecks":
                    log.info("Sent LocationChecks %s", p["locations"])
                elif p["cmd"] == "StatusUpdate":
                    log.info("Sent goal (StatusUpdate %s)", p["status"])
                elif p["cmd"] == "Sync":
                    log.info("Item index mismatch: sent Sync")
                elif p["cmd"] == "Bounce":
                    log.info("DeathLink sent: %s", p["data"]["cause"])
                elif p["cmd"] == "ConnectUpdate":
                    log.info("Connection tags set to %s", p["tags"])

    async def _handle(self, packet: dict[str, Any]) -> None:
        cmd = packet["cmd"]
        core = self.core
        if cmd == "RoomInfo":
            core.on_room_info(packet)
            log.info("Room info: seed %s, AP %s", packet.get("seed_name"), packet.get("version"))
            if packet.get("password") and not self.password and self.password_prompt:
                self.password = self.password_prompt()
            # Every game of the room, so items and locations of other worlds get real names in game.
            games = sorted(set(packet.get("games") or []) | {protocol.GAME})
            await self._send([protocol.get_data_package(games)])
            await self._send([protocol.connect(core.slot_name, self.uuid, self.password)])
        elif cmd == "DataPackage":
            self.names.load_data_package(packet)
        elif cmd == "Connected":
            core.on_connected(packet)
            self.names.load_connected(packet)
            log.info("Authenticated as %s (slot %s, team %s); %d checked, %d missing locations",
                     core.slot_name, core.slot, core.team, len(core.server_checked), len(core.missing_locations))
            if core.death_link:
                # Slot data (the YAML death_link option) is only known now, hence ConnectUpdate.
                await self._send([protocol.connect_update([protocol.DEATH_LINK_TAG])])
        elif cmd == "Bounced":
            death = core.on_bounced(packet)
            if death:
                log.info("DeathLink received (#%d) from %s: %s", death["id"], death["source"], death["cause"])
        elif cmd == "ConnectionRefused":
            errors = list(packet.get("errors", []))
            if errors == ["InvalidPassword"] and self.password_prompt:
                log.error("Server refused the connection: %s", describe_refusal(errors))
                new_password = self.password_prompt()
                if new_password:
                    self.password = new_password
                    raise RetryNow()
            raise ConnectionRefused(describe_refusal(errors))
        elif cmd == "ReceivedItems":
            await self._send(core.on_received_items(packet))
            for it in packet["items"]:
                log.info("Received %s from %s", self.names.item(core.slot or 0, it["item"]),
                         self.names.player(it["player"]))
            await self._send(core.packets_for_game_state(self.ipc.read_game_state()))
        elif cmd == "RoomUpdate":
            core.on_room_update(packet)
        elif cmd == "PrintJSON":
            text = core.on_print_json(packet, self.names)
            if text:
                log.info("[server] %s", text)
        elif cmd == "InvalidPacket":
            log.error("Server rejected a packet: %s", packet)
        self._state_dirty = True

    # --- IPC --------------------------------------------------------------------------

    def _write_state(self) -> None:
        try:
            self.ipc.write_bridge_state(self.core.bridge_state(self.names))
            self._state_dirty = False
        except OSError as e:
            log.error("Cannot write bridge state: %s", e)

    async def _ipc_loop(self) -> None:
        last_heartbeat = 0.0
        loop = asyncio.get_running_loop()
        while True:
            self._check_connect_request()
            game_state = self.ipc.read_game_state()
            if self.game_session is not None:
                gone = game_gone_reason(game_state, self.game_session, time.time())
                if gone:
                    self.disconnect_for_game(gone)
            if game_state and game_state.get("delivery_error"):
                log.error("Mod reports an item delivery error: %s", game_state["delivery_error"])
            # Ignore a refusal written before this bridge started (left over from a previous seed).
            fresh = game_state is not None and (game_state.get("updated") or 0) >= self._started_at
            incompatible = game_state.get("incompatible") if fresh else None
            if incompatible and incompatible != self._last_incompatible:
                log.error("Mod refuses this seed: %s", incompatible)
            self._last_incompatible = incompatible
            try:
                await self._send(self.core.packets_for_game_state(game_state))
            except websockets.WebSocketException as e:
                log.warning("Could not send checks: %s", e)
            now = loop.time()
            if self._state_dirty or now - last_heartbeat >= 5:
                self._write_state()
                last_heartbeat = now
            await asyncio.sleep(IPC_INTERVAL)

    def _check_connect_request(self) -> None:
        request = self.ipc.consume_connect_request()
        if request is None:
            return
        if request.get("invalid"):
            log.error("Ignored a malformed connection request from the game")
            self.core.set_status(Status.ERROR, "malformed connection request from the game")
            self._state_dirty = True
            return
        try:
            self.reconfigure(request["address"].strip(), request["slot"].strip(), request.get("password"),
                             request["seq"], request.get("game_session"))
        except ValueError as e:
            # Drop the current connection too: the player asked for a different server.
            log.error("Invalid server address from the game: %s", e)
            self.url = None
            self.core = BridgeCore(slot_name=None, death_link_override=self._death_link_override)
            self.core.request_seq = request["seq"]
            self.core.set_status(Status.ERROR, f"invalid server address: {e}")
            self._state_dirty = True
            self._reconfigured = True
            self._wake.set()
            if self.socket is not None:
                asyncio.ensure_future(self.socket.close())
