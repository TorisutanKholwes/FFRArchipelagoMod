--[[
  Research / data-extraction tooling (Milestone M1).
  These functions read game reflection data and write JSON files under <mod>/dumps.
  They never modify game state.

    dump.discover_classes()  -> dumps/classes.json      (game classes of interest: props + functions,
                                                          live instance counts, module list)
    dump.datatables()        -> dumps/datatables_index.json + dumps/datatables/<Table>.json
    dump.snapshot()          -> dumps/snapshots/snapshot_<time>.json
                                (all properties of live instances of the classes listed in
                                 config/watch_classes.txt; diff two snapshots to find state changes)
]]

local json = require("lib.json")
local fs = require("util.fs")
local log = require("util.log")
local reflect = require("game.reflect")

local dump = { mod_dir = nil }

local KEYWORDS = {
    "save", "flag", "item", "invent", "treasure", "chest", "scenario", "quest", "vision",
    "esper", "summon", "party", "gimmick", "collect", "reward", "shop", "gil", "chapter",
    "story", "event", "debug", "subsystem", "gameinstance", "gamemode", "player", "unit",
    "equip", "mastery", "colosseum", "achievement", "journal", "landmark", "warp", "tablet",
}

-- Engine / plugin script modules that are not game code. Classes in these modules are
-- skipped unless they are blueprint (/Game/) classes.
local ENGINE_MODULE_PREFIXES = {
    "Engine", "CoreUObject", "UMG", "Slate", "SlateCore", "Niagara", "MovieScene", "Chaos",
    "Landscape", "AudioMixer", "AudioExtensions", "Media", "Paper2D", "AIModule", "NavigationSystem",
    "GameplayTags", "GameplayTasks", "EnhancedInput", "InputCore", "Foliage", "PhysicsCore",
    "AnimGraphRuntime", "LevelSequence", "CinematicCamera", "DeveloperSettings", "Synthesis",
    "OnlineSubsystem", "Steam", "MetasoundEngine", "MetasoundFrontend", "Interchange", "NNE",
    "PCG", "Water", "ControlRig", "RigVM", "IKRig", "CommonUI", "CommonInput", "ModelViewViewModel",
    "Renderer", "MRMesh", "Overlay", "PropertyPath", "ClothingSystem", "GeometryCollection",
    "FieldNotification", "ImageWrite", "SignificanceManager", "UE4SS",
}

function dump.init(mod_dir)
    dump.mod_dir = mod_dir
end

local function out_path(...)
    return fs.join(dump.mod_dir, "dumps", ...)
end

