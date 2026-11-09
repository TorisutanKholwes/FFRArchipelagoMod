--[[
  Save / load detection by polling the live save object (UCPP_MuchaGameSaveData).

  Loads fire no hookable UFunction, so the mod polls once per second (TD-015, verified 2026-11-08):
    * the save object is REPLACED (new address)  -> a save was loaded (in-game load menu);
    * Player.SavedDateTime.Ticks changes on the same object -> a save was written: manual save
      (ApplySaveGameData hook also fires) or autosave (no hook; e.g. on entering the world map).
  Player.PlayTime is only updated when saving, so it is not used.
  ap/runtime.lua turns these into SAVE / LOAD decisions.

  savewatch.on_change(fn) registers fn(old_ticks, new_ticks, reason) callbacks.
  savewatch.on_initial(fn) registers fn(ticks) called once with the first observed value.
]]

local log = require("util.log")

local savewatch = { last = nil, callbacks = {}, initial_callbacks = {}, handle = nil }

--- Current snapshot { ticks, addr, playtime } or nil when no save object exists.
function savewatch.snapshot()
    local save = FindFirstOf("CPP_MuchaGameSaveData")
    if not save or not save:IsValid() then return nil end
    local ok, snap = pcall(function()
        return {
            ticks = save.Player.SavedDateTime.Ticks,
            addr = save:GetAddress(),
            playtime = save.Player.PlayTime,
            name = save:GetFName():ToString(),
        }
    end)
    if ok then return snap end
    return nil
end

function savewatch.describe()
    local s = savewatch.snapshot()
    if not s then return "no save object" end
    return string.format("save object %s @%X ticks=%s playtime=%.1f", s.name, s.addr, tostring(s.ticks), s.playtime)
end

function savewatch.on_initial(fn)
    savewatch.initial_callbacks[#savewatch.initial_callbacks + 1] = fn
end

function savewatch.on_change(fn)
    savewatch.callbacks[#savewatch.callbacks + 1] = fn
end

local function fire(old, new, reason)
    log.info("SAVEWATCH event (%s): ticks %s -> %s", reason, tostring(old.ticks), tostring(new.ticks))
    for _, fn in ipairs(savewatch.callbacks) do
        local cok, err = pcall(fn, old.ticks, new.ticks, reason)
        if not cok then log.error("savewatch callback error: %s", tostring(err)) end
    end
end

local function poll()
    local snap = savewatch.snapshot()
    if not snap then return end
    local last = savewatch.last
    savewatch.last = snap
    if last == nil then
        log.info("SAVEWATCH initial: %s", savewatch.describe())
        for _, fn in ipairs(savewatch.initial_callbacks) do
            local cok, err = pcall(fn, snap.ticks)
            if not cok then log.error("savewatch initial callback error: %s", tostring(err)) end
        end
        return
    end
    if snap.addr ~= last.addr then
        log.info("SAVEWATCH save object replaced: %X -> %X (%s -> %s)", last.addr, snap.addr, last.name, snap.name)
        fire(last, snap, "object replaced")
    elseif snap.ticks ~= last.ticks then
        fire(last, snap, "timestamp")
    end
end

function savewatch.start(interval_ms)
    savewatch.handle = LoopInGameThreadWithDelay(interval_ms or 1000, poll)
    log.info("Save watcher started (%d ms)", interval_ms or 1000)
end

return savewatch
