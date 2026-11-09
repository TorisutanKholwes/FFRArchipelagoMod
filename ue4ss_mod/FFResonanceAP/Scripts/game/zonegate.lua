--[[
  Zone locks in game (TD-033). Active only while the runtime is bound to a seed (armed by Connect)
  whose slot_data has zone_locks on; otherwise the game stays vanilla.

  Entrances: on the world map, every CPP_MapTransitionTrigger whose destination belongs to a locked zone
  gets its actor collision switched off (SetActorEnableCollision(false)): the player never overlaps it,
  so no Enter prompt, and the game never evaluates anything it could remember. Unlocking switches the
  collision back on. Actors are recreated on every map load, so nothing persists (actor collision isn't
  saved; the save's map data was unchanged with both lock methods, TD-033).
  Not used: rewriting m_Condition. It locks live, but once the game has evaluated the impossible
  condition near the player it keeps the entrance off until the map reloads (2026-11-09 tests).
  Scans: every 0.5 s for the first 10 s after the world map loads (triggers appear ~2 s after load),
  then every 2 s (streamed island sub-levels).
  Fast travel: pre-hook on CPP_VM_WldMap:DecideObject. When the focused destination's map is locked, the
  view model's FastTravelBehavior becomes { bCanTravel = false, LockMap dialog }, so the game refuses with
  its own dialog (verified in game). Its text is the game's "place you haven't visited yet".
  Never used: gimmick state setters (written into saves, TD-023/024), BeginPlay/overlap hooks (crash).
]]

local log = require("util.log")
local mappings = require("generated.mappings")
local zones = require("ap.zones")

local zg = {
    runtime = nil, on_world = false, ticks = 0, world_tick = 0,
    records = {},          -- [actor address] = { actor, use, cond, locked, dests, name }
    active = false, slot_enabled = false, items = nil,
    unlocked = {}, locked_maps = {}, signature = nil,
    readback_warned = false,
}

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end



--- Diagnostic snapshot of what the game may cache on a transition trigger.
local function state_of(actor)
    local box = safe(function() return actor.m_pRootBoxComponent end)
    return {
        init_once = safe(function() return actor.m_InitializeOnce end),
        actor_collision = safe(function() return actor:GetActorEnableCollision() end),
        hidden = safe(function() return actor.bHidden end),
        box_collision = box and safe(function() return box:GetCollisionEnabled() end),
        box_overlap = box and safe(function() return box:GetGenerateOverlapEvents() end),
        use = safe(function() return actor.m_IsUseCondion end),
        cond = safe(function() return actor.m_Condition:ToString() end),
    }
end

local function describe(st)
    return string.format("init=%s actorColl=%s hidden=%s boxColl=%s boxOverlap=%s use=%s cond='%s'",
        tostring(st.init_once), tostring(st.actor_collision), tostring(st.hidden), tostring(st.box_collision),
        tostring(st.box_overlap), tostring(st.use), tostring(st.cond))
end
local LOCKMAP_DIALOG = "UI.Dialog.Box.Map.FastTravel.CanNot.LockMap"

function zg.init(runtime)
    zg.runtime = runtime
end

-- State -----------------------------------------------------------------------

local function zone_of_record(rec)
    for _, m in ipairs(rec.dests) do
        local z = mappings.zone_of_map[m]
        if z then return z end
    end
    return nil
end

local function restore(rec, verbose)
    if not rec.locked then return end
    local actor = rec.actor
    if safe(function() return actor:IsValid() end) then
        local ok, err = pcall(function() actor:SetActorEnableCollision(rec.before.actor_collision ~= false) end)
        if not ok then log.error("ZONES: reopening %s failed: %s", tostring(rec.name), tostring(err)) end
        if verbose then
            log.info("ZONES: unlock %s (zone %s): %s", tostring(rec.name), tostring(zone_of_record(rec)),
                describe(state_of(actor)))
        end
    end
    rec.locked = false
end

local function restore_all(reason)
    local n = 0
    for _, rec in pairs(zg.records) do
        if rec.locked then
            restore(rec)
            n = n + 1
        end
    end
    if n > 0 then log.info("ZONES: %d entrance(s) restored (%s)", n, reason) end
end

--- Recompute whether locks apply and which maps are locked (cheap; every tick).
local function refresh()
    local rt = zg.runtime
    local st = rt.bridge
    if st and type(st.slot_data) == "table" then
        zg.slot_enabled = zones.enabled(st.slot_data)
        zg.items = st.items
    end
    local active = rt.session:is_bound() and zg.slot_enabled
    if active ~= zg.active then
        zg.active = active
        log.info("ZONES: zone locks %s", active and "active" or "inactive")
        if not active then
            restore_all("zone locks inactive")
            zg.signature = nil
        end
    end
    if not active then return end
    local unlocked = zones.unlocked(zg.items or {}, mappings)
    local keys = {}
    for z in pairs(unlocked) do keys[#keys + 1] = z end
    table.sort(keys)
    local sig = table.concat(keys, ",")
    if sig ~= zg.signature then
        local newly = {}
        for _, z in ipairs(keys) do
            if not zg.unlocked[z] then newly[#newly + 1] = mappings.zone_names[z] or tostring(z) end
        end
        zg.signature = sig
        zg.unlocked = unlocked
        zg.locked_maps = zones.locked_maps(unlocked, mappings)
        log.info("ZONES: %s%s", zones.summary(unlocked, mappings),
            #newly > 0 and (" (new: " .. table.concat(newly, ", ") .. ")") or "")
    end
end

-- Entrances -------------------------------------------------------------------

local function destinations(actor)
    local out = {}
    local mid = safe(function() return actor.m_MapId end)
    if type(mid) == "number" and mid > 0 then out[#out + 1] = mid end
    pcall(function()
        actor.mTransitionDataList:ForEach(function(_, e)
            local m = safe(function() return e:get().mapId end)
            if type(m) == "number" and m > 0 then out[#out + 1] = m end
        end)
    end)
    return out
end

local function scan()
    local changed_lock, changed_open = 0, 0
    local seen = {}
    for _, actor in ipairs(safe(function() return FindAllOf("CPP_MapTransitionTrigger") end) or {}) do
        local addr = safe(function() return actor:GetAddress() end)
        if addr and safe(function() return actor:IsValid() end) then
            seen[addr] = true
            local rec = zg.records[addr]
            if not rec then
                rec = {
                    actor = actor, dests = destinations(actor), locked = false,
                    name = safe(function() return actor:GetFName():ToString() end),
                    use = safe(function() return actor.m_IsUseCondion end),
                    cond = safe(function() return actor.m_Condition:ToString() end) or "",
                }
                rec.before = state_of(actor)
                zg.records[addr] = rec
            end
            local want = #rec.dests > 0 and zones.entrance_locked(rec.dests, zg.locked_maps)
            if want and (not rec.locked or safe(function() return actor:GetActorEnableCollision() end) == true) then
                -- Lock, or lock again if something switched the collision back on.
                local again = rec.locked
                local ok, err = pcall(function() actor:SetActorEnableCollision(false) end)
                local back = safe(function() return actor:GetActorEnableCollision() end)
                if ok and back == false then
                    rec.locked = true
                    changed_lock = changed_lock + 1
                    if again then log.warn("ZONES: %s had its collision back on; locked again", tostring(rec.name)) end
                elseif not zg.readback_warned then
                    zg.readback_warned = true
                    log.error("ZONES: could not lock %s (%s, collision now %s)", tostring(rec.name), tostring(err), tostring(back))
                end
            elseif rec.locked and not want then
                restore(rec, true)
                changed_open = changed_open + 1
            end
        end
    end
    for addr in pairs(zg.records) do
        if not seen[addr] then zg.records[addr] = nil end  -- streamed out
    end
    if changed_lock > 0 or changed_open > 0 then
        log.info("ZONES: entrances locked +%d, reopened +%d", changed_lock, changed_open)
    end
end

function zg.tick()
    zg.ticks = zg.ticks + 1
    refresh()
    if not (zg.active and zg.on_world) then return end
    local since = zg.ticks - zg.world_tick
    if since <= 20 or zg.ticks % 4 == 0 then
        local ok, err = pcall(scan)
        if not ok then log.error("ZONES: scan failed: %s", tostring(err)) end
    end
end

function zg.on_game_state(class_name, full_name)
    zg.records = {}  -- actors of the previous map are gone
    zg.on_world = class_name == "CPP_MuchaGameModeField" and tostring(full_name):find("/Map/Wld/", 1, true) ~= nil
    zg.world_tick = zg.ticks
end

-- Fast travel -------------------------------------------------------------------

local function on_decide_object(ctx)
    if not zg.active then return end
    local vm = safe(function() return ctx:get() end)
    local map_id = vm and safe(function() return vm.FocusObjectData.RelatedMapId end)
    if not (map_id and zg.locked_maps[map_id]) then return end
    local ok, err = pcall(function()
        vm.FastTravelBehavior.bCanTravel = false
        vm.FastTravelBehavior.DialogTag.TagName = FName(LOCKMAP_DIALOG)
    end)
    log.info("ZONES: fast travel to map %d refused (%s): zone locked", map_id, ok and "ok" or tostring(err))
end

function zg.register_hooks()
    local ok, err = pcall(RegisterHook, "/Script/mucha.CPP_VM_WldMap:DecideObject", on_decide_object)
    log.info("ZONES: fast-travel hook %s", ok and "registered" or ("NOT registered: " .. tostring(err)))
end

function zg.start()
    LoopInGameThreadWithDelay(500, function()
        local ok, err = pcall(zg.tick)
        if not ok then log.error("ZONES tick error: %s", tostring(err)) end
    end)
end

return zg
