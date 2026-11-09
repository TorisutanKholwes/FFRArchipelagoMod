--[[
  Story/island gating research (workstream 1). Research only: nothing here runs automatically.

    gatingprobe.toggle_island_lock()   Ctrl+F2: rewrite every row of DT_MapReleaseConditionData to an
                                       impossible condition ("{progress:0}>=99999"), or restore the
                                       original conditions. Originals are kept in memory and logged;
                                       a mod reload restores them too (the game reloads nothing, so
                                       restore_all() is also called at startup if a backup file exists).
    gatingprobe.report()               logs released islands (CPP_BFL_Map:GetMeetReleaseConditionIslandList)
                                       and current island (CPP_MapManager:GetCurrentIslandType)
    gatingprobe.start_tracer()         hooks every UFunction of the classes in config/trace_classes.txt
                                       and logs calls (rate-limited), to find what consumes island release

  Facts used (CXX header / DataTable dumps, TD-021):
    FMAP_RELEASE_CONDITION_DATA { FString Condition; eMapIslandType IslandType; }
    /Game/Datatable/Map/DT_MapReleaseConditionData.DT_MapReleaseConditionData
]]

local json = require("lib.json")
local fs = require("util.fs")
local log = require("util.log")

local gp = { mod_dir = nil, locked = false, originals = nil, trace_counts = {} }

local RELEASE_TABLE = "/Game/Datatable/Map/DT_MapReleaseConditionData.DT_MapReleaseConditionData"
local LOCKED_CONDITION = "{progress:0}>=99999"
local ISLAND_NAMES = { "Grandshelt", "Lanzelt", "Kolobos", "Dirnado", "Olderion", "Zoldaad", "Mysidia",
    "Gronoa", "Pharm", "LandOfTheCrystals", "Ardra", "AirShip", "AirShip_Ride", "Common" }

function gp.init(mod_dir)
    gp.mod_dir = mod_dir
end

local function backup_path()
    return fs.join(gp.mod_dir, "state", "island_conditions_backup.json")
end

local function release_table()
    local dt = StaticFindObject(RELEASE_TABLE)
    if not dt or not dt:IsValid() then error("DataTable not found: " .. RELEASE_TABLE) end
    return dt
end

--- Replace a DataTable row's Condition (UDataTable:AddRow replaces an existing row; documented)
--- and read it back. Returns the value actually stored; raises if the write did not take.
local function set_condition(dt, name, island, value)
    dt:AddRow(name, { Condition = value, IslandType = island })
    local now = dt:FindRow(name).Condition:ToString()
    if now ~= value then
        error(string.format("row %s write did not take: wanted '%s', table has '%s'", name, value, now))
    end
    return now
end

local function island_name(t)
    return ISLAND_NAMES[t] or tostring(t)
end

function gp.toggle_island_lock()
    local dt = release_table()
    if not gp.locked and fs.exists(backup_path()) then
        -- Locked by a previous mod instance (hot reload): restore, never re-save locked values.
        log.info("Island lock backup found from a previous mod instance: restoring")
        gp.restore_all()
        return
    end
    if not gp.locked then
        local originals = {}
        dt:ForEachRow(function(name, row)
            originals[name] = { condition = row.Condition:ToString(), island = row.IslandType }
        end)
        -- Persist before modifying so a crash or reload can restore.
        fs.write_atomic(backup_path(), json.encode(originals))
        gp.originals = originals
        for name, o in pairs(originals) do
            local now = set_condition(dt, name, o.island, LOCKED_CONDITION)
            log.info("ISLAND LOCK %s (%s): '%s' -> '%s' (verified)", name, island_name(o.island), o.condition, now)
        end
        gp.locked = true
    else
        gp.restore_all()
    end
end

function gp.restore_all()
    local originals = gp.originals
    if not originals then
        local raw = fs.read_all(backup_path())
        if not raw then return end
        originals = json.decode(raw)
    end
    local dt = release_table()
    for name, o in pairs(originals) do
        if dt:FindRow(name) then
            local now = set_condition(dt, name, o.island, o.condition)
            log.info("ISLAND RESTORE %s (%s): '%s' (verified)", name, island_name(o.island), now)
        end
    end
    os.remove(backup_path())
    gp.originals = nil
    gp.locked = false
end

