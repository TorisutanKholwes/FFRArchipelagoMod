"""ffr_bridge: connects FINAL FANTASY RESONANCE (FFResonanceAP mod) to an Archipelago server.

Usage:
  python -m ffr_bridge [--ipc-dir DIR]                        settings come from the game:
                                                              title screen > Archipelago Options
  python -m ffr_bridge --slot NAME [--server HOST:PORT] [--password PW] [--ipc-dir DIR]

With --slot, the password can also come from the FFR_AP_PASSWORD environment variable, or is
prompted for when the room requires one. Settings sent from the game always replace the command-line
ones. The password is never logged.
"""
from __future__ import annotations

import argparse
import asyncio
import getpass
import logging
import os
import re
import signal
import sys
import uuid as uuid_mod

from . import __version__
from .client import BridgeClient
from .ipc import IpcChannel

GAME_DIR_NAME = "FINAL FANTASY RESONANCE"
MOD_IPC_SUBPATH = os.path.join("FFRS", "Binaries", "Win64", "ue4ss", "Mods", "FFResonanceAP", "ipc")


def find_ipc_dir() -> str | None:
    """Locate the mod's ipc folder in a Steam library (Linux and Windows default locations)."""
    vdfs = [
        os.path.expanduser("~/.local/share/Steam/steamapps/libraryfolders.vdf"),
        os.path.expanduser("~/.steam/steam/steamapps/libraryfolders.vdf"),
        r"C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf",
    ]
    for vdf in vdfs:
        try:
            with open(vdf, encoding="utf-8") as f:
                libraries = re.findall(r'"path"\s+"([^"]+)"', f.read())
        except OSError:
            continue
        for lib in libraries:
            cand = os.path.join(lib.replace("\\\\", "\\"), "steamapps", "common", GAME_DIR_NAME, MOD_IPC_SUBPATH)
            if os.path.isdir(cand):
                return cand
    return None


def load_uuid(ipc_dir: str) -> str:
    path = os.path.join(ipc_dir, "bridge_uuid.txt")
    try:
        with open(path, encoding="utf-8") as f:
            value = f.read().strip()
            if value:
                return value
    except OSError:
        pass
    value = str(uuid_mod.uuid4())
    with open(path, "w", encoding="utf-8") as f:
        f.write(value + "\n")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="ffr_bridge", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", default="localhost:38281",
                        help="host:port, ws://host:port or wss://host:port (default localhost:38281; used with --slot)")
    parser.add_argument("--slot", default=None,
                        help="your slot (player) name; omit it to enter the settings in the game")
    parser.add_argument("--password", default=os.environ.get("FFR_AP_PASSWORD"), help="room password")
    parser.add_argument("--ipc-dir", default=None, help="the mod's ipc folder (auto-detected from Steam)")
    parser.add_argument("--ca-file", default=None, help="extra CA certificate for wss:// servers with private certificates")
    parser.add_argument("--death-link", choices=("auto", "on", "off"), default="auto",
                        help="DeathLink: auto follows the YAML option (default); on/off override it")
    parser.add_argument("--log-file", default=None, help="also write the log to this file")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if args.log_file:
        handlers.append(logging.FileHandler(args.log_file, encoding="utf-8"))
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, handlers=handlers,
                        format="%(asctime)s %(levelname)s %(message)s")
    log = logging.getLogger("ffr_bridge")

    ipc_dir = args.ipc_dir or find_ipc_dir()
    if not ipc_dir:
        log.error("Could not find the mod's ipc folder. Install the mod or pass --ipc-dir.")
        return 2
    try:
        ipc = IpcChannel(ipc_dir)
    except FileNotFoundError as e:
        log.error("%s", e)
        return 2
    log.info("ffr_bridge %s starting; IPC folder: %s", __version__, ipc_dir)

    def prompt() -> str | None:
        if sys.stdin.isatty():
            return getpass.getpass("Room password: ")
        log.error("The room needs a password: use --password or FFR_AP_PASSWORD")
        return None

    cli_mode = args.slot is not None
    if cli_mode:
        log.info("Using command-line settings: %s, slot %s", args.server, args.slot)
    else:
        log.info("No --slot: enter the server, port and slot in the game (title screen > Archipelago Options)")
    try:
        client = BridgeClient(args.server if cli_mode else None, args.slot, args.password, load_uuid(ipc_dir), ipc,
                              password_prompt=prompt if cli_mode else None, ca_file=args.ca_file,
                              death_link={"auto": None, "on": True, "off": False}[args.death_link],
                              exit_on_refusal=cli_mode)
    except ValueError as e:
        log.error("Invalid --server: %s", e)
        return 2

    async def runner() -> None:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, client.stop)
            except (NotImplementedError, RuntimeError):
                pass  # Windows: Ctrl+C raises KeyboardInterrupt instead
        await client.run()

    try:
        asyncio.run(runner())
    except KeyboardInterrupt:
        pass
    return 1 if client.core.status == "error" else 0


if __name__ == "__main__":
    sys.exit(main())
