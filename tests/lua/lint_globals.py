#!/usr/bin/env python3
"""Report globals read or written by the mod's Lua scripts that are neither Lua nor UE4SS globals.

A local function used above its definition compiles as a global access and only fails in game
(2026-11-09: zonegate.lua `safe`). Run from FFResonanceMod/: python3 tests/lua/lint_globals.py
"""
import glob
import re
import subprocess
import sys

LUA = {"assert", "error", "ipairs", "next", "pairs", "pcall", "print", "rawget", "rawset", "require",
       "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "xpcall", "table", "string",
       "math", "os", "io", "utf8", "debug", "package", "coroutine", "_G", "load"}
UE4SS = {"StaticFindObject", "StaticConstructObject", "FindFirstOf", "FindAllOf", "RegisterHook",
         "RegisterKeyBind", "Key", "ModifierKey", "ExecuteInGameThread", "ExecuteInGameThreadWithDelay",
         "LoopInGameThreadWithDelay", "RegisterInitGameStatePostHook", "FName", "FText", "UE4SS",
         "UnrealVersion", "EngineTickAvailable", "ProcessEventAvailable", "NotifyOnNewObject", "LoopAsync",
         "ExecuteWithDelay", "RegisterBeginPlayPreHook", "RegisterBeginPlayPostHook", "ForEachUObject"}
ALLOWED = LUA | UE4SS

bad = []
for path in sorted(glob.glob("ue4ss_mod/FFResonanceAP/Scripts/**/*.lua", recursive=True)):
    out = subprocess.run(["luac", "-p", "-l", "-l", path], capture_output=True, text=True, check=True).stdout
    for m in re.finditer(r'[GS]ETTABUP\s.*_ENV "([A-Za-z_][A-Za-z0-9_]*)"', out):
        if m.group(1) not in ALLOWED:
            bad.append(f"{path}: global '{m.group(1)}'")
for b in sorted(set(bad)):
    print(b)
print(f"{len(set(bad))} unexpected global(s)")
sys.exit(1 if bad else 0)
