"""Send one DeathLink from another slot of a running Archipelago room (testing aid).

Usage (from FFResonanceMod/bridge, with its venv):
  .venv/bin/python ../tools/send_deathlink.py --server localhost:38281 --slot Other [--password PW]
      [--cause "Other was squashed."] [--game "Final Fantasy Resonance"]

The slot connects with the "DeathLink" tag, sends a Bounce exactly as CommonClient.send_death does, and
disconnects. Every other DeathLink client in the room (e.g. the FFR bridge) receives it.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import time
import uuid

import websockets


async def send(server: str, slot: str, password: str, cause: str, game: str) -> None:
    url = server if "://" in server else f"ws://{server}"
    async with websockets.connect(url, max_size=None) as ws:
        json.loads(await ws.recv())  # RoomInfo
        await ws.send(json.dumps([{
            "cmd": "Connect", "password": password, "game": game, "name": slot, "uuid": str(uuid.uuid4()),
            "version": {"major": 0, "minor": 6, "build": 8, "class": "Version"},
            "items_handling": 0, "tags": ["DeathLink"], "slot_data": False}]))
        while True:
            for pkt in json.loads(await ws.recv()):
                if pkt["cmd"] == "ConnectionRefused":
                    raise SystemExit(f"refused: {pkt.get('errors')}")
                if pkt["cmd"] == "Connected":
                    await ws.send(json.dumps([{"cmd": "Bounce", "tags": ["DeathLink"], "data": {
                        "time": time.time(), "source": slot, "cause": cause or f"{slot} died (test)."}}]))
                    await asyncio.sleep(1.0)
                    print(f"DeathLink sent from {slot}")
                    return


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--server", default="localhost:38281")
    p.add_argument("--slot", required=True)
    p.add_argument("--password", default="")
    p.add_argument("--cause", default="")
    p.add_argument("--game", default="Final Fantasy Resonance")
    a = p.parse_args()
    asyncio.run(send(a.server, a.slot, a.password, a.cause, a.game))


if __name__ == "__main__":
    main()
