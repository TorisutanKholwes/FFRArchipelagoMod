--[[
  Progressive-shop research (TD-034, Phase A). Active only with config/shop_research.txt = "on".
  Writes DT_ShopList in memory; nothing is saved (DataTables are reloaded on every launch; added items
  have MaxOrderNum -1, so the save's limited-stock list is untouched).

  On the first field map (3 s after load), every chapter-1 shop (Mitra, Grandshelt incl. its "burning"
  variant, Grandport, Nashat, Kol) gets chapter-5 items at half price in its first free slots:
    weapon shops    : Rune Blade (10112), Kiku-Ichimonji (10214)
    armor shops     : Mythril Vest (11009)
    accessory shops : Safety Bit (12018)
    armor+acc shops : Mythril Vest, Safety Bit
    tool shops      : Hi-Potion (2)
  Write method per row: "inplace" (FindRow + assignment to the ItemList elements, reference access per
  the UE4SS docs), then "addrow" (UDataTable:AddRow with the full row) if the first doesn't read back.
  Each row's original and result are logged ("SHOP ...").
]]

local fs = require("util.fs")
local log = require("util.log")

local sp = { enabled = false, done = false }

local TABLE = "/Game/Datatable/Shop/DT_ShopList.DT_ShopList"
local RATIO = 0.5
local WEAPONS = { 10112, 10214 }
local ARMOR = { 11009 }
local ACCESSORY = { 12018 }
local TOOL = { 2 }

-- ShopID -> items to add (chapter-1 shops, from DT_ShopList).
local TARGETS = {
    [2001] = WEAPONS, [2002] = WEAPONS, [2003] = WEAPONS, [2004] = WEAPONS, [2007] = WEAPONS,
    [4001] = ARMOR, [4002] = ARMOR, [4003] = ARMOR, [4005] = ARMOR, [4017] = ARMOR,
    [6001] = ACCESSORY, [6002] = ACCESSORY, [6003] = ACCESSORY, [6004] = ACCESSORY, [6010] = ACCESSORY,
    [8002] = { 11009, 12018 }, [8008] = { 11009, 12018 },
    [1] = TOOL, [3] = TOOL, [4] = TOOL, [5] = TOOL, [6] = TOOL, [7] = TOOL, [8] = TOOL,
}

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

function sp.init(mod_dir)
    local cfg = fs.read_all(fs.join(mod_dir, "config", "shop_research.txt"))
    sp.enabled = cfg ~= nil and cfg:match("^%s*on") ~= nil
    if sp.enabled then log.info("SHOP research on") end
end

local function read_items(row)
    local out = {}
    row.ItemList:ForEach(function(_, e)
        local d = e:get()
        out[#out + 1] = { ItemId = d.ItemId, Condition = safe(function() return d.Condition:ToString() end) or "",
                          MaxOrderNum = d.MaxOrderNum, PriceRatio = d.PriceRatio }
    end)
    return out
end

local function describe(items)
    local parts = {}
    for _, it in ipairs(items) do
        if it.ItemId ~= -1 then parts[#parts + 1] = string.format("%d x%.2f", it.ItemId, it.PriceRatio) end
    end
    return table.concat(parts, ", ")
end

local function has_added(items, added)
    for _, id in ipairs(added) do
        local ok = false
        for _, it in ipairs(items) do
            if it.ItemId == id and math.abs(it.PriceRatio - RATIO) < 0.001 then ok = true end
        end
        if not ok then return false end
    end
    return true
end

local function inplace(dt, name, added)
    local row = dt:FindRow(name)
    local i = 1
    row.ItemList:ForEach(function(_, e)
        if i > #added then return true end
        local d = e:get()
        if d.ItemId == -1 then
            d.ItemId = added[i]
            d.PriceRatio = RATIO
            d.MaxOrderNum = -1
            i = i + 1
        end
    end)
end

local function addrow(dt, name, original, added)
    local row = dt:FindRow(name)
    local items, i = {}, 1
    for k, it in ipairs(original) do
        items[k] = { ItemId = it.ItemId, Condition = it.Condition, MaxOrderNum = it.MaxOrderNum, PriceRatio = it.PriceRatio }
        if it.ItemId == -1 and i <= #added then
            items[k] = { ItemId = added[i], Condition = "", MaxOrderNum = -1, PriceRatio = RATIO }
            i = i + 1
        end
    end
    local sell = {}
    row.SellItemList:ForEach(function(_, e)
        local d = e:get()
        sell[#sell + 1] = { ItemId = d.ItemId, PriceRatio = d.PriceRatio }
    end)
    dt:AddRow(name, { ShopID = row.ShopID, ShopName = FText(row.ShopName:ToString()), ItemList = items, SellItemList = sell })
end

local function probe()
    local dt = StaticFindObject(TABLE)
    if not dt or not dt:IsValid() then error("DataTable not found: " .. TABLE) end
    local rows = {}
    dt:ForEachRow(function(name, row)
        local id = safe(function() return row.ShopID end)
        if id and TARGETS[id] then rows[#rows + 1] = { name = name, id = id } end
    end)
    local inplace_ok, addrow_ok, failed = 0, 0, 0
    for _, r in ipairs(rows) do
        local added = TARGETS[r.id]
        local original = read_items(dt:FindRow(r.name))
        local ok, err = pcall(inplace, dt, r.name, added)
        local now = read_items(dt:FindRow(r.name))
        if has_added(now, added) then
            inplace_ok = inplace_ok + 1
        else
            log.info("SHOP %d in-place did not read back (%s); trying AddRow", r.id, ok and "ran" or tostring(err))
            ok, err = pcall(addrow, dt, r.name, original, added)
            now = read_items(dt:FindRow(r.name))
            if has_added(now, added) then addrow_ok = addrow_ok + 1 else failed = failed + 1 end
            if not ok then log.warn("SHOP %d AddRow failed: %s", r.id, tostring(err)) end
        end
        log.info("SHOP %d %s: before [%s] -> now [%s]", r.id, r.name, describe(original), describe(now))
    end
    log.info("SHOP RESULT: %d row(s) changed in place, %d by AddRow, %d failed (of %d)", inplace_ok, addrow_ok, failed, #rows)
end

function sp.on_game_state(class_name)
    if not sp.enabled or sp.done or class_name ~= "CPP_MuchaGameModeField" then return end
    sp.done = true
    ExecuteInGameThreadWithDelay(3000, function()
        local ok, err = pcall(probe)
        if not ok then log.error("SHOP probe failed: %s", tostring(err)) end
    end)
end

return sp
