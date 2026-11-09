--[[
  Milestone M1/M3 probes. All function and class names come from the UE4SS CXX header dump of
  FFRS (module /Script/mucha, see research notes in TECHNICAL_DECISIONS.md TD-009).

    probe.register_hooks()  log calls to candidate UFunctions (chest open, inventory, flags, save/load)
    probe.state()           read-only: money, chapter, map id; dumps the live save object
                            (CPP_MuchaGameSaveData) to dumps/savedata.json
    probe.notify_test()     opens the game's item-obtained dialog (CPP_BFL_Dialog:OpenItemObtainDialog)
                            with a Lua-built TArray<FItemSet>; display only, grants nothing (M6 test)
    probe.test_grant()      MODIFIES GAME STATE: adds 1 Potion via
                            CPP_BFL_SaveDataInventory:AddInventory and logs the count before/after
]]

local json = require("lib.json")
local fs = require("util.fs")
local log = require("util.log")
local reflect = require("game.reflect")

local probe = { mod_dir = nil }

local LIB = {
    inventory = "/Script/mucha.Default__CPP_BFL_SaveDataInventory",
    item = "/Script/mucha.Default__CPP_BFL_Item",
    map = "/Script/mucha.Default__CPP_BFL_SaveDataMap",
    player = "/Script/mucha.Default__CPP_BFL_SaveDataPlayer",
    scenario = "/Script/mucha.Default__CPP_BFL_Scenario",
    vision = "/Script/mucha.Default__CPP_BFL_Vision",
    dialog = "/Script/mucha.Default__CPP_BFL_Dialog",
}

local CONSUMABLES_TABLE = "/Game/Datatable/Item/DT_ConsumablesItemData.DT_ConsumablesItemData"
local POTION_ROW = "ポーション" -- row name of "Potion" in DT_ConsumablesItemData (observed in dump)

-- Candidate UFunctions to observe. A hook only fires when the function is invoked through
-- ProcessEvent (e.g. from Blueprint); native C++ -> C++ calls are invisible to it.
local HOOKS = {
    "/Script/mucha.CPP_BFL_SaveDataMap:OpenTreasureBox",
    "/Script/mucha.CPP_BFL_SaveDataMap:OpenTreasureBoxWithoutId",
    "/Script/mucha.CPP_BFL_SaveDataMap:SetTreasureBox",
    "/Script/mucha.CPP_BFL_SaveDataMap:UnlockTreasureBox",
    "/Script/mucha.CPP_MapGimmick_TreasureBox:SetOpen",
    "/Script/mucha.CPP_MapGimmick_TreasureBox:SetOpen_BP",
    "/Script/mucha.CPP_MapGimmick_ItemObjectBase:TryGetItem",
    "/Script/mucha.CPP_MapGimmick_ItemObjectBase:GetItem",
    "/Script/mucha.CPP_MapGimmick_ItemObjectBase:SetInventory",
    "/Script/mucha.CPP_BFL_SaveDataInventory:AddInventory",
    "/Script/mucha.CPP_BFL_SaveDataInventory:SetInventoryItem",
    "/Script/mucha.CPP_BFL_SaveDataPlayer:AddCurrentMoney",
    "/Script/mucha.CPP_BFL_SaveDataPlayer:SetCurrentMoney",
    "/Script/mucha.CPP_BFL_SaveDataProgress:SetFlag",
    "/Script/mucha.CPP_BFL_SaveDataUnit:SetJoinStatus",
    "/Script/mucha.CPP_BFL_SaveDataQuestBoard:ChangeQuestState",
    "/Script/mucha.CPP_BFL_SaveData:SaveGameData",
    "/Script/mucha.CPP_BFL_SaveData:LoadGameData",
    "/Script/mucha.CPP_BFL_SaveData:ApplySaveGameData",
    "/Script/mucha.CPP_BFL_SaveData:AutoSave",
}

function probe.init(mod_dir)
    probe.mod_dir = mod_dir
