--[[
  In-game Archipelago messages (TD-035): history for the pause-menu list and the queue of the
  top-right popups. Pure Lua (no UE4SS); unit-tested in tests/lua/run_tests.lua.

  Every message has a key. A key already seen is ignored, so a save reload that replays items,
  or a bridge state read twice, never shows a message again. Received items also carry their
  AP index: indices up to the highest one seen are ignored even after their entry left the
  history (cap 100).

  Popups: at most `max_visible` at once, newest first; each one is shown for `duration` seconds
  from the moment it appears, then fades out over the last `fade` seconds. Messages arriving while
  all slots are taken wait in a queue (capped; the oldest waiting ones are dropped from the popups,
  never from the history). Time is supplied by the caller (`now`, seconds, any monotonic origin).
]]

local Messages = {}
Messages.__index = Messages

Messages.KINDS = { item = true, gil = true, zone = true, shop = true, death = true, goal = true, hint = true, chat = true }

local DEFAULTS = { max_history = 100, max_visible = 4, duration = 5, fade = 0.5, max_queue = 30 }

function Messages.new(opts)
    local self = setmetatable({}, Messages)
    for k, v in pairs(DEFAULTS) do self[k] = (opts and opts[k]) or v end
    self.history = {}   -- oldest first: { key, kind, text, t }
    self.keys = {}
    self.item_max = -1  -- highest received-item index recorded
    self.queue = {}     -- waiting popups (entries)
    self.active = {}    -- shown popups, oldest first: { entry, shown_at }
    self.version = 0    -- increases on every history change (UI refresh, saving)
    return self
end

--- Record a message. opts.history_only: no popup; opts.item_index: AP received-item index;
--- opts.t: wall-clock time (os.time()) shown in the list. Returns true if it was new.
function Messages:add(kind, text, key, opts)
    opts = opts or {}
    if not Messages.KINDS[kind] or type(text) ~= "string" or text == "" or type(key) ~= "string" then return false end
    if self.keys[key] then return false end
    local idx = opts.item_index
    if idx ~= nil and idx <= self.item_max then return false end
    local entry = { key = key, kind = kind, text = text, t = opts.t or os.time() }
    self.history[#self.history + 1] = entry
    self.keys[key] = true
    if idx ~= nil then self.item_max = idx end
    while #self.history > self.max_history do
        local old = table.remove(self.history, 1)
        self.keys[old.key] = nil
    end
    self.version = self.version + 1
    if not opts.history_only then
        self.queue[#self.queue + 1] = entry
        while #self.queue > self.max_queue do table.remove(self.queue, 1) end
    end
    return true
end

--- Popups to display at `now`, newest first: list of { entry, alpha (0..1) }.
function Messages:visible(now)
    local kept = {}
    for _, a in ipairs(self.active) do
        if now - a.shown_at < self.duration then kept[#kept + 1] = a end
    end
    self.active = kept
    while #self.active < self.max_visible and #self.queue > 0 do
        self.active[#self.active + 1] = { entry = table.remove(self.queue, 1), shown_at = now }
    end
    local out = {}
    for i = #self.active, 1, -1 do
        local a = self.active[i]
        local left = self.duration - (now - a.shown_at)
        out[#out + 1] = { entry = a.entry, alpha = math.max(0, math.min(1, left / self.fade)) }
    end
    return out
end

--- Drop every popup (shown or waiting); the history is unchanged.
function Messages:clear_popups()
    self.queue, self.active = {}, {}
end

--- The `n` most recent history entries, newest first.
function Messages:recent(n)
    local out = {}
    for i = #self.history, math.max(1, #self.history - n + 1), -1 do out[#out + 1] = self.history[i] end
    return out
end

-- Persistence ---------------------------------------------------------------

function Messages:to_table()
    return { version = 1, item_max = self.item_max, history = self.history }
end

--- Restore a saved history (no popups). Invalid entries are skipped; a wrong shape gives an
--- empty history.
function Messages:load_table(t)
    self.history, self.keys, self.item_max = {}, {}, -1
    self:clear_popups()
    if type(t) ~= "table" or t.version ~= 1 or type(t.history) ~= "table" then return false end
    if type(t.item_max) == "number" then self.item_max = t.item_max end
    for _, e in ipairs(t.history) do
        if type(e) == "table" and Messages.KINDS[e.kind] and type(e.text) == "string" and type(e.key) == "string"
            and type(e.t) == "number" and not self.keys[e.key] then
            self.history[#self.history + 1] = { key = e.key, kind = e.kind, text = e.text, t = e.t }
            self.keys[e.key] = true
        end
    end
    while #self.history > self.max_history do
        self.keys[table.remove(self.history, 1).key] = nil
    end
    self.version = self.version + 1
    return true
end

-- Layout --------------------------------------------------------------------

--- Rows of height `row_h` that fit in `available_h` below a header of `header_h` (at least 1).
function Messages.fit_count(available_h, row_h, header_h)
    if type(available_h) ~= "number" or type(row_h) ~= "number" or row_h <= 0 then return 1 end
    return math.max(1, math.floor((available_h - (header_h or 0)) / row_h))
end

-- Text ----------------------------------------------------------------------

--- Text of a received item. info: { name, sender, location, own (found in our world), method,
--- zone_name, amount, chain, tier, chapter }.
function Messages.item_text(info)
    local from
    if info.own then
        from = (info.location and info.location ~= "") and (" (" .. info.location .. ")") or ""
    else
        from = " from " .. tostring(info.sender or "?")
    end
    if info.method == "money" then
        return string.format("+%s Gil%s", tostring(info.amount), from)
    elseif info.method == "zone" then
        return string.format("Zone unlocked: %s%s", tostring(info.zone_name), from)
    elseif info.method == "shop_tier" then
        local name = info.name or ("Progressive " .. tostring(info.chain) .. " shop")
        if info.tier and info.chapter then
            return string.format("%s: tier %d (chapter %d gear)%s", name, info.tier, info.chapter, from)
        end
        return name .. from
    end
    if info.own then return string.format("Found %s%s", tostring(info.name), from) end
    return string.format("Received %s%s", tostring(info.name), from)
end

--- Popup/list kind of a received item.
function Messages.item_kind(method)
    if method == "money" then return "gil" end
    if method == "zone" then return "zone" end
    if method == "shop_tier" then return "shop" end
    return "item"
end

--- Display form of a message: internal map codes such as " (Dng_01Gra_40)" or " (Town_01Gra_02)"
--- removed (they are part of some AP location names, TD-016), then cut to `max` characters
--- (UTF-8 aware) with an ellipsis.
function Messages.shorten(text, max)
    local t = tostring(text):gsub("%s*%(%a+_%d+%a*_%d+%)", "")
    if not max then return t end
    if not utf8 then return #t <= max and t or (t:sub(1, max - 3) .. "...") end
    local n = utf8.len(t)
    if not n or n <= max then return t end
    return t:sub(1, utf8.offset(t, max) - 1) .. "\u{2026}"
end

function Messages.death_received_text(source, cause)
    if cause and cause ~= "" then return "DeathLink: " .. cause end
    return "DeathLink: killed by " .. tostring(source or "?")
end

return Messages
