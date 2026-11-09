--[[
  DeathLink state (TD-030). Pure logic, no game calls (tested in tests/lua/run_tests.lua).

  Incoming: the bridge lists deaths received from other players in bridge_state.json
  ("death_link" = { enabled, session, deaths = [{id, source, cause}] }). Ids restart with every bridge
  run, which changes "session". Only live deaths apply:
    * the first state the mod sees is a baseline (the file may be left over from an earlier run);
    * after a bridge restart (new session seen while the mod runs) every death of the new session is new.
  Several deaths received before the party could be killed collapse into one pending wipe.
  A death received outside battle stays pending until the next battle starts.

  Outgoing: every game over increments `count` (in memory only, so a restarted game starts at 0);
  the bridge sends one Bounce per increment. The game over caused by a received death is not counted,
  so deaths are never echoed back. The game only checks for a wipe after the next action, which can
  be minutes later (verified 2026-11-09), so the suppression lasts until that game over or until the
  battle is over (battle_over), not for a fixed time.
]]

local DeathLink = {}
DeathLink.__index = DeathLink

function DeathLink.new()
    return setmetatable({
        enabled = false,
        session = nil,
        last_seen = 0,
        pending = nil,        -- the newest death not applied yet
        count = 0,
        last_time = nil,
        suppress = false,     -- the next game over was caused by a received death
    }, DeathLink)
end

--- Read the bridge's "death_link" table. Returns the list of newly received deaths.
function DeathLink:on_bridge(dl)
    if type(dl) ~= "table" or dl.enabled ~= true then
        if self.pending then self.pending = nil end
        self.enabled = false
        if type(dl) == "table" and dl.session ~= nil then self:_advance(dl) end
        return {}
    end
    self.enabled = true
    return self:_advance(dl)
end

function DeathLink:_advance(dl)
    local deaths = type(dl.deaths) == "table" and dl.deaths or {}
    if dl.session ~= self.session then
        local first = self.session == nil
        self.session = dl.session
        self.last_seen = 0
        if first then
            for _, d in ipairs(deaths) do
                if type(d.id) == "number" and d.id > self.last_seen then self.last_seen = d.id end
            end
            return {}
        end
    end
    local new = {}
    for _, d in ipairs(deaths) do
        if type(d.id) == "number" and d.id > self.last_seen then new[#new + 1] = d end
    end
    for _, d in ipairs(new) do
        if d.id > self.last_seen then self.last_seen = d.id end
    end
    if #new > 0 and self.enabled then self.pending = new[#new] end
    return self.enabled and new or {}
end

--- True when a pending death should be applied now.
function DeathLink:should_kill(in_battle)
    return self.enabled and self.pending ~= nil and in_battle == true
end

--- The party was killed for the pending death: clear it and ignore the resulting game over.
function DeathLink:on_killed()
    self.pending = nil
    self.suppress = true
end

--- The battle of a forced wipe ended without a game over: stop suppressing. Returns true if it was active.
function DeathLink:battle_over()
    local was = self.suppress
    self.suppress = false
    return was
end

--- Forget a pending death without applying it (title screen, kill impossible).
function DeathLink:drop_pending()
    local p = self.pending
    self.pending = nil
    return p
end

--- A game over started. Returns true if it is a real death to report.
function DeathLink:on_game_over(now)
    if self.suppress then
        self.suppress = false
        return false
    end
    self.count = self.count + 1
    self.last_time = now
    return true
end

--- The "deaths" table written to game_state.json.
function DeathLink:report()
    return { count = self.count, last_time = self.last_time }
end

return DeathLink