end

local function lib(name)
    local obj = StaticFindObject(LIB[name])
    if not obj or not obj:IsValid() then error("library object not found: " .. LIB[name]) end
    return obj
end

local function unwrap(param)
    local ok, v = pcall(function() return param:get() end)
    if not ok then return "?" end
    if type(v) == "userdata" then
        local s = pcall(function() return v:ToString() end) and v:ToString() or nil
        if s then return s end
        local okn, n = pcall(function() return v:GetFullName() end)
        return okn and n or tostring(v)
    end
    return v
end

function probe.register_hooks()
    local registered = 0
    for _, fn in ipairs(HOOKS) do
        local short = fn:match(":(.+)$")
        local cls = fn:match("%.([^.:]+):")
        local ok, err = pcall(RegisterHook, fn, function(ctx, ...)
            local args = {}
            for i, p in ipairs({ ... }) do args[i] = tostring(unwrap(p)) end
            log.info("HOOK %s.%s(%s)", cls, short, table.concat(args, ", "))
        end)
        if ok then
            registered = registered + 1
        else
            log.warn("Hook not registered: %s (%s)", fn, tostring(err))
        end
    end
    log.info("Registered %d/%d probe hooks", registered, #HOOKS)
end

local function call(libname, fname, ...)
    local o = lib(libname)
    local ok, res = pcall(function(...) return o[fname](o, ...) end, ...)
    if not ok then
        log.warn("%s:%s failed: %s", libname, fname, tostring(res))
        return nil
    end
    return res
end

function probe.state()
    log.info("STATE money=%s chapter=%s mapId=%s ownedVisions=%s",
        tostring(call("player", "GetCurrentMoney")),
        tostring(call("scenario", "GetCurrentChapter")),
        tostring(call("map", "GetMapId")),
        tostring(call("vision", "GetOwnedVisionNum")))

    local saves = FindAllOf("CPP_MuchaGameSaveData")
    if not saves or #saves == 0 then
        log.warn("No live CPP_MuchaGameSaveData instance")
        return
    end
    local out = {}
    for i, s in ipairs(saves) do
        out[i] = { path = s:GetFullName(), properties = reflect.object_to_table(s, 0) }
    end
    local path = fs.join(probe.mod_dir, "dumps", "savedata_" .. os.date("%Y%m%d_%H%M%S") .. ".json")
    local ok, err = fs.write_atomic(path, json.encode(out, true))
    if ok then log.info("Wrote %s", path) else log.error("savedata write failed: %s", tostring(err)) end
end

function probe.test_grant()
    local dt = StaticFindObject(CONSUMABLES_TABLE)
    if not dt or not dt:IsValid() then error("DataTable not found: " .. CONSUMABLES_TABLE) end
    local row = dt:FindRow(POTION_ROW)
    if not row then error("row not found: " .. POTION_ROW) end
    local id = row.ID
    log.info("TEST GRANT: Potion row ID=%s", tostring(id))
    local before = call("item", "GetInventoryItemNum", id)
    call("inventory", "AddInventory", id, 1)
    local after = call("item", "GetInventoryItemNum", id)
    log.info("TEST GRANT: Potion count %s -> %s (%s)", tostring(before), tostring(after),
        (tonumber(after) and tonumber(before) and tonumber(after) == tonumber(before) + 1) and "OK" or "UNEXPECTED")
end

function probe.notify_test()
    local d = lib("dialog")
    local active = call("dialog", "IsDialogActive")
    log.info("NOTIFY TEST: IsDialogActive=%s", tostring(active))
    local items = { { ID = 1, Num = 1, Text = FText("Archipelago: Potion from Other") } }
    local ok, err = pcall(function() d:OpenItemObtainDialog(items) end)
    log.info("NOTIFY TEST: OpenItemObtainDialog(Lua table) -> %s %s", ok and "returned" or "FAILED", ok and "" or tostring(err))
end

return probe
