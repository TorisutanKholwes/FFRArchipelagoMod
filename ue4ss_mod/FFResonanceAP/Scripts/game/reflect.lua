--[[
  Generic conversion of Unreal reflected values into plain Lua tables (for JSON dumps).
  Only uses documented UE4SS Lua APIs:
    Property:GetFName/GetClass, StructProperty:GetStruct, ArrayProperty:GetInner,
    UStruct:ForEachProperty, TArray:ForEach, FName/FString/FText:ToString,
    UObject:IsValid/GetFullName.
  Every access is wrapped in pcall: a dump must never crash the game.
]]

local reflect = {}

reflect.MAX_DEPTH = 6
reflect.MAX_ARRAY = 20000

-- TMap property name -> value struct path (from CXXHeaderDump/mucha.hpp, UCPP_MuchaGameSaveData).
reflect.MAP_VALUE_STRUCT_HINTS = {
    mapGimmick = "/Script/mucha.SaveData_MapGimmick",
    perMapSaveDataMap = "/Script/mucha.SaveData_PerMap",
    artifactList = "/Script/mucha.SaveData_Artifact",
    DataMap = "/Script/mucha.SaveData_RequestData",
    gimmickState = "/Script/mucha.SaveData_MapGimmickState",
}

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

function reflect.prop_name(prop)
    return safe(function() return prop:GetFName():ToString() end) or "?"
end

function reflect.prop_type(prop)
    return safe(function() return prop:GetClass():GetFName():ToString() end) or "?"
end

--- Convert an FName/FString/FText/UObject-ish userdata to a string, best effort.
local function stringify_userdata(v)
    local s = safe(function() return v:ToString() end)
    if s ~= nil then return s end
    local valid = safe(function() return v:IsValid() end)
    if valid == false then return nil end
    s = safe(function() return v:GetFullName() end)
    if s ~= nil then return s end
    return tostring(v)
end

local convert_value

-- Cache: struct full path -> UStruct wrapper that exposes ForEachProperty.
local struct_cache = {}

--- Return a wrapper for `struct_type` on which ForEachProperty can be called.
--- Observed on FFRS (UE4SS 3.0.1-1217): UDataTable:GetRowStruct() returns a wrapper without
--- UStruct methods ("attempt to call a TrivialObject value (method 'ForEachProperty')").
--- Re-fetching the same object through StaticFindObject yields a proper UStruct wrapper.
function reflect.resolve_struct(struct_type)
    if struct_type == nil then return nil end
    if type(safe(function() return struct_type.ForEachProperty end)) == "function" then
        return struct_type
    end
    local full = safe(function() return struct_type:GetFullName() end)
    if not full then return nil end
    local path = full:match("^%S+%s+(.+)$") or full
    local cached = struct_cache[path]
    if cached ~= nil then return cached or nil end
    local found = safe(function() return StaticFindObject(path) end)
    if found and safe(function() return found:IsValid() end)
        and type(safe(function() return found.ForEachProperty end)) == "function" then
        struct_cache[path] = found
        return found
    end
    struct_cache[path] = false
    return nil
end

--- Convert a struct value given its UScriptStruct type.
function reflect.struct_to_table(struct_type, value, depth)
    depth = depth or 0
    if depth > reflect.MAX_DEPTH then return "<max depth>" end
    local resolved = reflect.resolve_struct(struct_type)
    if not resolved then
        return { ["<error>"] = "cannot resolve struct type " .. tostring(safe(function() return struct_type:GetFullName() end)) }
    end
    struct_type = resolved
    local out = {}
    local ok, err = pcall(function()
        struct_type:ForEachProperty(function(prop)
            local name = reflect.prop_name(prop)
            local raw = safe(function() return value[name] end)
            out[name] = convert_value(prop, raw, depth + 1)
        end)
    end)
    if not ok then out["<error>"] = tostring(err) end
    -- Include inherited members (e.g. FTableRowBase subclasses).
    local super = safe(function() return struct_type:GetSuperStruct() end)
    if super and safe(function() return super:IsValid() end) then
        local inherited = reflect.struct_to_table(super, value, depth + 1)
        if type(inherited) == "table" then
            for k, v in pairs(inherited) do
                if out[k] == nil then out[k] = v end
            end
        end
    end
    return out
