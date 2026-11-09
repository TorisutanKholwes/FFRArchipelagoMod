--[[
  FFResonanceAP — Archipelago integration mod for FINAL FANTASY RESONANCE (UE4SS Lua mod).

  Release 0.9.0: chests (all 25 Oblivion Palace safes), world-map pickups, Tablet Shard counts, Visions,
  requests, chapters, Espers, Colosseum, Chamber of Arms checks; DeathLink.
  Gating research tools (TD-021..TD-024) stay available as keys; per-map scans are opt-in
  (config/research.txt containing "on").
  Milestone M5: Archipelago runtime (ap/runtime.lua) talking to the ffr_bridge process through
  files in ipc/. Randomized chests are emptied and reported; received items are applied in order;
  per-save bookkeeping keeps delivery exactly-once across save/load.

  Research keybinds (the game window must be focused):
    Ctrl+F6  class discovery      -> dumps/classes.json
    Ctrl+F7  DataTable dump       -> dumps/datatables_index.json, dumps/datatables/*.json
    Ctrl+F8  instance snapshot    -> dumps/snapshots/snapshot_<time>.json (classes in config/watch_classes.txt)
    Ctrl+F9  state probe          -> log money/chapter/map + dumps/savedata_<time>.json
    Ctrl+F10 TEST GRANT           -> adds 1 Potion (modifies game state; test only)
    Ctrl+F3  NOTIFY TEST          -> game's item-obtained dialog with a custom line (display only)
    Ctrl+F2  ISLAND LOCK          -> toggle: all island release conditions impossible / restored
    Ctrl+F4  NOENTRY LOCK         -> toggle: every NoEntry blocker in the map forced to "blocked"
    Ctrl+F1  DEPARTURES OFF       -> toggle: ship-travel trigger conditions set to "never" (memory only)
  Probe hooks log calls to chest/inventory/flag/save UFunctions as "HOOK ..." lines.
]]

local MOD_NAME = "FFResonanceAP"
local MOD_VERSION = "0.13.0"

-- Resolve this mod's folder from the script path and make our modules require()-able.
local function resolve_mod_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", ""):gsub("\\", "/")
    local scripts_dir = src:match("^(.*)/[^/]+$")
    if scripts_dir then
        return scripts_dir:match("^(.*)/[^/]+$") or scripts_dir, scripts_dir
    end
    -- Fallback: UE4SS runs with the working directory at Binaries/Win64.
    return "ue4ss/Mods/" .. MOD_NAME, "ue4ss/Mods/" .. MOD_NAME .. "/Scripts"
end

local MOD_DIR, SCRIPTS_DIR = resolve_mod_dir()
package.path = SCRIPTS_DIR .. "/?.lua;" .. SCRIPTS_DIR .. "/?/init.lua;" .. package.path

local fs = require("util.fs")
local log = require("util.log")
local dump = require("game.dump")
local probe = require("game.probe")
local savewatch = require("game.savewatch")
local runtime = require("ap.runtime")
local gatingprobe = require("game.gatingprobe")
local uidump = require("game.uidump")
local apmenu = require("ui.apmenu")
local overlay = require("ui.overlay")
local zoneprobe = require("game.zoneprobe")
local zonegate = require("game.zonegate")
local shopprobe = require("game.shopprobe")
local shopgate = require("game.shopgate")

log.init(fs.join(MOD_DIR, "logs", "ffr_ap.log"), 2)
dump.init(MOD_DIR)
probe.init(MOD_DIR)
gatingprobe.init(MOD_DIR)
uidump.init(MOD_DIR)
zoneprobe.init(MOD_DIR)
shopprobe.init(MOD_DIR)

local function log_environment()
    log.info("%s v%s starting", MOD_NAME, MOD_VERSION)
    log.info("Mod directory: %s", MOD_DIR)
    log.info("Data version: %s", require("generated.mappings").data_version)
    if UE4SS and UE4SS.GetVersion then
        local ok, major, minor, hotfix = pcall(UE4SS.GetVersion)
        if ok then log.info("UE4SS version: %s.%s.%s", tostring(major), tostring(minor), tostring(hotfix)) end
    end
    if UnrealVersion then
        local ok, major, minor = pcall(function() return UnrealVersion.GetMajor(), UnrealVersion.GetMinor() end)
        if ok then log.info("Unreal Engine version: %s.%s", tostring(major), tostring(minor)) end
    end
    log.info("Game-thread execution: EngineTick=%s ProcessEvent=%s",
        tostring(EngineTickAvailable), tostring(ProcessEventAvailable))
    for _, sub in ipairs({ "dumps", "ipc", "state" }) do
        if not fs.exists(fs.join(MOD_DIR, sub, ".keep")) then
            log.warn("%s/ folder marker missing; re-run tools/install_proton.sh", sub)
        end
    end
end

--- Run a research task on the game thread, logging (not propagating) any error.
local function run_task(name, fn)
    log.info("Task '%s' requested", name)
    ExecuteInGameThread(function()
        local ok, err = pcall(fn)
        if ok then
            log.info("Task '%s' finished", name)
        else
            log.error("Task '%s' failed: %s", name, tostring(err))
        end
    end)
end

log_environment()

RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, function() run_task("discover_classes", dump.discover_classes) end)
RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function() run_task("datatables", dump.datatables) end)
RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function() run_task("snapshot", dump.snapshot) end)
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function()
    run_task("state", function() probe.state(); gatingprobe.report(); gatingprobe.report_saved_gimmick_states() end)
end)
RegisterKeyBind(Key.F2, { ModifierKey.CONTROL }, function() run_task("island_lock", gatingprobe.toggle_island_lock) end)
RegisterKeyBind(Key.F4, { ModifierKey.CONTROL }, function() run_task("noentry_lock", gatingprobe.toggle_noentry) end)
RegisterKeyBind(Key.F1, { ModifierKey.CONTROL }, function() run_task("departures", gatingprobe.toggle_departures) end)
RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, function() run_task("test_grant", probe.test_grant) end)
RegisterKeyBind(Key.F3, { ModifierKey.CONTROL }, function() run_task("notify_test", probe.notify_test) end)

probe.register_hooks()
-- Research hooks disabled after the 2026-11-08 crash (TD-023); enable only for targeted research:
-- gatingprobe.start_tracer(); gatingprobe.register_beginplay_hook(); gatingprobe.register_overlap_hook()

runtime.init(MOD_DIR, MOD_VERSION, savewatch)
runtime.register_hooks()
uidump.register_hooks()
apmenu.init(MOD_DIR, runtime)
apmenu.register_hooks()
zonegate.init(runtime)
shopgate.init(runtime)
zonegate.register_hooks()

local restored_island_backup = false
local research_cfg = fs.read_all(fs.join(MOD_DIR, "config", "research.txt"))
local research_enabled = research_cfg ~= nil and research_cfg:match("^%s*on") ~= nil
uidump.enabled = research_enabled  -- title-screen UI dumps freeze the game for 1-3 s: research only
log.info("Research scans: %s", research_enabled and "on" or "off")
overlay.init(MOD_DIR, runtime)

-- World/game-state transitions (title screen -> field, map changes).
local ok_hook, hook_err = pcall(RegisterInitGameStatePostHook, function(game_state)
    local ok, gs = pcall(function() return game_state:get() end)
    if not ok or not gs then return end
    local name = select(2, pcall(function() return gs:GetFullName() end))
    local class = select(2, pcall(function() return gs:GetClass():GetFName():ToString() end))
    log.info("InitGameState: %s | %s", tostring(name), savewatch.describe())
    runtime.on_game_state(class, name)
    uidump.on_game_state(name)
    apmenu.on_game_state(name)
    overlay.on_game_state(name)
    zoneprobe.on_game_state(class, name)
    zonegate.on_game_state(class, name)
    shopprobe.on_game_state(class)
    if class == "CPP_MuchaGameModeField" and research_enabled then
        -- Research (opt-in, config/research.txt = "on"): dump the event triggers of the new map.
        local label = tostring(name):match("/Game/Map/[^%.]+/([^/%.]+)%.") or tostring(name)
        ExecuteInGameThreadWithDelay(3000, function()
            local sok, serr = pcall(gatingprobe.scan_events, label)
            if not sok then log.error("Event scan failed: %s", tostring(serr)) end
            local map_id = nil
            pcall(function() map_id = StaticFindObject("/Script/mucha.Default__CPP_BFL_SaveDataMap"):GetMapId() end)
            local iok, ierr = pcall(gatingprobe.scan_item_objects, label, map_id)
            if not iok then log.error("Item scan failed: %s", tostring(ierr)) end
            local lok, lerr = pcall(gatingprobe.on_map_loaded)
            if not lok then log.error("NoEntry re-apply failed: %s", tostring(lerr)) end
        end)
    end
    if not restored_island_backup and class == "CPP_MuchaGameModeField" then
        -- A lock left by a crash or mod reload is undone as soon as the game data is loaded.
        restored_island_backup = true
        local rok, rerr = pcall(gatingprobe.restore_all)
        if not rok then log.error("Island condition restore failed: %s", tostring(rerr)) end
    end
end)
if not ok_hook then log.warn("RegisterInitGameStatePostHook unavailable: %s", tostring(hook_err)) end

savewatch.start(1000)
runtime.start(1000)
apmenu.start()
overlay.start()
zoneprobe.register_hooks()
zoneprobe.start()
zonegate.start()
shopgate.start()

log.info("Ready. Archipelago runtime active; research keys Ctrl+F6..F10")
