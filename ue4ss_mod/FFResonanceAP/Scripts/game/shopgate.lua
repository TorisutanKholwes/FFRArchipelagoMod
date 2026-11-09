--[[
  Progressive shops in game (TD-034). Active only while the runtime is bound to a seed (armed by Connect)
  whose slot_data has progressive_shops on; otherwise the shops stay vanilla.

  DT_ShopList rows of the equipment shops (mappings.shop_kinds) are rewritten in memory: FindRow +
  assignment to the ItemList elements (verified in game: the shop shows the change and purchases work).
  The original lists are read once and kept; they are written back when the gate turns off. DataTables
  are reloaded on every launch and added items have MaxOrderNum -1, so nothing reaches the save.
  Rows are only written while the game is idle in the field (no shop/menu/dialog/event open).
]]

local log = require("util.log")
local mappings = require("generated.mappings")
local shops = require("ap.shops")
local gamestate = require("game.gamestate")

local sg = {
    runtime = nil, originals = nil, applied = "vanilla", slot_enabled = false, ratio = 0.5, items = nil,
    broken = false,
}

local TABLE = "/Game/Datatable/Shop/DT_ShopList.DT_ShopList"

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

function sg.init(runtime)
    sg.runtime = runtime
end

local function shop_table()
    local dt = StaticFindObject(TABLE)
    if not dt or not dt:IsValid() then return nil end
    return dt
end

local function read_items(row)
    local out = {}
    row.ItemList:ForEach(function(_, e)
        local d = e:get()
        out[#out + 1] = { ItemId = d.ItemId, MaxOrderNum = d.MaxOrderNum, PriceRatio = d.PriceRatio,
                          Condition = safe(function() return d.Condition:ToString() end) or "" }
    end)
    return out
end

local function snapshot(dt)
    local originals = {}
    dt:ForEachRow(function(name, row)
        local id = safe(function() return row.ShopID end)
        local kind = id and mappings.shop_kinds[id]
        if kind then originals[name] = { id = id, kind = kind, items = read_items(row) } end
    end)
    return originals
end

--- Write `target` into the row's ItemList (only the slots that differ). Returns true if it reads back.
local function write_row(dt, name, target)
    local row = dt:FindRow(name)
    local i = 0
    row.ItemList:ForEach(function(_, e)
        i = i + 1
        local t = target[i]
        if not t then return true end
        local d = e:get()
        if d.ItemId ~= t.ItemId then d.ItemId = t.ItemId end
        if d.MaxOrderNum ~= t.MaxOrderNum then d.MaxOrderNum = t.MaxOrderNum end
        if math.abs(d.PriceRatio - t.PriceRatio) > 1e-6 then d.PriceRatio = t.PriceRatio end
    end)
    return not shops.differs(read_items(dt:FindRow(name)), target)
end

local function signature(active, counts)
    if not active then return "vanilla" end
    return string.format("w%d a%d c%d x%.2f", counts.weapon, counts.armor, counts.accessory, sg.ratio)
end

local function apply(active, counts)
    local dt = shop_table()
    if not dt then return false end
    sg.originals = sg.originals or snapshot(dt)
    local written, failed = 0, 0
    for name, orig in pairs(sg.originals) do
        local target = active and shops.merge(orig.items, orig.kind, counts, mappings, sg.ratio) or orig.items
        if shops.differs(read_items(dt:FindRow(name)), target) then
            if write_row(dt, name, target) then written = written + 1 else failed = failed + 1 end
        end
    end
    local function tier_text(chain)
        local n = counts[chain]
        return n > 0 and string.format("tier %d (chapter %d)", n, mappings.shop_tiers[chain][n].chapter) or "vanilla"
    end
    if active then
        log.info("SHOPS: weapons %s, armor %s, accessories %s, price x%.2f; %d row(s) written%s",
            tier_text("weapon"), tier_text("armor"), tier_text("accessory"), sg.ratio, written,
            failed > 0 and string.format(", %d FAILED", failed) or "")
    elseif written > 0 or failed > 0 then
        log.info("SHOPS: vanilla shops restored (%d row(s)%s)", written, failed > 0 and string.format(", %d FAILED", failed) or "")
    end
    if failed > 0 then
        sg.broken = true
        log.error("SHOPS: shop rows could not be written; progressive shops disabled until restart")
    end
    return true
end

function sg.tick()
    if sg.broken then return end
    local rt = sg.runtime
    local st = rt.bridge
    if st and type(st.slot_data) == "table" then
        sg.slot_enabled = shops.enabled(st.slot_data)
        sg.ratio = shops.ratio(st.slot_data)
        sg.items = st.items
    end
    local active = rt.session:is_bound() and sg.slot_enabled
    local counts = shops.counts(active and sg.items or {}, mappings)
    local sig = signature(active, counts)
    if sig == sg.applied then return end
    -- Never change a shop list while the game might be showing it.
    local ok, idle = pcall(gamestate.idle)
    if ok and not idle then return end
    local aok, done = pcall(apply, active, counts)
    if not aok then
        sg.broken = true
        log.error("SHOPS: applying failed (%s); progressive shops disabled until restart", tostring(done))
    elseif done then
        sg.applied = sig
    end
end

function sg.start()
    LoopInGameThreadWithDelay(1000, function()
        local ok, err = pcall(sg.tick)
        if not ok then log.error("SHOPS tick error: %s", tostring(err)) end
    end)
end

return sg
