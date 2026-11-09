--[[
  Battle state and the DeathLink party wipe (TD-030). Game-specific; every call may raise, so callers
  wrap it in pcall.

    UCPP_UI_BattleSubsystem.bDuringBattle            in battle
    UCPP_BtlManager.m_pUnitManager.m_UnitList        all battle units (ACPP_BtlUnit)
    ACPP_BtlUnit.m_pUnitParameter                    GetRelation() (1 = Friendlies, 2 = Enemies), IsDead()
    ACPP_BtlUnit.m_pAI                               UCPP_BtlUnitAI:ActivateSkill(skillId, targets, doCalcOrder, isAddHead)

  Party wipe: a living enemy is made to use skill 503140 "Execution" (DT_SkillData: all targets,
  effect 1357 = instant death ignoring resistance, accuracy 300) on every living ally. The skill
  resolves through the game's own battle flow, so the result is the normal game-over screen.
  Rejected (tested in game 2026-11-09): CPP_DBG_BFL_Unit:DBG_ForceDeathInUnitDM does nothing in the
  shipping build; CPP_BFL_Unit:AddPlayableUnitHitPoint changes the party's saved HP, not the battle units.
]]

local battle = {}

local RELATION_FRIENDLIES = 1
local RELATION_ENEMIES = 2
local SKILL_EXECUTION = 503140

local function valid(o)
    return o ~= nil and o:IsValid()
end

--- True while a battle is running.
function battle.in_battle()
    local ui = FindFirstOf("CPP_UI_BattleSubsystem")
    if not valid(ui) then return false end
    return ui.bDuringBattle == true
end

--- Battle units with the given relation: list of { unit = ACPP_BtlUnit, param = UCPP_BtlUnitParameter }.
function battle.units(relation, alive_only)
    local mgr = FindFirstOf("CPP_BtlManager")
    if not valid(mgr) then error("CPP_BtlManager not found") end
    local units = mgr.m_pUnitManager
    if not valid(units) then error("CPP_BtlManager.m_pUnitManager not set") end
    local out = {}
    units.m_UnitList:ForEach(function(_, elem)
        local unit = elem:get()
        if valid(unit) then
            local param = unit.m_pUnitParameter
            if valid(param) and param:GetRelation() == relation and not (alive_only and param:IsDead()) then
                out[#out + 1] = { unit = unit, param = param }
            end
        end
    end)
    return out
end

--- Count living allies (for logging and checks).
function battle.allies_alive()
    return #battle.units(RELATION_FRIENDLIES, true)
end

--- Ask a living enemy to use "Execution" on every living ally.
--- Returns true + description, or false + reason. "not ready" reasons can be retried later.
function battle.kill_party()
    local allies = battle.units(RELATION_FRIENDLIES, true)
    if #allies == 0 then return false, "not ready: no living ally" end
    local enemies = battle.units(RELATION_ENEMIES, true)
    local caster
    for _, e in ipairs(enemies) do
        if valid(e.unit.m_pAI) then caster = e; break end
    end
    if not caster then return false, "not ready: no living enemy with an AI" end
    local targets = {}
    for i, a in ipairs(allies) do targets[i] = a.unit end
    caster.unit.m_pAI:ActivateSkill(SKILL_EXECUTION, targets, true, true)
    return true, string.format("enemy %s uses skill %d on %d allies", caster.unit:GetFName():ToString(),
        SKILL_EXECUTION, #allies)
end

return battle
