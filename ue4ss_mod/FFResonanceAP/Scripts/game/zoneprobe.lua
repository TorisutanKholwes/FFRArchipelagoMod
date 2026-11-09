--[[
  Zone-lock research (TD-033, Phase A). Active only when config/zone_research.txt contains "on"
  (separate from config/research.txt, whose per-map event scans once crashed the world-map load).
  No hooks: everything runs from a 2 s game-thread loop.

  1. Entrance inventory: on each field map, every CPP_MapTransitionTrigger (destination map, transition
     data list, condition, interact type, location) and every CPP_MapLandmarkPoint -> trigger link
     -> dumps/zones/entrances_<map>_<time>.json, rewritten when the set of triggers changes (streaming).
  2. Lock test, world map only: config/zone_lock_test.txt, one line per destination map id:
        <mapId> cond        m_IsUseCondion = true, m_Condition = "{progress:0}>=99999" (in memory)
        <mapId> collision   SetActorEnableCollision(false) (actor property, not saved)
     Each change is read back and logged once per actor. Nothing is restored: a game restart (or map
     reload, which recreates the actors) brings the level-defined values back.
  2b. Fast-travel test (any map): config/zone_fasttravel_test.txt, one line per map id:
        <mapId> prop    UCPP_DA_LandmarkProperty.IdPropertyMap[mapId] = no fast travel (override)
        <mapId> list    landmark data conditions for mapId (UCPP_DA_LandmarkList / UCPP_DA_MapLandmark)
                        set to the impossible condition
        <mapId> vm      pre-hook CPP_VM_WldMap:DecideObject: when the focused object's RelatedMapId is
                        listed, FastTravelBehavior = { bCanTravel = false, LockMap dialog }
     (round 1 + 2 result: entrance locks don't stop fast travel; prop/list edits have no effect)
     The data assets are dumped once per instance (dumps/zones/fasttravel_assets_<time>.json).
  3. Save check: the live save object's Map data (gimmick states, per-map flags) is written before the
     first lock and again 60 s later (dumps/zones/save_map_<when>.json) to confirm nothing persists.
]]

local json = require("lib.json")
local fs = require("util.fs")
local log = require("util.log")
local reflect = require("game.reflect")

local zp = { mod_dir = nil, enabled = false, map_label = nil, is_world = false, last_signature = nil,
             locked = {}, tests = {}, save_before_done = false, scheduled_after = false,
             ft_tests = {}, ft_done = {} }

local LOCKED_CONDITION = "{progress:0}>=99999"

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function plain(v)
    if v == nil then return nil end
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return v end
    local s = safe(function() return v:ToString() end)
    if s ~= nil then return s end
    return safe(function() return v:GetFullName() end) or tostring(v)
end

local function out_dir()
    return fs.join(zp.mod_dir, "dumps", "zones")
end

function zp.init(mod_dir)
    zp.mod_dir = mod_dir
    local cfg = fs.read_all(fs.join(mod_dir, "config", "zone_research.txt"))
    zp.enabled = cfg ~= nil and cfg:match("^%s*on") ~= nil
    zp.tests = {}
    local raw = fs.read_all(fs.join(mod_dir, "config", "zone_lock_test.txt")) or ""
    for line in raw:gmatch("[^\r\n]+") do
        local id, method = line:match("^%s*(%d+)%s*(%a*)")
        if id then zp.tests[tonumber(id)] = (method ~= "" and method) or "cond" end
    end
    local ft = fs.read_all(fs.join(mod_dir, "config", "zone_fasttravel_test.txt")) or ""
    for line in ft:gmatch("[^\r\n]+") do
        local id, method = line:match("^%s*(%d+)%s*(%a*)")
        if id then zp.ft_tests[tonumber(id)] = (method ~= "" and method) or "prop" end
    end
    if zp.enabled then
        reflect.MAP_VALUE_STRUCT_HINTS.IdPropertyMap = "/Script/mucha.MapLandmarkOverrideProperty"
        reflect.MAP_VALUE_STRUCT_HINTS.TypePropertyMap = "/Script/mucha.MapLandmarkOverrideProperty"
        if not fs.exists(fs.join(out_dir(), ".keep")) then
            log.warn("ZONE: dumps/zones/ missing; re-run tools/install_proton.sh --mod-only")
        end
        local n = 0
        for _ in pairs(zp.tests) do n = n + 1 end
        log.info("ZONE research on; %d test lock(s) configured", n)
    end
end

-- Inventory -----------------------------------------------------------------

local function trigger_record(a)
    local r = {
        actor = safe(function() return a:GetFName():ToString() end),
        class = safe(function() return a:GetClass():GetFName():ToString() end),
        address = safe(function() return a:GetAddress() end),
        map_id = plain(safe(function() return a.m_MapId end)),
        point_id = plain(safe(function() return a.m_PointID end)),
        region_id = plain(safe(function() return a.m_RegionId end)),
        unique_id = plain(safe(function() return a.m_UniqueId end)),
        use_condition = plain(safe(function() return a.m_IsUseCondion end)),
        condition = plain(safe(function() return a.m_Condition end)),
        event_only = plain(safe(function() return a.m_IsEventOnly end)),
        auto = plain(safe(function() return a.m_IsAutoTransition end)),
        same_map = plain(safe(function() return a.m_IsSameMapTrasition end)),
        interact_type = plain(safe(function() return a.m_MapInteractType end)),
        object_type = plain(safe(function() return a.m_MapObjectType end)),
        landing_point = plain(safe(function() return a.m_LandingAirShipPointId end)),
        collision = plain(safe(function() return a:GetActorEnableCollision() end)),
        hidden = plain(safe(function() return a.bHidden end)),
        transitions = {},
    }
    local loc = safe(function() return a:K2_GetActorLocation() end)
    if loc then r.location = { x = math.floor(loc.X or 0), y = math.floor(loc.Y or 0), z = math.floor(loc.Z or 0) } end
    pcall(function()
        a.mTransitionDataList:ForEach(function(_, e)
            local d = e:get()
            r.transitions[#r.transitions + 1] = {
                condition = plain(safe(function() return d.FlagCondition end)),
                map_id = plain(safe(function() return d.mapId end)),
                point_id = plain(safe(function() return d.pointId end)),
                event_only = plain(safe(function() return d.isEventOnly end)),
            }
        end)
    end)
    return r
end

local function destinations(r)
    local out = {}
    if type(r.map_id) == "number" and r.map_id > 0 then out[r.map_id] = true end
    for _, t in ipairs(r.transitions) do
        if type(t.map_id) == "number" and t.map_id > 0 then out[t.map_id] = true end
    end
    return out
end

local function inventory()
    local triggers, landmarks = {}, {}
    for _, a in ipairs(safe(function() return FindAllOf("CPP_MapTransitionTrigger") end) or {}) do
        if safe(function() return a:IsValid() end) then triggers[#triggers + 1] = { actor = a, rec = trigger_record(a) } end
    end
    for _, l in ipairs(safe(function() return FindAllOf("CPP_MapLandmarkPoint") end) or {}) do
        if safe(function() return l:IsValid() end) then
            local trig = safe(function() return l.TransitionTrigger end)
            local loc = safe(function() return l:K2_GetActorLocation() end)
            landmarks[#landmarks + 1] = {
                actor = safe(function() return l:GetFName():ToString() end),
                transition_id = plain(safe(function() return l.TransitionId end)),
                trigger = trig and safe(function() return trig:GetFName():ToString() end) or nil,
                airship_landing = plain(safe(function() return l.AirShipLandingId end)),
                location = loc and { x = math.floor(loc.X or 0), y = math.floor(loc.Y or 0) } or nil,
            }
        end
    end
    return triggers, landmarks
end

local function write_json(name, value)
    local path = fs.join(out_dir(), name)
    local ok, encoded = pcall(json.encode, value, true)
    if not ok then log.error("ZONE: JSON encode failed for %s: %s", name, tostring(encoded)) return end
    local wok, err = fs.write_atomic(path, encoded)
    if wok then log.info("ZONE: wrote %s", path) else log.error("ZONE: write failed %s: %s", path, tostring(err)) end
end

-- Save check ----------------------------------------------------------------

local function dump_save_map(when)
    local s = safe(function() return FindFirstOf("CPP_MuchaGameSaveData") end)
    if not s or not safe(function() return s:IsValid() end) then
        log.warn("ZONE: no save object for the save check (%s)", when)
        return
    end
    local all = reflect.object_to_table(s, 0)
    write_json("save_map_" .. when .. "_" .. os.date("%H%M%S") .. ".json",
        { Map = all.Map, Progress = all.Progress })
end

-- Lock test -----------------------------------------------------------------

local function lock(actor, rec, method, dest)
    local key = rec.address
    if not key or zp.locked[key] then return end
    zp.locked[key] = true
    if not zp.save_before_done then
        zp.save_before_done = true
        local ok, err = pcall(dump_save_map, "before")
        if not ok then log.error("ZONE: save check (before) failed: %s", tostring(err)) end
    end
    if method == "collision" then
        local ok, err = pcall(function() actor:SetActorEnableCollision(false) end)
        local now = safe(function() return actor:GetActorEnableCollision() end)
        log.info("ZONE LOCK [collision] %s -> map %d: %s, collision now %s", tostring(rec.actor), dest,
            ok and "set" or ("FAILED " .. tostring(err)), tostring(now))
    else
        local ok, err = pcall(function()
            actor.m_IsUseCondion = true
            actor.m_Condition = LOCKED_CONDITION
        end)
        local use = safe(function() return actor.m_IsUseCondion end)
        local cond = safe(function() return actor.m_Condition:ToString() end)
        log.info("ZONE LOCK [cond] %s -> map %d: %s, read back use=%s cond='%s' (was use=%s cond='%s')",
            tostring(rec.actor), dest, ok and "set" or ("FAILED " .. tostring(err)), tostring(use), tostring(cond),
            tostring(rec.use_condition), tostring(rec.condition))
    end
    if not zp.scheduled_after then
        zp.scheduled_after = true
        ExecuteInGameThreadWithDelay(60000, function()
            local ok, err = pcall(dump_save_map, "after60s")
            if not ok then log.error("ZONE: save check (after) failed: %s", tostring(err)) end
        end)
    end
end

-- Fast-travel test --------------------------------------------------------

local function dump_ft_assets(objs)
    local out = {}
    for _, o in ipairs(objs) do
        out[#out + 1] = { path = safe(function() return o:GetFullName() end), properties = reflect.object_to_table(o, 0) }
    end
    write_json("fasttravel_assets_" .. os.date("%H%M%S") .. ".json", out)
end

local function ft_prop(asset)
    for map_id, method in pairs(zp.ft_tests) do
        if method == "prop" then
            local ok, err = pcall(function()
                asset.IdPropertyMap:Add(map_id, { bCanFastTravel = false, bDisplayName = true,
                    bOverrideCanFastTravel = true, bOverrideDisplayName = false })
            end)
            local back = safe(function()
                local v = asset.IdPropertyMap:Find(map_id):get()
                return string.format("can=%s override=%s", tostring(v.bCanFastTravel), tostring(v.bOverrideCanFastTravel))
            end)
            log.info("ZONE FT [prop] map %d: %s, read back %s", map_id, ok and "added" or ("FAILED " .. tostring(err)), tostring(back))
        end
    end
end

local function ft_list(asset, field)
    local changed = 0
    pcall(function()
        asset[field]:ForEach(function(_, entry)
            local e = entry:get()
            e.landmarkDataList:ForEach(function(_, ld)
                local d = ld:get()
                local mid = safe(function() return d.mapId end)
                if mid and zp.ft_tests[mid] == "list" then
                    local before = safe(function() return d.Condition:ToString() end)
                    local ok, err = pcall(function() d.Condition = LOCKED_CONDITION end)
                    local now = safe(function() return d.Condition:ToString() end)
                    changed = changed + 1
                    log.info("ZONE FT [list] %s map %d: '%s' -> '%s' %s", field, mid, tostring(before), tostring(now),
                        ok and "" or ("FAILED " .. tostring(err)))
                end
            end)
        end)
    end)
    return changed
end

local function fasttravel_test()
    if next(zp.ft_tests) == nil then return end
    local all = {}
    for _, cls in ipairs({ "CPP_DA_LandmarkProperty", "CPP_DA_LandmarkList", "CPP_DA_MapLandmark", "CPP_DA_WldMapParameter" }) do
        for _, o in ipairs(safe(function() return FindAllOf(cls) end) or {}) do
            local a = safe(function() return o:GetAddress() end)
            local name = safe(function() return o:GetFullName() end) or ""
            if a and not zp.ft_done[a] and not name:find("Default__", 1, true) then
                zp.ft_done[a] = true
                all[#all + 1] = o
                if cls == "CPP_DA_LandmarkProperty" then ft_prop(o)
                elseif cls == "CPP_DA_LandmarkList" then ft_list(o, "DataList")
                elseif cls == "CPP_DA_MapLandmark" then ft_list(o, "landmarkDataList") end
                log.info("ZONE FT: processed %s", name)
            end
        end
    end
    if #all > 0 then dump_ft_assets(all) end
end

local LOCKMAP_DIALOG = "UI.Dialog.Box.Map.FastTravel.CanNot.LockMap"

local function behavior_text(vm)
    return safe(function()
        local b = vm.FastTravelBehavior
        return string.format("can=%s dialog=%s", tostring(b.bCanTravel), b.DialogTag.TagName:ToString())
    end) or "?"
end

function zp.register_hooks()
    if not zp.enabled then return end
    local ok, err = pcall(RegisterHook, "/Script/mucha.CPP_VM_WldMap:DecideObject", function(ctx)
        local vm = safe(function() return ctx:get() end)
        if not vm then return end
        local obj = safe(function() return vm.FocusObjectId end)
        local map_id = safe(function() return vm.FocusObjectData.RelatedMapId end)
        log.info("ZONE FT DecideObject: object=%s map=%s behavior(before)=%s", tostring(obj), tostring(map_id), behavior_text(vm))
        if map_id and zp.ft_tests[map_id] == "vm" then
            local wok, werr = pcall(function()
                vm.FastTravelBehavior.bCanTravel = false
                vm.FastTravelBehavior.DialogTag.TagName = FName(LOCKMAP_DIALOG)
            end)
            log.info("ZONE FT [vm] map %d blocked: %s, behavior(now)=%s", map_id,
                wok and "set" or ("FAILED " .. tostring(werr)), behavior_text(vm))
        end
    end)
    log.info("ZONE: DecideObject hook %s", ok and "registered" or ("NOT registered: " .. tostring(err)))
    local ok2, err2 = pcall(RegisterHook, "/Script/mucha.CPP_VM_WldMap:HandleTransitionDialogClose", function(ctx, delval)
        local d = safe(function() return delval:get() end)
        log.info("ZONE FT TransitionDialogClose: dialog=%s choice=%s decided=%s index=%s",
            tostring(safe(function() return d.DialogTag.TagName:ToString() end)),
            tostring(safe(function() return d.ChoiceTag.TagName:ToString() end)),
            tostring(safe(function() return d.IsDecidedItem end)), tostring(safe(function() return d.DecidedItemIndex end)))
    end)
    log.info("ZONE: TransitionDialogClose hook %s", ok2 and "registered" or ("NOT registered: " .. tostring(err2)))
end

-- Loop ----------------------------------------------------------------------

local function scan()
    if not zp.map_label then return end
    local triggers, landmarks = inventory()
    local names = {}
    for _, t in ipairs(triggers) do names[#names + 1] = tostring(t.rec.actor) end
    table.sort(names)
    local signature = zp.map_label .. "|" .. #landmarks .. "|" .. table.concat(names, ",")
    if signature ~= zp.last_signature then
        zp.last_signature = signature
        local recs = {}
        for _, t in ipairs(triggers) do recs[#recs + 1] = t.rec end
        write_json("entrances_" .. zp.map_label .. "_" .. os.date("%H%M%S") .. ".json",
            { map = zp.map_label, triggers = recs, landmarks = landmarks })
        log.info("ZONE: %s has %d transition triggers, %d landmarks", zp.map_label, #triggers, #landmarks)
    end
    if zp.is_world then
        for _, t in ipairs(triggers) do
            for dest in pairs(destinations(t.rec)) do
                local method = zp.tests[dest]
                if method then lock(t.actor, t.rec, method, dest) end
            end
        end
    end
end

function zp.on_game_state(class_name, full_name)
    if not zp.enabled then return end
    local name = tostring(full_name)
    zp.locked = {}          -- actors are recreated with each map load
    zp.last_signature = nil
    if class_name == "CPP_MuchaGameModeField" then
        zp.map_label = name:match("/Game/Map/[^%.]+/([^/%.]+)%.") or "field"
        zp.is_world = name:find("/Map/Wld/", 1, true) ~= nil
    else
        zp.map_label, zp.is_world = nil, false
    end
end

function zp.start()
    if not zp.enabled then return end
    LoopInGameThreadWithDelay(2000, function()
        local ok, err = pcall(scan)
        if not ok then log.error("ZONE scan error: %s", tostring(err)) end
        local fok, ferr = pcall(fasttravel_test)
        if not fok then log.error("ZONE fast-travel test error: %s", tostring(ferr)) end
    end)
end

return zp