end

convert_value = function(prop, raw, depth)
    if raw == nil then return nil end
    local rt = type(raw)
    if rt == "number" or rt == "boolean" or rt == "string" then return raw end
    local ptype = reflect.prop_type(prop)

    if ptype == "StructProperty" then
        local st = safe(function() return prop:GetStruct() end)
        if st then return reflect.struct_to_table(st, raw, depth) end
        return stringify_userdata(raw)
    elseif ptype == "ArrayProperty" then
        local inner = safe(function() return prop:GetInner() end)
        local arr = {}
        local ok, err = pcall(function()
            raw:ForEach(function(index, elem)
                if index > reflect.MAX_ARRAY then return true end
                local v = safe(function() return elem:get() end)
                arr[#arr + 1] = inner and convert_value(inner, v, depth + 1) or stringify_userdata(v)
            end)
        end)
        if not ok then return { ["<error>"] = tostring(err) } end
        return arr
    elseif ptype == "MapProperty" then
        -- UE4SS does not expose MapProperty key/value types to Lua, so struct values are decoded
        -- through a hint table keyed by property name (types taken from the CXX header dump).
        local hint = reflect.MAP_VALUE_STRUCT_HINTS[reflect.prop_name(prop)]
        local value_struct = hint and safe(function() return StaticFindObject(hint) end) or nil
        local map = {}
        local ok, err = pcall(function()
            raw:ForEach(function(key, value)
                local k = safe(function() return key:get() end)
                local v = safe(function() return value:get() end)
                local kstr = (type(k) == "number" or type(k) == "string") and tostring(k) or (stringify_userdata(k) or "?")
                if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                    map[kstr] = v
                elseif value_struct then
                    map[kstr] = reflect.struct_to_table(value_struct, v, depth + 1)
                else
                    map[kstr] = stringify_userdata(v)
                end
            end)
        end)
        if not ok then return { ["<error>"] = tostring(err) } end
        return map
    elseif ptype == "SetProperty" then
        return "<SetProperty not dumped>"
    elseif ptype:find("Delegate") then
        return nil
    end
    if rt == "userdata" or rt == "table" then
        return stringify_userdata(raw)
    end
    return tostring(raw)
end

reflect.convert_value = convert_value

--- Describe a UStruct/UClass: list of {name, type} for its own properties.
function reflect.describe_properties(ustruct)
    local props = {}
    ustruct = reflect.resolve_struct(ustruct) or ustruct
    pcall(function()
        ustruct:ForEachProperty(function(prop)
            props[#props + 1] = { name = reflect.prop_name(prop), type = reflect.prop_type(prop) }
        end)
    end)
    return props
end

--- Describe the UFunctions of a UClass with their parameters.
function reflect.describe_functions(uclass)
    local fns = {}
    pcall(function()
        uclass:ForEachFunction(function(fn)
            fns[#fns + 1] = {
                name = safe(function() return fn:GetFName():ToString() end) or "?",
                params = reflect.describe_properties(fn),
            }
        end)
    end)
    return fns
end

--- Convert all reflected properties of a UObject instance (its class chain) to a table.
function reflect.object_to_table(obj, depth)
    depth = depth or 0
    local out = {}
    local cls = safe(function() return obj:GetClass() end)
    local guard = 0
    while cls and safe(function() return cls:IsValid() end) and guard < 32 do
        guard = guard + 1
        pcall(function()
            cls:ForEachProperty(function(prop)
                local name = reflect.prop_name(prop)
                if out[name] == nil then
                    local raw = safe(function() return obj[name] end)
                    out[name] = convert_value(prop, raw, depth + 1)
                end
            end)
        end)
        cls = safe(function() return cls:GetSuperStruct() end)
    end
    return out
end

return reflect
