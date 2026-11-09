--[[
  In-game notification of received items using the game's own "You obtained the following" dialog
  (CPP_BFL_Dialog:OpenItemObtainDialog(TArray<FItemSet>)), verified 2026-11-08 to accept a Lua table.
  FItemSet.Text is ignored by the dialog, so only item names (localized by the game) can be shown;
  Gil has no item id and is not shown.

  The dialog only opens when the game is idle in the field (game/gamestate.lua); items wait in
  a queue until then.
  Disable with config/notifications.txt containing "off".
]]

local fs = require("util.fs")
local log = require("util.log")
local gamestate = require("game.gamestate")

local notify = { queue = {}, enabled = true, broken = false }

local LIB_DIALOG = "/Script/mucha.Default__CPP_BFL_Dialog"
local MAX_PER_DIALOG = 10

function notify.init(mod_dir)
    local cfg = fs.read_all(fs.join(mod_dir, "config", "notifications.txt"))
    if cfg and cfg:match("^%s*off") then notify.enabled = false end
    log.info("Item notifications: %s", notify.enabled and "on" or "off")
end

function notify.push(item_id, num)
    if notify.enabled and not notify.broken then
        notify.queue[#notify.queue + 1] = { ID = item_id, Num = num }
    end
end

local function obj(path)
    local o = StaticFindObject(path)
    if not o or not o:IsValid() then error("not found: " .. path) end
    return o
end

--- Called from the runtime tick when the player is in the field.
function notify.flush()
    if #notify.queue == 0 or notify.broken then return end
    local ok, idle = pcall(gamestate.idle)
    if not ok then
        notify.broken = true
        notify.queue = {}
        log.error("Item notifications disabled: game state check failed (%s)", tostring(idle))
        return
    end
    if not idle then return end
    local batch = {}
    for i = 1, math.min(#notify.queue, MAX_PER_DIALOG) do
        local e = table.remove(notify.queue, 1)
        batch[i] = { ID = e.ID, Num = e.Num, Text = FText("") }
    end
    local dok, err = pcall(function() obj(LIB_DIALOG):OpenItemObtainDialog(batch) end)
    if dok then
        log.info("Notification shown for %d received item(s)", #batch)
    else
        notify.broken = true
        notify.queue = {}
        log.error("Item notifications disabled: OpenItemObtainDialog failed (%s)", tostring(err))
    end
end

return notify
