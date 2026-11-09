--[[
  Progressive shops (TD-034). Pure Lua (unit-tested).

  The k-th "Progressive <Weapon|Armor|Accessory> Shop" received unlocks mappings.shop_tiers[chain][k].
  Counts come from the full received-item list (shops are rebuilt in memory on every launch; nothing is
  stored in the save). A shop list (15 slots: { ItemId, MaxOrderNum, PriceRatio, Condition }) is merged
  with the unlocked gear, never losing strength:
    weapon / armor: for each tier item, skip if the shop already sells it or an item of the same kind
                    and type that is at least as expensive; else put it in a free slot, so the shop keeps
                    its own stock (owner decision 2026-11-09); only when the list is full, replace the
                    cheapest item of that type (plain slots only: unlimited stock, no condition);
    accessory     : accessories of every unlocked tier, newest tier first, into free slots.
  Added/replaced slots get PriceRatio = the seed's price option, MaxOrderNum -1.
]]

local shops = {}

shops.CHAINS = { "weapon", "armor", "accessory" }
local RATIOS = { [0] = 1.0, [1] = 0.5, [2] = 0.25 }

function shops.enabled(slot_data)
    return type(slot_data) == "table" and (slot_data.progressive_shops == 1 or slot_data.progressive_shops == true)
end

function shops.ratio(slot_data)
    return RATIOS[type(slot_data) == "table" and slot_data.progressive_shop_prices or 1] or 0.5
end

--- Number of tiers unlocked per chain, capped by the tiers that exist.
function shops.counts(items, mappings)
    local out = { weapon = 0, armor = 0, accessory = 0 }
    for _, it in ipairs(items or {}) do
        local m = mappings.items[it.item]
        if m and m.method == "shop_tier" and out[m.chain] then out[m.chain] = out[m.chain] + 1 end
    end
    for chain, n in pairs(out) do
        out[chain] = math.min(n, #(mappings.shop_tiers[chain] or {}))
    end
    return out
end

local function copy(list)
    local out = {}
    for i, e in ipairs(list) do
        out[i] = { ItemId = e.ItemId, MaxOrderNum = e.MaxOrderNum, PriceRatio = e.PriceRatio, Condition = e.Condition or "" }
    end
    return out
end

local function sold(list, id)
    for _, e in ipairs(list) do
        if e.ItemId == id then return true end
    end
    return false
end

local function free_slot(list)
    for i, e in ipairs(list) do
        if e.ItemId == -1 then return i end
    end
    return nil
end

local function put(list, i, id, ratio)
    list[i] = { ItemId = id, MaxOrderNum = -1, PriceRatio = ratio, Condition = "" }
end

local function add_gear(list, chain, n, mappings, ratio)
    if n < 1 then return end
    for _, id in ipairs(mappings.shop_tiers[chain][n].items) do
        local e = mappings.equip[id]
        local stronger = false
        if e then
            for _, slot in ipairs(list) do
                local s = mappings.equip[slot.ItemId]
                if slot.ItemId == id or (s and s.kind == e.kind and s.detail == e.detail and s.price >= e.price) then
                    stronger = true
                    break
                end
            end
        end
        if e and not stronger then
            local target = free_slot(list)
            if not target then
                local cheapest
                for i, slot in ipairs(list) do
                    local s = mappings.equip[slot.ItemId]
                    if s and s.kind == e.kind and s.detail == e.detail and s.price < e.price
                        and slot.MaxOrderNum == -1 and (slot.Condition or "") == ""
                        and (not cheapest or s.price < mappings.equip[list[cheapest].ItemId].price) then
                        cheapest = i
                    end
                end
                target = cheapest
            end
            if target then put(list, target, id, ratio) end
        end
    end
end

local function add_accessories(list, n, mappings, ratio)
    for k = n, 1, -1 do
        for _, id in ipairs(mappings.shop_tiers.accessory[k].items) do
            if not sold(list, id) then
                local i = free_slot(list)
                if not i then return end
                put(list, i, id, ratio)
            end
        end
    end
end

--- The merged list for a shop of `kind` (weapon | armor | accessory | armor_accessory).
function shops.merge(original, kind, counts, mappings, ratio)
    local list = copy(original)
    if kind == "weapon" then
        add_gear(list, "weapon", counts.weapon, mappings, ratio)
    elseif kind == "armor" then
        add_gear(list, "armor", counts.armor, mappings, ratio)
    elseif kind == "accessory" then
        add_accessories(list, counts.accessory, mappings, ratio)
    elseif kind == "armor_accessory" then
        add_gear(list, "armor", counts.armor, mappings, ratio)
        add_accessories(list, counts.accessory, mappings, ratio)
    end
    return list
end

--- Do two lists differ (ItemId / PriceRatio / MaxOrderNum)?
function shops.differs(a, b)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i], b[i]
        if not x or not y or x.ItemId ~= y.ItemId or x.MaxOrderNum ~= y.MaxOrderNum
            or math.abs((x.PriceRatio or 0) - (y.PriceRatio or 0)) > 1e-6 then
            return true
        end
    end
    return false
end

return shops