function gp.report()
    local bfl = StaticFindObject("/Script/mucha.Default__CPP_BFL_Map")
    local ok, list = pcall(function() return bfl:GetMeetReleaseConditionIslandList() end)
    local islands = {}
    if ok and list then
        pcall(function()
            list:ForEach(function(_, e) islands[#islands + 1] = island_name(e:get()) end)
        end)
        log.info("RELEASED ISLANDS (%d): %s", #islands, table.concat(islands, ", "))
    else
        log.warn("GetMeetReleaseConditionIslandList failed: %s", tostring(list))
    end
    local mm = FindFirstOf("CPP_MapManager")
    if mm and mm:IsValid() then
        local cok, cur = pcall(function() return mm:GetCurrentIslandType() end)
        log.info("CURRENT ISLAND: %s", cok and island_name(cur) or ("? " .. tostring(cur)))
    end
    log.info("Island lock active: %s", tostring(gp.locked))
    log.info("PLAYER LOCATION: %s | NoEntry lock active: %s", gp.player_location(), tostring(gp.noentry_locked))
end

-- Function tracer -----------------------------------------------------------

-- Whole-class tracing skips per-frame / camera functions; list "Class:Function" lines to trace
-- a specific function regardless (e.g. a Get... function).
local SKIP = { "Tick", "Update", "Camera", "Cursor", "Delegate" }

local function skipped(fname)
    for _, p in ipairs(SKIP) do
        if fname:find(p) then return true end
    end
    return false
end

function gp.start_tracer()
    local raw = fs.read_all(fs.join(gp.mod_dir, "config", "trace_classes.txt"))
    if not raw then
        log.info("No config/trace_classes.txt; tracer off")
        return
    end
    local hooked = 0
    for line in raw:gmatch("[^\r\n]+") do
        local path = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
        if path:find(":", 1, true) then
            local ok, err = pcall(RegisterHook, path, function()
                local n = (gp.trace_counts[path] or 0) + 1
                gp.trace_counts[path] = n
                if n <= 3 or n % 50 == 0 then log.info("TRACE %s (call %d)", path, n) end
            end)
            if ok then hooked = hooked + 1 else log.warn("Tracer: cannot hook %s (%s)", path, tostring(err)) end
        elseif path ~= "" then
            local cls = StaticFindObject(path)
            if cls and cls:IsValid() then
                local fns = {}
                pcall(function()
                    cls:ForEachFunction(function(fn) fns[#fns + 1] = fn:GetFName():ToString() end)
                end)
                for _, fname in ipairs(fns) do
                    if not skipped(fname) then
                        local full = path .. ":" .. fname
                        local ok = pcall(RegisterHook, full, function()
                            local n = (gp.trace_counts[full] or 0) + 1
                            gp.trace_counts[full] = n
                            if n <= 3 or n % 50 == 0 then
                                log.info("TRACE %s (call %d)", full, n)
                            end
                        end)
                        if ok then hooked = hooked + 1 end
                    end
                end
            else
                log.warn("Tracer: class not found: %s", path)
            end
        end
    end
    log.info("Tracer: %d functions hooked", hooked)
end

-- Event trigger scanner ------------------------------------------------------
-- Writes dumps/events/<map>.json: every {Condition, EventId} found on NPCs, gimmicks and
-- transition triggers of the loaded map (actor properties from the CXX header dump).

local EVENT_SOURCES = {
    { class = "CPP_MapUnit_NPC", fields = { "m_EventList" } },
    { class = "CPP_MapGimmick", fields = { "m_EventList" } },
    { class = "CPP_MapTransitionTrigger", fields = { "m_EventList", "m_EventList2", "m_AfterTransitionEventList" } },
}

local function read_event_list(actor, field)
    local out = {}
    local ok = pcall(function()
        actor[field]:ForEach(function(_, e)
            local ev = e:get()
            out[#out + 1] = { condition = ev.Condition:ToString(), event = ev.EventId:ToString() }
        end)
    end)
    return ok and out or nil
end

function gp.scan_events(map_label)
    local result = { map = map_label, actors = {} }
    local total = 0
    for _, src in ipairs(EVENT_SOURCES) do
        for _, actor in ipairs(FindAllOf(src.class) or {}) do
            local entry = nil
            for _, field in ipairs(src.fields) do
                local list = read_event_list(actor, field)
                if list and #list > 0 then
                    entry = entry or { actor = actor:GetFName():ToString(), class = actor:GetClass():GetFName():ToString(), lists = {} }
                    entry.lists[field] = list
                    total = total + #list
                end
            end
            local flag_cond = nil
            pcall(function() flag_cond = actor.m_FlagCondition:ToString() end)
            if flag_cond and flag_cond ~= "" then
                entry = entry or { actor = actor:GetFName():ToString(), class = actor:GetClass():GetFName():ToString(), lists = {} }
                entry.flag_condition = flag_cond
            end
            if entry then
                pcall(function()
                    local loc = actor:K2_GetActorLocation()
                    entry.location = { x = math.floor(loc.X), y = math.floor(loc.Y), z = math.floor(loc.Z) }
                end)
                result.actors[#result.actors + 1] = entry
            end
        end
    end
    local file = fs.join(gp.mod_dir, "dumps", "events", (map_label:gsub("[^%w_%-]", "_")) .. ".json")
    local ok, err = fs.write_atomic(file, json.encode(result, true))
    log.info("EVENT SCAN %s: %d actors, %d triggers -> %s", map_label, #result.actors, total,
        ok and file or ("write failed: " .. tostring(err)))
end

-- Item-object scanner (research for non-table chests and world-map pickups) ----------------
-- Writes dumps/items/<map>.json: every ACPP_MapGimmick_ItemObjectBase actor (treasure boxes and
-- field items) with its identity (m_UniqueId), contents, table ID (treasure boxes) and flags.

--- Convert any reflected value to something JSON can hold (numbers, booleans, strings).
function gp.plain(v)
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" or v == nil then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    ok, s = pcall(function() return v:GetFullName() end)
    if ok and type(s) == "string" then return s end
    return tostring(v)
end

function gp.scan_item_objects(map_label, map_id)
    local plain = gp.plain
    map_id = plain(map_id)
    local out = { map = map_label, map_id = map_id, objects = {} }
    for _, a in ipairs(FindAllOf("CPP_MapGimmick_ItemObjectBase") or {}) do
        local o = {}
        pcall(function() o.actor = a:GetFName():ToString() end)
        pcall(function() o.class = a:GetClass():GetFName():ToString() end)
        pcall(function() o.unique_id = plain(a.m_UniqueId) end)
        pcall(function() o.item_id = plain(a.m_ItemId) end)
        pcall(function() o.item_num = plain(a.m_ItemNum) end)
        pcall(function() o.money = plain(a.m_Money) end)
        pcall(function() o.is_trap = plain(a.m_IsTrap) end)
        pcall(function() o.battle_group = plain(a.m_BattleGroupId) end)
        pcall(function() o.flag_condition = a.m_FlagCondition:ToString() end)
        pcall(function()
            local d = a.m_TreasureBoxData
            o.table_id = plain(d.ID); o.table_map_id = plain(d.mapId)
            o.table_item = plain(d.ItemId); o.table_num = plain(d.ItemNum); o.table_money = plain(d.Money)
        end)
        pcall(function()
            local flags = {}
            a.m_OnFlagList:ForEach(function(_, e) flags[#flags + 1] = plain(e:get()) end)
            o.on_flags = flags
        end)
        pcall(function() o.island = plain(a.m_IslandType) end)
        pcall(function()
            local l = a:K2_GetActorLocation()
            o.location = { x = math.floor(l.X), y = math.floor(l.Y), z = math.floor(l.Z) }
        end)
        for k, v in pairs(o) do
            if type(v) ~= "table" then o[k] = plain(v) end
        end
        out.objects[#out.objects + 1] = o
    end
    -- Merge with earlier scans of the same map (streaming can load only part of a map, e.g. the
    -- world map): objects are keyed by class + unique id, newer values win, nothing is dropped.
    local file = fs.join(gp.mod_dir, "dumps", "items", (map_label:gsub("[^%w_%-]", "_")) .. ".json")
    local merged, order = {}, {}
    local raw = fs.read_all(file)
    if raw then
        local pok, prev = pcall(json.decode, raw)
        if pok and type(prev) == "table" and type(prev.objects) == "table" then
            for _, o in ipairs(prev.objects) do
                local k = tostring(o.class) .. "#" .. tostring(o.unique_id)
                if not merged[k] then order[#order + 1] = k end
                merged[k] = o
            end
        end
    end
    local seen_now = #out.objects
    for _, o in ipairs(out.objects) do
        local k = tostring(o.class) .. "#" .. tostring(o.unique_id)
        if not merged[k] then order[#order + 1] = k end
        merged[k] = o
    end
    out.objects = {}
    for _, k in ipairs(order) do out.objects[#out.objects + 1] = merged[k] end
    local ok, err = fs.write_atomic(file, json.encode(out, true))
    log.info("ITEM SCAN %s (map %s): %d seen now, %d total after merge -> %s", map_label, tostring(map_id), seen_now,
        #out.objects, ok and file or ("write failed: " .. tostring(err)))
end

-- NoEntry gate experiment ----------------------------------------------------
-- Ctrl+F4 toggles: every ACPP_MapGimmick_NoEntry in the current map gets all its m_EventList
-- conditions forced to ALWAYS_TRUE (blocked), or restored. The lock is re-applied on every map
-- load while active (to learn whether the game re-reads conditions after a reload).

local ALWAYS_TRUE = "{progress:0}>=0"
gp.noentry_locked = false
gp.noentry_originals = {}   -- [actor full name] = { {condition, event}, ... }

local function read_list(actor)
    local out = {}
    actor.m_EventList:ForEach(function(_, e)
        local ev = e:get()
        out[#out + 1] = { condition = ev.Condition:ToString(), event = ev.EventId:ToString() }
    end)
    return out
end

--- Try to set every m_EventList condition of `actor` to `cond_for(i, entry)`; returns method name.
local function write_conditions(actor, entries, cond_for)
    local function verify()
        local now = read_list(actor)
        for i, e in ipairs(entries) do
            if not now[i] or now[i].condition ~= cond_for(i, e) then return false end
        end
        return true
    end
    -- 1. in-place FString edit
    pcall(function()
        local i = 0
        actor.m_EventList:ForEach(function(_, el)
            i = i + 1
            local c = el:get().Condition
            c:Clear(); c:Append(cond_for(i, entries[i]))
        end)
    end)
    if verify() then return "in-place" end
    -- 2. plain assignment of the struct field
    pcall(function()
        local i = 0
        actor.m_EventList:ForEach(function(_, el)
            i = i + 1
            local ev = el:get()
            ev.Condition = cond_for(i, entries[i])
        end)
    end)
    if verify() then return "assignment" end
    -- 3. the game's own setter (ACPP_MapGimmick:SetEventList), rebuilding the list
    pcall(function()
        local list = {}
        for i, e in ipairs(entries) do
            list[i] = { Condition = cond_for(i, e), EventId = FName(e.event) }
        end
        actor:SetEventList(list)
    end)
    if verify() then return "SetEventList" end
    return nil
end

local function lock_flag_condition(actor, when)
    local ok, original = pcall(function() return actor.m_FlagCondition:ToString() end)
    if not ok then return end
    local key = "flag:" .. actor:GetFullName()
    if gp.noentry_originals[key] == nil then gp.noentry_originals[key] = original end
    pcall(function() actor.m_FlagCondition = ALWAYS_TRUE end)
    local now = actor.m_FlagCondition:ToString()
    log.info("NOENTRY FLAGCOND [%s] %s '%s' -> '%s' %s", when, actor:GetFName():ToString(),
        tostring(gp.noentry_originals[key]), now, now == ALWAYS_TRUE and "(verified)" or "(WRITE FAILED)")
end

--- Force the gimmick active through the game's own setters (ACPP_MapGimmick, CXX header dump).
local function force_active(actor, when)
    local results = {}
    for _, attempt in ipairs({
        { "m_GimmickCondition=Active", function() actor.m_GimmickCondition = 0 end },
        { "SetGimmickActiveState(Active)", function() actor:SetGimmickActiveState(0) end },
        { "SetGimmickCondition(Active)", function() actor:SetGimmickCondition(0, false) end },
    }) do
        local ok, err = pcall(attempt[2])
        results[#results + 1] = attempt[1] .. (ok and " ok" or (" FAILED " .. tostring(err)))
    end
    local state = "?"
    pcall(function() state = tostring(actor.m_GimmickCondition) end)
    log.info("NOENTRY FORCE ACTIVE [%s] %s: %s; m_GimmickCondition now %s", when,
        actor:GetFName():ToString(), table.concat(results, "; "), state)
end

local function lock_actor(actor, when)
    lock_flag_condition(actor, when)
    if when == "after load" then force_active(actor, when) end
    local key = actor:GetFullName()
    local entries = gp.noentry_originals[key] or read_list(actor)
    gp.noentry_originals[key] = entries
    local method = write_conditions(actor, entries, function() return ALWAYS_TRUE end)
    local loc = "?"
    pcall(function() local l = actor:K2_GetActorLocation(); loc = string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) end)
    if method then
        for _, e in ipairs(entries) do
            log.info("NOENTRY LOCK [%s] %s @%s event=%s '%s' -> '%s' (via %s)", when, actor:GetFName():ToString(), loc,
                e.event, e.condition, ALWAYS_TRUE, method)
        end
    else
        log.error("NOENTRY LOCK FAILED [%s] %s @%s: no write method verified", when, actor:GetFName():ToString(), loc)
    end
    return method ~= nil
end

function gp.apply_noentry_lock()
    local n, failed = 0, 0
    for _, actor in ipairs(FindAllOf("CPP_MapGimmick_NoEntry") or {}) do
        if lock_actor(actor, "after load") then n = n + 1 else failed = failed + 1 end
    end
    log.info("NoEntry lock applied: %d blocker(s) locked, %d failed", n, failed)
end

--- BeginPlay pre-hook: lock NoEntry blockers before they initialize (the game may read the
--- conditions only once, at BeginPlay).
function gp.register_beginplay_hook()
    local ok, err = pcall(RegisterBeginPlayPreHook, function(actor_param)
        if not gp.noentry_locked then return end
        local ok2, err2 = pcall(function()
            local actor = actor_param:get()
            if actor and actor:IsValid() and actor:IsA("/Script/mucha.CPP_MapGimmick_NoEntry") then
                lock_actor(actor, "before BeginPlay")
            end
        end)
        if not ok2 then log.error("NoEntry BeginPlay hook error: %s", tostring(err2)) end
    end)
    log.info("BeginPlay pre-hook %s", ok and "registered" or ("NOT registered: " .. tostring(err)))
end

function gp.restore_noentry()
    for _, actor in ipairs(FindAllOf("CPP_MapGimmick_NoEntry") or {}) do
        local fc = gp.noentry_originals["flag:" .. actor:GetFullName()]
        if fc ~= nil then pcall(function() actor.m_FlagCondition = fc end) end
        local entries = gp.noentry_originals[actor:GetFullName()]
        if entries then
            local method = write_conditions(actor, entries, function(_, e) return e.condition end)
            log.info("NOENTRY RESTORE %s (%s)", actor:GetFName():ToString(), method or "FAILED")
        end
    end
    gp.noentry_originals = {}
end

function gp.toggle_noentry()
    gp.noentry_locked = not gp.noentry_locked
    if gp.noentry_locked then gp.apply_noentry_lock() else gp.restore_noentry() end
end

--- Called on every field map load: actors are new, so re-apply while the experiment is active.
function gp.on_map_loaded()
    if gp.departure_off then gp.departure_originals = {}; gp.apply_departures() end
    if gp.noentry_locked then
        gp.noentry_originals = {}
        gp.apply_noentry_lock()
    end
end

--- Diagnostic: log every overlap with a trigger gimmick (NoEntry, event triggers, ...).
function gp.register_overlap_hook()
    local ok, err = pcall(RegisterHook, "/Script/mucha.CPP_MapGimmick_Trigger:BeginOverlap", function(ctx, _, other)
        pcall(function()
            local g = ctx:get()
            local o = other:get()
            local who = (o and o:IsValid()) and o:GetClass():GetFName():ToString() or "?"
            if not who:find("Playable") then return end
            local conds = {}
            pcall(function()
                g.m_EventList:ForEach(function(_, e)
                    local ev = e:get()
                    conds[#conds + 1] = ev.EventId:ToString() .. "[" .. ev.Condition:ToString() .. "]"
                end)
            end)
            local state, flag = "?", "?"
            pcall(function() state = tostring(g.m_GimmickCondition) end)
            pcall(function() flag = g.m_FlagCondition:ToString() end)
            log.info("OVERLAP %s (%s) state=%s flag='%s' events=%s", g:GetFName():ToString(),
                g:GetClass():GetFName():ToString(), state, flag, table.concat(conds, " "))
        end)
    end)
    log.info("Overlap hook %s", ok and "registered" or ("NOT registered: " .. tostring(err)))
end

-- Departure-trigger experiment ---------------------------------------------------
-- Ctrl+F1 toggles: every interact trigger whose events contain "ShipMovement" is set Deactive
-- (state 1) through the game's setters, re-applied after each map load while active.

gp.departure_off = false
local DEPARTURE_PATTERN = "ShipMovement"

local function departure_triggers()
    local out = {}
    for _, actor in ipairs(FindAllOf("CPP_MapGimmick_InteractEventTrigger") or {}) do
        local events = {}
        pcall(function()
            actor.m_EventList:ForEach(function(_, e) events[#events + 1] = e:get().EventId:ToString() end)
        end)
        local joined = table.concat(events, ",")
        if joined:find(DEPARTURE_PATTERN, 1, true) then out[#out + 1] = { actor = actor, events = joined } end
    end
    return out
end

local function set_state(actor, state)
    local results = {}
    for _, attempt in ipairs({
        { "m_GimmickCondition", function() actor.m_GimmickCondition = state end },
        { "SetGimmickActiveState", function() actor:SetGimmickActiveState(state) end },
        { "SetGimmickCondition", function() actor:SetGimmickCondition(state, false) end },
    }) do
        local ok = pcall(attempt[2])
        results[#results + 1] = attempt[1] .. (ok and " ok" or " FAILED")
    end
    local now = "?"
    pcall(function() now = tostring(actor.m_GimmickCondition) end)
    return table.concat(results, "; ") .. "; now " .. now
end

--- Disable departures WITHOUT touching gimmick state (state changes are saved, TD-023): rewrite the
--- trigger's event conditions in memory only. Originals are kept per actor and restored on toggle;
--- a map reload recreates the actors with their original conditions anyway.
local NEVER = "{progress:0}>=99999"
gp.departure_originals = {}

function gp.apply_departures()
    local list = departure_triggers()
    for _, d in ipairs(list) do
        local actor = d.actor
        local key = actor:GetFullName()
        local entries = gp.departure_originals[key] or read_list(actor)
        gp.departure_originals[key] = entries
        local method
        if gp.departure_off then
            method = write_conditions(actor, entries, function() return NEVER end)
        else
            method = write_conditions(actor, entries, function(_, e) return e.condition end)
        end
        local state = "?"
        pcall(function() state = tostring(actor.m_GimmickCondition) end)
        log.info("DEPARTURE %s %s [%s] via %s; gimmick state %s (not changed)", gp.departure_off and "OFF" or "ON",
            actor:GetFName():ToString(), d.events, tostring(method or "FAILED"), state)
    end
    if not gp.departure_off then gp.departure_originals = {} end
    log.info("Departure triggers %s: %d found", gp.departure_off and "disabled" or "enabled", #list)
end

function gp.toggle_departures()
    gp.departure_off = not gp.departure_off
    gp.apply_departures()
end

--- Log every gimmick state stored in the live save that is not Active (0), per map. Used to check
--- that research experiments (SetGimmickActiveState) did not leave persistent states behind.
function gp.report_saved_gimmick_states()
    local save = FindFirstOf("CPP_MuchaGameSaveData")
    if not save or not save:IsValid() then log.warn("No save object"); return end
    local total, non_default = 0, 0
    save.Map.mapGimmick:ForEach(function(key, value)
        local map_id = key:get()
        value:get().gimmickState:ForEach(function(uid, st)
            total = total + 1
            local s = st:get()
            if s.State ~= 0 then
                non_default = non_default + 1
                log.info("SAVED GIMMICK STATE map=%s uniqueId=%s State=%s Value=%s", tostring(map_id), tostring(uid:get()),
                    tostring(s.State), tostring(s.Value))
            end
        end)
    end)
    log.info("Saved gimmick states: %d total, %d not Active", total, non_default)
end

function gp.player_location()
    local unit = FindFirstOf("CPP_MapUnit_Playable")
    if not unit or not unit:IsValid() then return "no player unit" end
    local l = unit:K2_GetActorLocation()
    return string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z)
end

return gp
