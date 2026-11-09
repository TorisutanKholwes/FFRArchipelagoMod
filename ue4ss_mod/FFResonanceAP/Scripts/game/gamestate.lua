--[[
  "Is the game idle in the field?" (TD-017, TD-018). True when the player character is controllable
  and nothing modal is running:
    not CPP_BFL_TalkEvent:IsPlayingEvent()        (cutscenes / talk events)
    not CPP_BFL_Dialog:IsDialogActive()           (game dialogs)
    not CPP_MainMenuSubsystem:IsOpenMenu()        (main menu)
    CPP_MapUnit_Playable:IsEnableUnitInput()      (player can move; false in battles/transitions)
  Raises an error if one of these objects/functions is unavailable, so callers can decide on a
  fallback instead of silently assuming a state.
]]

local gamestate = {}

local LIB_DIALOG = "/Script/mucha.Default__CPP_BFL_Dialog"
local LIB_TALK = "/Script/mucha.Default__CPP_BFL_TalkEvent"

local function obj(path)
    local o = StaticFindObject(path)
    if not o or not o:IsValid() then error("not found: " .. path) end
    return o
end

--- Returns idle (bool), reason (string when not idle).
function gamestate.idle()
    if obj(LIB_TALK):IsPlayingEvent() then return false, "event" end
    if obj(LIB_DIALOG):IsDialogActive() then return false, "dialog" end
    local menu = FindFirstOf("CPP_MainMenuSubsystem")
    if menu and menu:IsValid() and menu:IsOpenMenu() then return false, "menu" end
    local unit = FindFirstOf("CPP_MapUnit_Playable")
    if not unit or not unit:IsValid() then return false, "no player unit" end
    if not unit:IsEnableUnitInput() then return false, "player input disabled" end
    return true
end

return gamestate
