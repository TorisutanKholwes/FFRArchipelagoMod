--[[
  Archipelago session state for the game mod: pure logic, no UE4SS calls (unit-tested offline).

  Item delivery is exactly-once relative to the game's own saves (TD-004, TD-014):
    * applied_index = number of received items (server order) already applied in the current game.
    * On every game SAVE, the current applied_index is recorded under that save's timestamp
      (UCPP_MuchaGameSaveData.Player.SavedDateTime.Ticks).
    * On every game LOAD, applied_index is restored from the entry recorded for the loaded save's
      timestamp, so items received after that save are applied again and items already in the
      save are not. A save the mod has no record of (made before Archipelago, or a new game,
      ticks 0) starts at 0.
  Checked locations are global per seed: a check sent to the server stays checked forever, even if
  an older save is loaded.

  State is persisted through a store object: store.load(key) -> table|nil, store.save(key, table).
]]

local Session = {}
Session.__index = Session

Session.MAX_SAVE_RECORDS = 500

local function sanitize(s)
    return (tostring(s):gsub("[^%w%-_]", "_"))
end

function Session.new(store)
    return setmetatable({ store = store, key = nil, state = nil, loaded = false }, Session)
end

--- Bind to an Archipelago seed + slot. Loads persisted state for it.
--- Returns true if the binding changed.
function Session:bind(seed_name, slot_name)
    local key = sanitize(seed_name) .. "__" .. sanitize(slot_name)
    if self.key == key then return false end
    self.key = key
    local st = self.store.load(key)
    if type(st) ~= "table" then
        st = {}
    end
    st.seed_name = seed_name
    st.slot_name = slot_name
    st.saves = st.saves or {}          -- [tostring(ticks)] = { applied_index = n, slot = s }
    st.checked = st.checked or {}      -- [tostring(location_id)] = true
    st.applied_index = st.applied_index or 0
    st.current_ticks = st.current_ticks
    self.state = st
    -- The game must report a load before items are applied in this process.
    self.loaded = false
    return true
end

function Session:is_bound()
    return self.state ~= nil
end

function Session:persist()
    if self.state then self.store.save(self.key, self.state) end
end

--- The game just loaded the save with timestamp `ticks` (0 = new game / unsaved).
--- Returns the restored applied_index and whether the save was known.
function Session:on_loaded(ticks)
    local st = self.state
    local rec = st.saves[tostring(ticks)]
    st.applied_index = rec and rec.applied_index or 0
    st.current_ticks = ticks
    self.loaded = true
    self:persist()
    return st.applied_index, rec ~= nil
end

--- The game just wrote a save with timestamp `ticks` into `slot` (slot may be nil).
function Session:on_saved(ticks, slot)
    local st = self.state
    st.saves[tostring(ticks)] = { applied_index = st.applied_index, slot = slot }
    st.current_ticks = ticks
    self:prune()
    self:persist()
end

function Session:prune()
    local keys = {}
    for k in pairs(self.state.saves) do keys[#keys + 1] = k end
    if #keys <= Session.MAX_SAVE_RECORDS then return end
    table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
    for i = 1, #keys - Session.MAX_SAVE_RECORDS do self.state.saves[keys[i]] = nil end
end

--- Items (from the server-ordered list `received`, 1-based Lua array) still to apply.
--- Returns an array of { index = n (1-based position), item = entry }.
function Session:pending_items(received)
    local out = {}
    if not self.loaded then return out end
    for i = self.state.applied_index + 1, #received do
        out[#out + 1] = { index = i, item = received[i] }
    end
    return out
end

--- Record that the item at 1-based position `index` was applied in game.
function Session:mark_applied(index)
    local st = self.state
    if index ~= st.applied_index + 1 then
        error(string.format("items must be applied in order: expected %d, got %d", st.applied_index + 1, index))
    end
    st.applied_index = index
    self:persist()
end

--- Mark a location as checked. Returns true if it was new.
function Session:add_checked(location_id)
    local k = tostring(location_id)
    if self.state.checked[k] then return false end
    self.state.checked[k] = true
    self:persist()
    return true
end

--- Latch the goal for this seed (story completion never un-happens). Returns true if new.
function Session:set_goal()
    if self.state.goal then return false end
    self.state.goal = true
    self:persist()
    return true
end

function Session:checked_list()
    local out = {}
    for k in pairs(self.state.checked) do out[#out + 1] = math.tointeger(tonumber(k)) end
    table.sort(out)
    return out
end

return Session
