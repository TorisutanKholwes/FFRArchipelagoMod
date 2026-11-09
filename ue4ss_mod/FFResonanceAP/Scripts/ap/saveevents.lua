--[[
  Classifies save-object events as SAVE or LOAD (pure logic, unit-tested). Evidence: TD-015.

    reason "object replaced"  -> LOAD  (the game builds a new save object when loading in game;
                                        verified: reloading slot 2 replaced the object)
    reason "timestamp" while no game is loaded (title screen / fresh process)
                              -> LOAD  (load from the title screen)
    reason "timestamp" while a game is loaded
                              -> SAVE  (manual save: ApplySaveGameData(slot) hook fired just
                                        before; autosave: no hook, slot reported as "auto")
]]

local SaveEvents = {}
SaveEvents.__index = SaveEvents

SaveEvents.HOOK_WINDOW = 10 -- seconds between the ApplySaveGameData hook and the timestamp change

function SaveEvents.new(clock)
    return setmetatable({ clock = clock or os.time, save_hook_at = nil, save_slot = nil }, SaveEvents)
end

function SaveEvents:on_save_hook(slot)
    self.save_hook_at = self.clock()
    self.save_slot = slot
end

--- Returns "save", slot  or  "load", nil.
function SaveEvents:classify(reason, game_loaded)
    local hook_recent = self.save_hook_at ~= nil and self.clock() - self.save_hook_at <= SaveEvents.HOOK_WINDOW
    local slot = hook_recent and self.save_slot or "auto"
    self.save_hook_at, self.save_slot = nil, nil
    if reason == "object replaced" or not game_loaded then
        return "load", nil
    end
    return "save", slot
end

return SaveEvents
