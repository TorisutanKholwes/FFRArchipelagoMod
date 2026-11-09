--[[
  Zone-lock bookkeeping (TD-033). Pure Lua (unit-tested).

  A zone is unlocked when its "<Zone> Access" item is in the bridge's received-item list. The full
  list is used (not the per-save applied index): unlocks aren't stored in game saves, and the start
  zones arrive as precollected items at the beginning of that list.
]]

local zones = {}

--- Is zone locking on for this seed (slot_data.zone_locks)?
function zones.enabled(slot_data)
    return type(slot_data) == "table" and (slot_data.zone_locks == 1 or slot_data.zone_locks == true)
end

--- Set of unlocked zone ids from received items ({ {item = ap_id, ...}, ... }).
function zones.unlocked(items, mappings)
    local out = {}
    for _, it in ipairs(items or {}) do
        local m = mappings.items[it.item]
        if m and m.method == "zone" then out[m.zone] = true end
    end
    return out
end

--- Set of map ids that belong to a locked zone.
function zones.locked_maps(unlocked, mappings)
    local out = {}
    for map_id, zone in pairs(mappings.zone_of_map) do
        if not unlocked[zone] then out[map_id] = true end
    end
    return out
end

--- Should an entrance with these destination map ids be locked?
function zones.entrance_locked(destinations, locked_maps)
    for _, map_id in ipairs(destinations) do
        if locked_maps[map_id] then return true end
    end
    return false
end

--- Short description for the log: "<unlocked>/<total> zones unlocked".
function zones.summary(unlocked, mappings)
    local total, open = 0, 0
    for zone in pairs(mappings.zone_names) do
        total = total + 1
        if unlocked[zone] then open = open + 1 end
    end
    return string.format("%d/%d zones unlocked", open, total)
end

return zones
