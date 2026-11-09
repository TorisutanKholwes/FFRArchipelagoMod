"""Connection settings sent by the mod's title-screen "Archipelago Options" panel (TD-032)."""
from __future__ import annotations

import asyncio
import json

import pytest

from ffr_bridge.client import BridgeClient
from ffr_bridge.core import Status
from ffr_bridge.ipc import CONNECT_REQUEST, IpcChannel, read_json


def request(seq=1, address="localhost:38281", slot="P1", password=None):
    return {"protocol": 1, "seq": seq, "address": address, "slot": slot, "password": password}


def test_request_is_consumed_and_deleted(tmp_path):
    ipc = IpcChannel(str(tmp_path))
    (tmp_path / CONNECT_REQUEST).write_text(json.dumps(request(password="secret")))
    data = ipc.consume_connect_request()
    assert data["slot"] == "P1" and data["password"] == "secret"
    assert not (tmp_path / CONNECT_REQUEST).exists()  # the password must not stay on disk
    assert ipc.consume_connect_request() is None


def test_tmp_copy_is_used_when_final_file_missing(tmp_path):
    ipc = IpcChannel(str(tmp_path))
    (tmp_path / (CONNECT_REQUEST + ".tmp")).write_text(json.dumps(request(seq=7)))
    assert ipc.consume_connect_request()["seq"] == 7
    assert not (tmp_path / (CONNECT_REQUEST + ".tmp")).exists()


@pytest.mark.parametrize("bad", [
    {"seq": 1, "address": "", "slot": "P1"},
    {"seq": 1, "address": "localhost", "slot": "  "},
    {"seq": "1", "address": "localhost", "slot": "P1"},
    {"seq": 1, "address": "localhost", "slot": "P1", "password": 5},
    ["not", "a", "dict"],
])
def test_malformed_request_is_flagged_and_deleted(tmp_path, bad):
    ipc = IpcChannel(str(tmp_path))
    (tmp_path / CONNECT_REQUEST).write_text(json.dumps(bad))
    assert ipc.consume_connect_request() == {"invalid": True}
    assert not (tmp_path / CONNECT_REQUEST).exists()


def test_half_written_request_is_left_alone(tmp_path):
    ipc = IpcChannel(str(tmp_path))
    (tmp_path / CONNECT_REQUEST).write_text('{"seq": 1, "addr')
    assert ipc.consume_connect_request() is None
    assert (tmp_path / CONNECT_REQUEST).exists()


def test_wait_mode_then_reconfigure(tmp_path):
    async def scenario():
        client = BridgeClient(None, None, None, "uuid", IpcChannel(str(tmp_path)), exit_on_refusal=False)
        assert client.url is None
        assert client.core.status == Status.WAITING
        client._write_state()
        st = read_json(str(tmp_path / "bridge_state.json"))
        assert st["status"] == "waiting_for_settings" and st["seed_name"] is None

        client.core.received.append({"item": 1, "location": 2, "player": 3, "flags": 0})
        client.reconfigure("wss://archipelago.gg:12345", "P2", "pw", seq=3)
        assert client.url == "wss://archipelago.gg:12345" and client.explicit_scheme
        assert client.core.slot_name == "P2" and client.core.received == []  # nothing leaks from the old slot
        assert client.core.request_seq == 3 and client.password == "pw" and client.password_prompt is None

        with pytest.raises(ValueError):
            client.reconfigure("http://example.com:1", "P3", None)
        assert client.core.slot_name == "P2"  # unchanged after a rejected address
    asyncio.run(scenario())


def test_invalid_address_request_reports_error(tmp_path):
    async def scenario():
        client = BridgeClient("localhost:1", "P1", None, "uuid", IpcChannel(str(tmp_path)))
        (tmp_path / CONNECT_REQUEST).write_text(json.dumps(request(seq=9, address="ftp://x:1")))
        client._check_connect_request()
        assert client.url is None
        assert client.core.status == Status.ERROR and "invalid server address" in client.core.status_message
        assert client.core.bridge_state()["request_seq"] == 9
    asyncio.run(scenario())


def test_password_never_written_to_bridge_state(tmp_path):
    async def scenario():
        client = BridgeClient(None, None, None, "uuid", IpcChannel(str(tmp_path)))
        (tmp_path / CONNECT_REQUEST).write_text(json.dumps(request(password="hunter2-secret")))
        client._check_connect_request()
        client._write_state()
        assert "hunter2-secret" not in (tmp_path / "bridge_state.json").read_text()
    asyncio.run(scenario())


def test_game_gone_reason():
    from ffr_bridge.client import game_gone_reason
    now = 1000.0
    assert game_gone_reason({"updated": 995, "game_session": "A"}, "A", now) is None
    assert game_gone_reason({"updated": 995}, "A", now) is None                    # older mod: no session id
    assert "restarted" in game_gone_reason({"updated": 999, "game_session": "B"}, "A", now)
    assert "closed" in game_gone_reason({"updated": 960, "game_session": "A"}, "A", now)
    assert "closed" in game_gone_reason({"game_session": "A"}, "A", now)
    assert "closed" in game_gone_reason(None, "A", now)


def test_disconnect_for_game_forgets_password(tmp_path):
    async def scenario():
        client = BridgeClient(None, None, None, "uuid", IpcChannel(str(tmp_path)), exit_on_refusal=False)
        client.reconfigure("localhost:38281", "P1", "secret", seq=5, game_session="A")
        assert client.game_session == "A"
        client.disconnect_for_game("the game was closed")
        assert client.url is None and client.password is None and client.game_session is None
        st = client.core.bridge_state()
        assert st["status"] == "waiting_for_settings" and "the game was closed" in st["status_message"]
        assert st["slot_name"] is None and st["request_seq"] is None
    asyncio.run(scenario())
