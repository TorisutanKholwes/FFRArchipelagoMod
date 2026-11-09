"""End-to-end test of the bridge against a real Archipelago MultiServer.

Needs the Archipelago fork with its Python 3.13 venv (test-only dependency, documented in README):
  FFR_AP_FORK=/path/to/ArchipelagoFFResonance   (default: ../../ArchipelagoFFResonance)

Scenario (the game mod is simulated by writing ipc/game_state.json, exactly as ap/ipc.lua does):
  1. generate a 2-player seed (two Final Fantasy Resonance worlds), start a password-protected server;
  2. bridge connects + authenticates (bridge_state.json status "ready", seed/slot bound);
  3. "mod" reports 2 chest checks -> server confirms them;
  4. the other player checks all its locations -> items arrive in bridge_state.json;
  5. the bridge's socket drops -> it reconnects, nothing lost;
  6. the server is saved and restarted while the "mod" records a check offline -> after reconnect the
     offline check is confirmed and the received item list is unchanged;
  7. "mod" reports goal -> server marks the slot finished (status 30).
"""
from __future__ import annotations

import asyncio
import json
import os
import queue
import socket
import subprocess
import threading
import time

import pytest
import websockets

from ffr_bridge.client import BridgeClient
from ffr_bridge.core import PROTOCOL
from ffr_bridge.ipc import IpcChannel, read_json, write_json_atomic

HERE = os.path.dirname(os.path.abspath(__file__))
FORK = os.environ.get("FFR_AP_FORK", os.path.normpath(os.path.join(HERE, "..", "..", "..", "ArchipelagoFFResonance")))
FORK_PY = os.path.join(FORK, ".venv", "bin", "python")
PASSWORD = "test-pw"

pytestmark = pytest.mark.skipif(not os.path.exists(FORK_PY), reason=f"Archipelago fork venv not found at {FORK_PY}")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    def __init__(self, multidata: str, port: int, log_path: str, tls: tuple[str, str] | None = None) -> None:
        self.multidata, self.port, self.log_path, self.tls = multidata, port, log_path, tls
        self.proc: subprocess.Popen | None = None
        self.lines: queue.Queue[str] = queue.Queue()

    def start(self) -> None:
        self.proc = subprocess.Popen(
            [FORK_PY, "MultiServer.py", "--host", "127.0.0.1", "--port", str(self.port),
             "--password", PASSWORD, self.multidata]
            + (["--cert", self.tls[0], "--cert_key", self.tls[1]] if self.tls else []),
            cwd=FORK, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            env={**os.environ, "PYTHONUNBUFFERED": "1"})  # console output is print()-based
        log = open(self.log_path, "a", encoding="utf-8")

        def pump() -> None:
            for line in self.proc.stdout:
                log.write(line)
                log.flush()
                self.lines.put(line)
        threading.Thread(target=pump, daemon=True).start()
        self.wait_for("server listening", 60)

    def wait_for(self, text: str, timeout: float) -> str:
        end = time.time() + timeout
        while time.time() < end:
            try:
                line = self.lines.get(timeout=0.5)
            except queue.Empty:
                continue
            if text in line:
                return line
        raise AssertionError(f"server never printed {text!r} (see {self.log_path})")

    def command(self, cmd: str) -> None:
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.command("/save")
            self.wait_for("Game saved", 20)
            self.command("/exit")
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                self.proc.kill()