local function write_json(path, value)
    local ok, encoded = pcall(json.encode, value, true)
    if not ok then
        log.error("JSON encode failed for %s: %s", path, tostring(encoded))
        return false
    end
    local wok, err = fs.write_atomic(path, encoded)
    if not wok then
        log.error("Write failed: %s (does the folder exist? run tools/install_proton.sh)", tostring(err))
        return false
    end
    log.info("Wrote %s (%d bytes)", path, #encoded)
    return true
end

local function matches_keyword(name)
    local lname = name:lower()
    for _, k in ipairs(KEYWORDS) do
        if lname:find(k, 1, true) then return true end
    end
    return false
end

local function is_engine_module(path)
    local module = path:match("^/Script/([^%.]+)%.")
    if not module then return false end
    for _, prefix in ipairs(ENGINE_MODULE_PREFIXES) do
        if module:sub(1, #prefix) == prefix then return true end
    end
    return false
end

--- Strip the "Class " / "BlueprintGeneratedClass " type prefix from GetFullName().
local function object_path(full_name)
    return full_name:match("^%S+%s+(.+)$") or full_name
end

function dump.discover_classes()
    log.info("Class discovery started (this can take a while)...")
    local started = os.clock()
    local modules = {}
    local classes = {}          -- path -> description
    local instance_counts = {}  -- class short name -> live (non-CDO) instance count
    local total = 0

    ForEachUObject(function(obj)
        total = total + 1
        local ok, err = pcall(function()
            if obj:IsClass() then
                local path = object_path(obj:GetFullName())
                local module = path:match("^/Script/([^%.]+)%.")
                if module then modules[module] = (modules[module] or 0) + 1 end
                local short = obj:GetFName():ToString()
                if matches_keyword(short) and not is_engine_module(path) then
                    local super = obj:GetSuperStruct()
                    classes[path] = {
                        name = short,
                        path = path,
                        super = (super and super:IsValid()) and object_path(super:GetFullName()) or nil,
                        properties = reflect.describe_properties(obj),
                        functions = reflect.describe_functions(obj),
                    }
                end
            else
                local cls = obj:GetClass()
                if cls and cls:IsValid() then
                    local cname = cls:GetFName():ToString()
                    -- Default objects are named Default__X; skip them.
                    if not obj:GetFName():ToString():find("^Default__") then
                        instance_counts[cname] = (instance_counts[cname] or 0) + 1
                    end
                end
            end
        end)
        if not ok and total % 50000 == 0 then log.debug("discovery error: %s", tostring(err)) end
    end)

    local class_list = {}
    for _, c in pairs(classes) do
        c.live_instances = instance_counts[c.name] or 0
        class_list[#class_list + 1] = c
    end
    table.sort(class_list, function(a, b) return a.path < b.path end)

    local result = {
        generated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        objects_scanned = total,
        script_modules = modules,
        classes = class_list,
    }
    write_json(out_path("classes.json"), result)
    log.info("Class discovery done: %d objects, %d classes of interest, %.1fs",
        total, #class_list, os.clock() - started)
end

function dump.datatables()
    local tables = FindAllOf("DataTable")
    if not tables then
        log.warn("No DataTable instances found in memory")
        return
    end
    log.info("Dumping %d DataTables...", #tables)
    local index = {}
    for _, dt in ipairs(tables) do
        local entry = {}
        local ok, err = pcall(function()
            entry.name = dt:GetFName():ToString()
            entry.path = object_path(dt:GetFullName())
            entry.class = dt:GetClass():GetFName():ToString()
            local row_struct = dt:GetRowStruct()
            entry.row_struct = row_struct and object_path(row_struct:GetFullName()) or nil
            entry.row_count = #dt
            entry.columns = row_struct and reflect.describe_properties(row_struct) or {}

            local rows = {}
            if row_struct then
                dt:ForEachRow(function(row_name, row_data)
                    rows[row_name] = reflect.struct_to_table(row_struct, row_data, 0)
                end)
            end
            entry.file = "datatables/" .. entry.name .. ".json"
            write_json(out_path(entry.file), {
                name = entry.name, path = entry.path, row_struct = entry.row_struct,
                columns = entry.columns, rows = rows,
            })
        end)
        if not ok then
            entry.error = tostring(err)
            log.warn("DataTable dump error (%s): %s", tostring(entry.name), entry.error)
        end
        index[#index + 1] = entry
    end
    table.sort(index, function(a, b) return (a.name or "") < (b.name or "") end)
    write_json(out_path("datatables_index.json"), { generated = os.date("!%Y-%m-%dT%H:%M:%SZ"), tables = index })
end

local function read_watch_list()
    local path = fs.join(dump.mod_dir, "config", "watch_classes.txt")
    local data = fs.read_all(path)
    local list = {}
    if not data then
        log.warn("No %s; nothing to snapshot", path)
        return list
    end
    for line in data:gmatch("[^\r\n]+") do
        local name = line:gsub("#.*$", ""):match("^%s*(.-)%s*$")
        if name ~= "" then list[#list + 1] = name end
    end
    return list
end

function dump.snapshot()
    local names = read_watch_list()
    if #names == 0 then return end
    local snap = { generated = os.date("!%Y-%m-%dT%H:%M:%SZ"), classes = {} }
    for _, cname in ipairs(names) do
        local instances = FindAllOf(cname)
        local list = {}
        for _, obj in ipairs(instances or {}) do
            local ok, res = pcall(function()
                return { path = object_path(obj:GetFullName()), properties = reflect.object_to_table(obj, 0) }
            end)
            list[#list + 1] = ok and res or { error = tostring(res) }
        end
        snap.classes[cname] = list
        log.info("Snapshot: %s -> %d instance(s)", cname, #list)
    end
    write_json(out_path("snapshots", "snapshot_" .. os.date("%Y%m%d_%H%M%S") .. ".json"), snap)
end

return dump