@pytest.fixture(scope="module")
def seed(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("seed")
    players = tmp / "players"
    players.mkdir()
    (players / "p1.yaml").write_text("name: FFRPlayer\ngame: Final Fantasy Resonance\nFinal Fantasy Resonance: {}\n")
    (players / "p2.yaml").write_text("name: Other\ngame: Final Fantasy Resonance\nFinal Fantasy Resonance: {}\n")
    out = tmp / "out"
    subprocess.run([FORK_PY, "Generate.py", "--player_files_path", str(players), "--outputpath", str(out),
                    "--seed", "4242"], cwd=FORK, check=True, capture_output=True, timeout=300)
    zips = [p for p in out.iterdir() if p.suffix == ".zip"]
    assert len(zips) == 1
    return str(zips[0]), tmp


async def wait_until(predicate, timeout: float, what: str):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        await asyncio.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


async def other_player_checks_everything(port: int) -> int:
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await ws.recv()  # RoomInfo
        await ws.send(json.dumps([{"cmd": "Connect", "password": PASSWORD, "game": "Final Fantasy Resonance",
                                   "name": "Other", "uuid": "other", "items_handling": 0,
                                   "version": {"major": 0, "minor": 6, "build": 9, "class": "Version"},
                                   "tags": [], "slot_data": False}]))
        while True:
            for pkt in json.loads(await ws.recv()):
                if pkt["cmd"] == "Connected":
                    locs = pkt["missing_locations"]
                    await ws.send(json.dumps([{"cmd": "LocationChecks", "locations": locs}]))
                    await asyncio.sleep(1.0)
                    return len(locs)
                if pkt["cmd"] == "ConnectionRefused":
                    raise AssertionError(pkt)


async def server_slot_status(port: int, slot: int) -> int:
    async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
        await ws.recv()
        await ws.send(json.dumps([{"cmd": "Connect", "password": PASSWORD, "game": "Final Fantasy Resonance",
                                   "name": "Other", "uuid": "other2", "items_handling": 0,
                                   "version": {"major": 0, "minor": 6, "build": 9, "class": "Version"},
                                   "tags": [], "slot_data": False}]))
        while True:
            for pkt in json.loads(await ws.recv()):
                if pkt["cmd"] == "Connected":
                    key = f"_read_client_status_{pkt['team']}_{slot}"
                    await ws.send(json.dumps([{"cmd": "Get", "keys": [key]}]))
                elif pkt["cmd"] == "Retrieved":
                    return next(iter(pkt["keys"].values()))


def test_end_to_end(seed, tmp_path):
    multidata, seed_dir = seed
    port = free_port()
    ipc_dir = tmp_path / "ipc"
    ipc_dir.mkdir()
    server = Server(multidata, port, str(tmp_path / "server.log"))
    server.start()

    bridge_file = str(ipc_dir / "bridge_state.json")
    game_file = str(ipc_dir / "game_state.json")

    def bridge_state():
        return read_json(bridge_file) or {}

    def write_game(checked, goal=False):
        st = bridge_state()
        write_json_atomic(game_file, {"protocol": PROTOCOL, "seed_name": st["seed_name"], "slot_name": st["slot_name"],
                                      "checked": sorted(checked), "goal": goal, "applied_index": 0})

    async def scenario():
        client = BridgeClient(f"127.0.0.1:{port}", "FFRPlayer", PASSWORD, "uuid-test", IpcChannel(str(ipc_dir)))
        task = asyncio.create_task(client.run())
        try:
            # 2. authenticated + synchronized, state visible to the mod
            await wait_until(lambda: bridge_state().get("status") == "ready", 20, "bridge ready")
            st = bridge_state()
            assert st["slot_name"] == "FFRPlayer" and st["seed_name"]
            missing = sorted(client.core.missing_locations)
            assert len(missing) > 3

            # 3. checks reported by the mod are confirmed by the server
            checked = set(missing[:2])
            write_game(checked)
            await wait_until(lambda: checked <= set(bridge_state().get("server_checked", [])), 15, "checks confirmed")

            # 4. items from the other player arrive
            await other_player_checks_everything(port)
            # (player 0 = the server's start inventory: the chapter-1 zone access items, zone_locks default on)
            await wait_until(lambda: any(i["player"] == 2 for i in bridge_state().get("items", [])), 15,
                             "items from the other player")
            await asyncio.sleep(1.0)
            n_items = len(bridge_state()["items"])
            assert all(i["player"] in (0, 1, 2) for i in bridge_state()["items"])
            assert sum(1 for i in bridge_state()["items"] if i["player"] == 0) == 8

            # 5. socket drop -> reconnect -> nothing lost
            await client.socket.close()
            await wait_until(lambda: bridge_state().get("status") != "ready", 10, "disconnect noticed")
            await wait_until(lambda: bridge_state().get("status") == "ready", 20, "reconnected")
            assert len(bridge_state()["items"]) == n_items
            assert checked <= set(bridge_state()["server_checked"])

            # 6. server restart; a check happens while offline
            items_before_restart = list(bridge_state()["items"])
            server.stop()
            await wait_until(lambda: bridge_state().get("status") in ("reconnecting", "connecting"), 15, "offline")
            checked.add(missing[2])
            write_game(checked)
            server.start()
            await wait_until(lambda: bridge_state().get("status") == "ready", 90, "reconnected after restart")
            await wait_until(lambda: checked <= set(bridge_state().get("server_checked", [])), 15,
                             "offline check confirmed")
            # Nothing lost or reordered across the restart; the only possible additions are our own
            # items found at the location checked while offline.
            items_after = bridge_state()["items"]
            assert items_after[:len(items_before_restart)] == items_before_restart
            assert all(i["player"] == st["slot"] and i["location"] == missing[2]
                       for i in items_after[len(items_before_restart):])

            # 7. goal
            write_game(checked, goal=True)
            slot = bridge_state()["slot"]
            async def finished():
                return await server_slot_status(port, slot) == 30
            end = time.time() + 15
            while not await finished():
                assert time.time() < end, "goal not registered"
                await asyncio.sleep(0.5)
        finally:
            client.stop()
            await asyncio.wait_for(task, 10)

    try:
        asyncio.run(scenario())
    finally:
        server.stop()


def test_secure_websocket_fallback(seed, tmp_path):
    """Bare host:port against a TLS-only server: ws:// handshake fails, bridge retries with wss://."""
    multidata, _ = seed
    cert, key = str(tmp_path / "cert.pem"), str(tmp_path / "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                    "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"],
                   check=True, capture_output=True)
    port = free_port()
    ipc_dir = tmp_path / "ipc"
    ipc_dir.mkdir()
    server = Server(multidata, port, str(tmp_path / "server.log"), tls=(cert, key))
    server.start()

    async def scenario():
        client = BridgeClient(f"127.0.0.1:{port}", "FFRPlayer", PASSWORD, "uuid-tls", IpcChannel(str(ipc_dir)),
                              ca_file=cert)
        task = asyncio.create_task(client.run())
        try:
            await wait_until(lambda: (read_json(str(ipc_dir / "bridge_state.json")) or {}).get("status") == "ready",
                             30, "ready over wss")
            assert client.url.startswith("wss://")
        finally:
            client.stop()
            await asyncio.wait_for(task, 10)

    try:
        asyncio.run(scenario())
    finally:
        server.stop()


def test_refused_slot_is_reported_not_retried(seed, tmp_path):
    multidata, _ = seed
    port = free_port()
    ipc_dir = tmp_path / "ipc"
    ipc_dir.mkdir()
    server = Server(multidata, port, str(tmp_path / "server.log"))
    server.start()

    async def scenario():
        client = BridgeClient(f"127.0.0.1:{port}", "NoSuchSlot", PASSWORD, "uuid-bad", IpcChannel(str(ipc_dir)))
        await asyncio.wait_for(client.run(), 20)  # returns by itself: refusal is final
        st = read_json(str(ipc_dir / "bridge_state.json"))
        assert client.core.status == "error"
        assert "check the slot name" in client.core.status_message
        assert st["seed_name"] is None  # the mod must not bind to anything

    async def wrong_password_then_right():
        prompts = iter([PASSWORD])
        client = BridgeClient(f"127.0.0.1:{port}", "FFRPlayer", "wrong", "uuid-pw", IpcChannel(str(ipc_dir)),
                              password_prompt=lambda: next(prompts, None))
        task = asyncio.create_task(client.run())
        try:
            await wait_until(lambda: client.core.status == "ready", 20, "ready after re-prompt")
        finally:
            client.stop()
            await asyncio.wait_for(task, 10)

    try:
        asyncio.run(scenario())
        asyncio.run(wrong_password_then_right())
    finally:
        server.stop()


@pytest.fixture(scope="module")
def death_link_seed(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("dlseed")
    players = tmp / "players"
    players.mkdir()
    for name in ("FFRPlayer", "Other"):
        (players / f"{name}.yaml").write_text(
            f"name: {name}\ngame: Final Fantasy Resonance\nFinal Fantasy Resonance:\n  death_link: true\n")
    out = tmp / "out"
    subprocess.run([FORK_PY, "Generate.py", "--player_files_path", str(players), "--outputpath", str(out),
                    "--seed", "4243"], cwd=FORK, check=True, capture_output=True, timeout=300)
    return str(next(p for p in out.iterdir() if p.suffix == ".zip"))


def test_death_link_between_two_bridges(death_link_seed, tmp_path):
    """A game over reported by one "mod" reaches the other bridge (and is not echoed back to the sender)."""
    port = free_port()
    server = Server(death_link_seed, port, str(tmp_path / "server.log"))
    server.start()
    dirs = {name: tmp_path / name for name in ("FFRPlayer", "Other")}
    for d in dirs.values():
        d.mkdir()

    def bridge_state(name):
        return read_json(str(dirs[name] / "bridge_state.json")) or {}

    def write_deaths(name, count):
        st = bridge_state(name)
        write_json_atomic(str(dirs[name] / "game_state.json"), {
            "protocol": PROTOCOL, "seed_name": st["seed_name"], "slot_name": name, "checked": [], "goal": False,
            "deaths": {"count": count, "last_time": time.time()}, "updated": int(time.time())})

    async def scenario():
        clients = {name: BridgeClient(f"127.0.0.1:{port}", name, PASSWORD, f"uuid-{name}", IpcChannel(str(d)))
                   for name, d in dirs.items()}
        tasks = [asyncio.create_task(c.run()) for c in clients.values()]
        try:
            for name in dirs:
                await wait_until(lambda n=name: bridge_state(n).get("status") == "ready", 30, f"{name} ready")
                assert bridge_state(name)["death_link"]["enabled"] is True
            await asyncio.sleep(1.0)  # ConnectUpdate (DeathLink tag) processed by the server
            write_deaths("FFRPlayer", 2)   # baseline: deaths from before are never sent
            await asyncio.sleep(1.5)
            assert bridge_state("Other")["death_link"]["deaths"] == []
            write_deaths("FFRPlayer", 3)
            deaths = await wait_until(lambda: bridge_state("Other")["death_link"]["deaths"], 15, "death at Other")
            assert deaths == [{"id": 1, "source": "FFRPlayer", "cause": "FFRPlayer's party was wiped out."}]
            await asyncio.sleep(1.5)
            assert bridge_state("FFRPlayer")["death_link"]["deaths"] == []  # own Bounce not recorded
        finally:
            for c in clients.values():
                c.stop()
            await asyncio.wait_for(asyncio.gather(*tasks), 10)

    try:
        asyncio.run(scenario())
    finally:
        server.stop()


def test_settings_from_game_panel(seed, tmp_path):
    """Bridge started without settings; the "mod" sends them through ipc/connect_request.json (TD-032):
    wrong slot -> refusal shown, bridge keeps running; wrong password -> refusal; right settings -> ready;
    switching slot -> new slot bound, nothing kept from the previous one."""
    multidata, _ = seed
    port = free_port()
    ipc_dir = tmp_path / "ipc"
    ipc_dir.mkdir()
    server = Server(multidata, port, str(tmp_path / "server.log"))
    server.start()
    req_file = ipc_dir / "connect_request.json"

    def bridge_state():
        return read_json(str(ipc_dir / "bridge_state.json")) or {}

    def send(seq, slot, password):
        write_json_atomic(str(req_file), {"protocol": PROTOCOL, "seq": seq, "address": f"127.0.0.1:{port}",
                                          "slot": slot, "password": password, "game_session": "launch-1"})
        write_json_atomic(str(ipc_dir / "game_state.json"),
                          {"protocol": PROTOCOL, "updated": int(time.time()), "game_session": "launch-1"})

    def server_output():
        return (tmp_path / "server.log").read_text(encoding="utf-8", errors="replace")

    async def scenario():
        client = BridgeClient(None, None, None, "uuid-panel", IpcChannel(str(ipc_dir)), exit_on_refusal=False)
        task = asyncio.create_task(client.run())
        try:
            await wait_until(lambda: bridge_state().get("status") == "waiting_for_settings", 10, "waiting state")

            send(1, "NoSuchSlot", PASSWORD)
            await wait_until(lambda: bridge_state().get("request_seq") == 1
                             and bridge_state().get("status") == "error", 20, "slot refusal")
            assert "check the slot name" in bridge_state()["status_message"]
            assert not req_file.exists()
            assert not task.done()  # still waiting for the next settings

            send(2, "FFRPlayer", "wrong")
            await wait_until(lambda: bridge_state().get("request_seq") == 2
                             and bridge_state().get("status") == "error", 20, "password refusal")
            assert "password" in bridge_state()["status_message"]

            send(3, "FFRPlayer", PASSWORD)
            await wait_until(lambda: bridge_state().get("request_seq") == 3
                             and bridge_state().get("status") == "ready", 20, "ready")
            assert bridge_state()["slot_name"] == "FFRPlayer"
            assert not req_file.exists()
            assert PASSWORD not in (ipc_dir / "bridge_state.json").read_text()

            send(4, "Other", PASSWORD)
            await wait_until(lambda: bridge_state().get("request_seq") == 4
                             and bridge_state().get("status") == "ready", 20, "ready as Other")
            assert bridge_state()["slot_name"] == "Other"

            # The game that sent the settings is restarted (new launch id): disconnect, forget the password.
            write_json_atomic(str(ipc_dir / "game_state.json"),
                              {"protocol": PROTOCOL, "updated": int(time.time()), "game_session": "launch-2"})
            await wait_until(lambda: bridge_state().get("status") == "waiting_for_settings", 10, "disconnect on restart")
            assert "restarted" in bridge_state()["status_message"]
            assert bridge_state()["slot_name"] is None and client.password is None
            await wait_until(lambda: "Other (Team #1) has left" in server_output(), 10, "server sees the disconnect")
        finally:
            client.stop()
            await asyncio.wait_for(task, 10)

    try:
        asyncio.run(scenario())
    finally:
        server.stop()
