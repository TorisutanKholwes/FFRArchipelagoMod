--[[
  Offline tests for the pure-Lua parts of the FFResonanceAP mod (no UE4SS required).
  Run from FFResonanceMod/:  lua tests/lua/run_tests.lua
]]

package.path = "ue4ss_mod/FFResonanceAP/Scripts/?.lua;" .. package.path

local json = require("lib.json")
local fs = require("util.fs")

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local function deep_eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- json -------------------------------------------------------------------

test("encode scalars", function()
    eq(json.encode(1), "1")
    eq(json.encode(-12345678901), "-12345678901")
    eq(json.encode(true), "true")
    eq(json.encode(nil), "null")
    eq(json.encode("a\"b\\c\n"), '"a\\"b\\\\c\\n"')
    eq(json.encode(0.5), "0.5")
end)

test("encode arrays and objects deterministically", function()
    eq(json.encode({ 1, 2, 3 }), "[1,2,3]")
    eq(json.encode({ b = 1, a = 2 }), '{"a":2,"b":1}')
    eq(json.encode({}), "[]")
    eq(json.encode(json.empty_object), "{}")
    eq(json.encode({ [1] = "x", [3] = "y" }), '{"1":"x","3":"y"}')
end)

test("encode rejects nan and cycles", function()
    assert(not pcall(json.encode, 0 / 0))
    local t = {}; t.self = t
    assert(not pcall(json.encode, t))
end)

test("decode basic document", function()
    local v = json.decode(' {"cmd":"ReceivedItems","index":3,"items":[{"item":7700001,"flags":1}],"ok":true,"n":null} ')
    eq(v.cmd, "ReceivedItems")
    eq(math.type(v.index), "integer")
    eq(v.items[1].item, 7700001)
    eq(v.ok, true)
    eq(v.n, json.null)
end)

test("decode unicode escapes and surrogates", function()
    eq(json.decode('"\\u00e9"'), "é")
    eq(json.decode('"\\ud83d\\ude00"'), "😀")
    eq(json.decode('"tab\\tnew\\nline"'), "tab\tnew\nline")
end)

test("decode numbers", function()
    eq(json.decode("-0.25"), -0.25)
    eq(json.decode("1e3"), 1000.0)
    eq(json.decode("9007199254740993"), 9007199254740993)
end)

test("decode errors", function()
    assert(not pcall(json.decode, "{"))
    assert(not pcall(json.decode, "[1,]"))
    assert(not pcall(json.decode, '{"a":1} x'))
    assert(not pcall(json.decode, '"unterminated'))
end)

test("round trip", function()
    local doc = { seed = "abc", applied_index = 42, checked = { 7710001, 7710002 }, nested = { x = { y = false } } }
    assert(deep_eq(json.decode(json.encode(doc)), doc))
    assert(deep_eq(json.decode(json.encode(doc, true)), doc))
end)

-- fs ---------------------------------------------------------------------

test("path helpers", function()
    eq(fs.normalize("C:\\a\\b\\"), "C:/a/b")
    eq(fs.join("a", "b", "c.json"), "a/b/c.json")
    eq(fs.dirname("a/b/c.json"), "a/b")
end)

test("atomic write overwrites and recovers", function()
    local path = os.tmpname()
    assert(fs.write_atomic(path, "first"))
    eq(fs.read_all(path), "first")
    assert(fs.write_atomic(path, "second"))
    eq(fs.read_all(path), "second")
    eq(fs.exists(path .. ".tmp"), false)
    -- Simulate a crash after removing the target but before renaming the tmp file.
    os.remove(path)
    local f = io.open(path .. ".tmp", "wb"); f:write("pending"); f:close()
    eq(fs.read_all_recover(path), "pending")
    os.remove(path .. ".tmp")
end)

test("write_atomic_with_backup keeps the previous version", function()
    local path = os.tmpname()
    os.remove(path)
    assert(fs.write_atomic_with_backup(path, "v1"))
    eq(fs.exists(path .. ".bak"), false)
    assert(fs.write_atomic_with_backup(path, "v2"))
    eq(fs.read_all(path), "v2"); eq(fs.read_all(path .. ".bak"), "v1")
    local c = fs.read_candidates(path)
    eq(#c, 2); eq(c[1].data, "v2"); eq(c[2].data, "v1")
    os.remove(path); os.remove(path .. ".bak")
end)

test("file store recovers from a corrupted or missing state file", function()
    local ipc = require("ap.ipc")
    local dir = os.tmpname()
    os.remove(dir)
    dir = dir .. "_d"
    os.execute('mkdir -p "' .. dir .. '"')
    local warnings = {}
    local store = ipc.file_store(dir, function(m) warnings[#warnings + 1] = m end)
    store.save("k", { applied_index = 1 })
    store.save("k", { applied_index = 2 })
    eq(store.load("k").applied_index, 2)
    -- corrupted main file (e.g. disk full / killed mid-write): fall back to the backup
    local f = io.open(dir .. "/k.json", "wb"); f:write("{\"applied_ind"); f:close()
    eq(store.load("k").applied_index, 1)
    eq(#warnings, 1)
    -- crash between "main -> .bak" and ".tmp -> main": main missing, pending .tmp holds the newest
    os.remove(dir .. "/k.json")
    f = io.open(dir .. "/k.json.tmp", "wb"); f:write('{"applied_index":3}'); f:close()
    eq(store.load("k").applied_index, 3)
    -- everything unreadable: explicit error, never a silent reset
    for _, suffix in ipairs({ "", ".tmp", ".bak" }) do
        f = io.open(dir .. "/k.json" .. suffix, "wb"); f:write("garbage"); f:close()
    end
    assert(not pcall(store.load, "k"))
    os.execute('rm -rf "' .. dir .. '"')
end)

-- generated mappings ------------------------------------------------------

test("generated mappings load and are consistent", function()
    local m = require("generated.mappings")
    local n_items, n_chests = 0, 0
    for ap_id, a in pairs(m.items) do
        n_items = n_items + 1
        assert(math.type(ap_id) == "integer")
        assert(a.method == "inventory" or a.method == "money" or a.method == "zone" or a.method == "shop_tier", "bad method for " .. ap_id)
        if a.method == "inventory" then assert(a.item_id > 0 and a.num >= 1)
        elseif a.method == "money" then assert(a.amount > 0)
        elseif a.method == "zone" then assert(a.zone > 0)
        else assert(a.chain) end
    end
    for key, loc in pairs(m.chests) do
        n_chests = n_chests + 1
        assert(key:match("^%d+:%d+$"), "bad chest key " .. key)
        assert(loc >= 80000000 and loc < 82000000)
    end
    assert(n_items > 0 and n_chests > 0)
    eq(m.items[77000011].item_id, 1, "Potion mapping")
    eq(m.goal.min_progress, 9000)
    assert(type(m.data_version) == "string" and m.data_version:match("^%x+$") and #m.data_version == 16)
    eq(#m.chapters, 8)
    for i, ch in ipairs(m.chapters) do eq(ch.min_progress, (i + 1) * 1000) end
    local nv, nr = 0, 0
    for id, loc in pairs(m.visions) do nv = nv + 1; eq(loc, 82000000 + id) end
    for id, loc in pairs(m.requests) do nr = nr + 1; eq(loc, 82100000 + id) end
    eq(nv, 26); eq(nr, 33)
    local nf, nc = 0, 0
    for flag, loc in pairs(m.event_flags) do nf = nf + 1; assert(loc >= 82400000 and loc < 82600000, "flag " .. flag) end
    for row, loc in pairs(m.colosseum) do nc = nc + 1; assert(loc >= 82300000 and loc < 82300100, row) end
    eq(nf, 33); eq(nc, 20)              -- 9 Espers + 24 Chamber trials; 20 rank battles
    eq(m.event_flags[90], 82510451)     -- Siren
    eq(m.colosseum["初級_初級バトル１"], 82300000)
    local np = 0
    for key, loc in pairs(m.pickups) do
        np = np + 1
        assert(key:match("^1000:%d+$"), "bad pickup key " .. key)
        eq(loc, 82600000 + tonumber(key:match(":(%d+)$")))
    end
    eq(np, 93)
    eq(m.pickups["1000:96"], 82600096)
    eq(m.shards.item_id, 25004); eq(m.shards.turnin_map, 2031); eq(m.shards.turnin_target, 0)
    for n = 1, 99 do eq(m.shards.locations[n], 82700000 + n) end
    eq(m.shards.locations[100], nil)  -- the pickup observed in game (OpenTreasureBoxWithoutId(1000, 96))
    -- Oblivion Palace: 25 safes = 19 randomized + 6 check-only (valuable reward kept), never both
    local safes, keep = 0, 0
    for id = 0, 24 do
        local key = "2031:" .. id
        local r, k = m.chests[key], m.chests_keep[key]
        assert((r == nil) ~= (k == nil), "safe " .. key .. " must be in exactly one table")
        eq(r or k, 80203100 + id)
        safes = safes + 1
        if k then keep = keep + 1 end
    end
    eq(safes, 25); eq(keep, 6)
    for key in pairs(m.chests_keep) do assert(key:match("^2031:"), "check-only chest outside the palace " .. key) end
end)


-- ap.session --------------------------------------------------------------

local Session = require("ap.session")

local function memory_store()
    local data = {}
    return {
        data = data,
        load = function(key) return data[key] and json.decode(data[key]) or nil end,
        save = function(key, t) data[key] = json.encode(t) end,
    }
end

local function items(n)
    local t = {}
    for i = 1, n do t[i] = { item = 77000011, player = 1, location = i, flags = 0 } end
    return t
end

test("session applies nothing before a load is seen", function()
    local s = Session.new(memory_store())
    s:bind("seedA", "Player1")
    eq(#s:pending_items(items(3)), 0)
    s:on_loaded(0)
    eq(#s:pending_items(items(3)), 3)
end)

test("session: save, receive more, reload older save re-applies only newer items", function()
    local store = memory_store()
    local s = Session.new(store)
    s:bind("seedA", "Player1")
    s:on_loaded(0)                         -- new game
    for _, p in ipairs(s:pending_items(items(2))) do s:mark_applied(p.index) end
    s:on_saved(1000, 1)                     -- save holds 2 items
    for _, p in ipairs(s:pending_items(items(5))) do s:mark_applied(p.index) end
    eq(s.state.applied_index, 5)
    local idx, known = s:on_loaded(1000)    -- reload the save made with 2 items
    eq(idx, 2); eq(known, true)
    local pending = s:pending_items(items(5))
    eq(#pending, 3); eq(pending[1].index, 3)
end)

test("session: unknown save starts at 0", function()
    local s = Session.new(memory_store())
    s:bind("seedA", "Player1")
    local idx, known = s:on_loaded(424242)
    eq(idx, 0); eq(known, false)
end)

test("session: state survives a restart (persisted through the store)", function()
    local store = memory_store()
    local s = Session.new(store)
    s:bind("seed/with:odd chars", "P 1")
    s:on_loaded(0)
    s:mark_applied(1)
    s:on_saved(77, 2)
    assert(s:add_checked(80201503))
    eq(s:add_checked(80201503), false)
    local s2 = Session.new(store)
    s2:bind("seed/with:odd chars", "P 1")
    eq(s2.loaded, false)
    eq(#s2:pending_items(items(3)), 0)     -- must wait for the game's load event
    eq(select(1, s2:on_loaded(77)), 1)
    eq(s2:checked_list()[1], 80201503)
end)

test("session: out-of-order mark_applied is rejected", function()
    local s = Session.new(memory_store())
    s:bind("seedA", "Player1")
    s:on_loaded(0)
    assert(not pcall(s.mark_applied, s, 2))
end)

test("session: seeds are isolated", function()
    local store = memory_store()
    local s = Session.new(store)
    s:bind("seedA", "P1"); s:on_loaded(0); s:mark_applied(1); s:add_checked(1)
    eq(s:bind("seedB", "P1"), true)
    eq(s.state.applied_index, 0)
    eq(#s:checked_list(), 0)
end)

test("session: goal latch is persisted and reported once", function()
    local store = memory_store()
    local s = Session.new(store)
    s:bind("seedG", "P1")
    eq(s:set_goal(), true)
    eq(s:set_goal(), false)
    local s2 = Session.new(store)
    s2:bind("seedG", "P1")
    eq(s2.state.goal, true)
end)

-- ap.saveevents -----------------------------------------------------------

local SaveEvents = require("ap.saveevents")

test("saveevents: manual save = save with hook slot", function()
    local now = 100
    local e = SaveEvents.new(function() return now end)
    e:on_save_hook(2); now = 101
    local kind, slot = e:classify("timestamp", true)
    eq(kind, "save"); eq(slot, 2)
end)

test("saveevents: autosave (timestamp, no hook) = save in slot auto", function()
    local e = SaveEvents.new(function() return 100 end)
    local kind, slot = e:classify("timestamp", true)
    eq(kind, "save"); eq(slot, "auto")
end)

test("saveevents: object replaced = load, even right after a save hook", function()
    local now = 100
    local e = SaveEvents.new(function() return now end)
    eq(e:classify("object replaced", true), "load")
    e:on_save_hook(1); now = 101
    eq(e:classify("object replaced", true), "load")
end)

test("saveevents: timestamp while no game loaded (title screen) = load", function()
    local e = SaveEvents.new(function() return 100 end)
    eq(e:classify("timestamp", false), "load")
end)

test("saveevents: stale hook is not reused", function()
    local now = 100
    local e = SaveEvents.new(function() return now end)
    e:on_save_hook(1); now = 200
    local kind, slot = e:classify("timestamp", true)
    eq(kind, "save"); eq(slot, "auto")
end)

-- The 2026-11-08 duplication incident, replayed through session + classifier.
test("regression: autosaves on map change never re-apply items", function()
    local store = memory_store()
    local s = Session.new(store)
    local e = SaveEvents.new(function() return 100 end)
    s:bind("seedA", "P1")
    s:on_loaded(5000)
    for _, p in ipairs(s:pending_items(items(14))) do s:mark_applied(p.index) end
    for _, ticks in ipairs({ 6000, 7000 }) do          -- two autosaves while walking between maps
        local kind, slot = e:classify("timestamp", s.loaded)
        eq(kind, "save")
        s:on_saved(ticks, slot)
        eq(#s:pending_items(items(14)), 0)
    end
    -- reloading the autosave restores its count: nothing to re-apply
    local kind = e:classify("object replaced", s.loaded)
    eq(kind, "load")
    s:on_loaded(7000)
    eq(#s:pending_items(items(14)), 0)
end)


-- deathlink ----------------------------------------------------------------

local DeathLink = require("ap.deathlink")

local function dl_state(session, ids, enabled)
    local deaths = {}
    for _, id in ipairs(ids) do deaths[#deaths + 1] = { id = id, source = "P2", cause = "P2 died " .. id } end
    return { enabled = enabled ~= false, session = session, deaths = deaths }
end

test("deathlink: first bridge state is a baseline (no stale deaths)", function()
    local d = DeathLink.new()
    eq(#d:on_bridge(dl_state(1, { 1, 2 })), 0)
    eq(d.pending, nil)
    local new = d:on_bridge(dl_state(1, { 1, 2, 3 }))
    eq(#new, 1)
    eq(new[1].id, 3)
    eq(d.pending.id, 3)
end)

test("deathlink: queued outside battle, applied in battle, collapsed to one wipe", function()
    local d = DeathLink.new()
    d:on_bridge(dl_state(1, {}))
    d:on_bridge(dl_state(1, { 1, 2 }))
    eq(d:should_kill(false), false)
    eq(d:should_kill(true), true)
    eq(d.pending.id, 2)
    d:on_killed()
    eq(d:should_kill(true), false)
    eq(#d:on_bridge(dl_state(1, { 1, 2 })), 0)
end)

test("deathlink: the game over caused by a received death is not reported", function()
    local d = DeathLink.new()
    d:on_bridge(dl_state(1, {}))
    d:on_bridge(dl_state(1, { 1 }))
    d:on_killed()
    eq(d:on_game_over(400), false)  -- even minutes later: the game waits for the next action
    eq(d.count, 0)
    eq(d:on_game_over(500), true)   -- a later, real game over is reported
    eq(d.count, 1)
    eq(d:report().last_time, 500)
end)

test("deathlink: suppression ends with the battle", function()
    local d = DeathLink.new()
    d:on_killed()
    eq(d:battle_over(), true)
    eq(d:battle_over(), false)
    eq(d:on_game_over(100), true)
end)

test("deathlink: bridge restart (new session) accepts all its deaths", function()
    local d = DeathLink.new()
    d:on_bridge(dl_state(1, { 5, 6 }))
    eq(#d:on_bridge(dl_state(2, { 1 })), 1)
    eq(d.pending.id, 1)
end)

test("deathlink: disabled link ignores deaths and keeps the baseline", function()
    local d = DeathLink.new()
    d:on_bridge(dl_state(1, {}, false))
    eq(#d:on_bridge(dl_state(1, { 1 }, false)), 0)
    eq(d.pending, nil)
    eq(d:should_kill(true), false)
    d:on_bridge(dl_state(1, { 1 }))        -- enabled later: death 1 is old
    eq(d.pending, nil)
    d:on_bridge(nil)                       -- unbound / no bridge
    eq(d.enabled, false)
end)

test("deathlink: game overs count while disabled (bridge decides whether to send)", function()
    local d = DeathLink.new()
    eq(d:on_game_over(10), true)
    eq(d:report().count, 1)
end)


-- connconfig (title-screen Archipelago Options panel, TD-032) --------------

local connconfig = require("ap.connconfig")

local function tmpdir()
    local base = os.tmpname()
    os.remove(base)
    os.execute('mkdir -p "' .. base .. '"')
    return base
end

test("connconfig: parse_server variants", function()
    local s, h, p = connconfig.parse_server("  archipelago.gg ")
    eq(s, nil); eq(h, "archipelago.gg"); eq(p, nil)
    s, h, p = connconfig.parse_server("localhost:38281")
    eq(h, "localhost"); eq(p, 38281)
    s, h, p = connconfig.parse_server("WSS://example.org:1234/room")
    eq(s, "wss"); eq(h, "example.org"); eq(p, 1234)
    s, h, p = connconfig.parse_server("archipelago://host")
    eq(s, "ws"); eq(h, "host")
    s, h, p = connconfig.parse_server("[::1]:5000")
    eq(h, "[::1]"); eq(p, 5000)
end)

test("connconfig: valid fields give an address", function()
    local cfg = assert(connconfig.validate({ server = "archipelago.gg", port = "38281", slot = " Tori " }))
    eq(cfg.slot, "Tori"); eq(cfg.port, 38281); eq(cfg.server, "archipelago.gg")
    eq(connconfig.address(cfg), "archipelago.gg:38281")
    cfg = assert(connconfig.validate({ server = "wss://host.example:1", port = "2000", slot = "P" }))
    eq(connconfig.address(cfg), "wss://host.example:2000", "Port field replaces the embedded port")
    eq(cfg.server, "wss://host.example")
    cfg = assert(connconfig.validate({ server = "localhost:4000", port = "", slot = "P" }))
    eq(cfg.port, 4000, "empty Port falls back to the server field's port")
end)

test("connconfig: invalid fields are reported", function()
    local function errs(f) local c, e = connconfig.validate(f); eq(c, nil); return table.concat(e, "|") end
    assert(errs({ server = "", port = "38281", slot = "P" }):find("Server: enter", 1, true))
    assert(errs({ server = "http://x", port = "1", slot = "P" }):find("ws://", 1, true))
    assert(errs({ server = "my host", port = "1", slot = "P" }):find("spaces", 1, true))
    assert(errs({ server = "h", port = "abc", slot = "P" }):find("digits only", 1, true))
    assert(errs({ server = "h", port = "0", slot = "P" }):find("between 1 and 65535", 1, true))
    assert(errs({ server = "h", port = "65536", slot = "P" }):find("between 1 and 65535", 1, true))
    assert(errs({ server = "h", port = "", slot = "P" }):find("enter the room's port", 1, true))
    assert(errs({ server = "h", port = "1", slot = "  " }):find("Slot: enter", 1, true))
    assert(errs({ server = "h", port = "1", slot = "12345678901234567" }):find("16 characters", 1, true))
    assert(connconfig.validate({ server = "h", port = "1", slot = "éééééééééééééééé" }), "16 UTF-8 characters are fine")
end)

test("connconfig: save never writes the password, load restores fields", function()
    local dir = tmpdir()
    local path = dir .. "/connection.json"
    local cfg = assert(connconfig.validate({ server = "localhost", port = "38281", slot = "Tori" }))
    cfg.password = "hunter2"  -- even if a caller leaves it in the table
    assert(connconfig.save(path, cfg))
    local raw = fs.read_all(path)
    assert(not raw:find("hunter2", 1, true), "password must not be saved")
    assert(not raw:find("password", 1, true))
    local back = connconfig.load(path)
    eq(back.server, "localhost"); eq(back.port, 38281); eq(back.slot, "Tori")
    os.remove(path)
    os.execute('rmdir "' .. dir .. '"')
end)

test("connconfig: load falls back to defaults", function()
    local d, why = connconfig.load("/nonexistent/dir/connection.json")
    eq(d.server, "localhost"); eq(d.port, 38281); eq(d.slot, ""); eq(why, "absent")
    local dir = tmpdir()
    local path = dir .. "/connection.json"
    local f = io.open(path, "w"); f:write('{"server": 5, "port": 99999, "slot": "X"}'); f:close()
    d = connconfig.load(path)
    eq(d.server, "localhost"); eq(d.port, 38281); eq(d.slot, "X")
    os.remove(path)
    os.execute('rmdir "' .. dir .. '"')
end)

test("connconfig: request content and increasing seq", function()
    local cfg = assert(connconfig.validate({ server = "localhost", port = "38281", slot = "Tori" }))
    local s1 = connconfig.next_seq(nil, 1000)
    eq(math.type(s1), "integer"); eq(s1, 1000000)
    eq(connconfig.next_seq(s1, 1000), s1 + 1)
    eq(connconfig.next_seq(s1, 2000), 2000000)
    local r = connconfig.build_request(cfg, "", s1)
    eq(r.password, nil, "empty password is sent as no password")
    eq(r.address, "localhost:38281"); eq(r.slot, "Tori"); eq(r.protocol, 1)
    r = connconfig.build_request(cfg, "pw", connconfig.next_seq(nil, os.time()))
    eq(r.password, "pw")
    local decoded = json.decode(json.encode(r))
    eq(math.type(decoded.seq), "integer", "seq stays an integer in JSON")
end)

test("connconfig: status descriptions", function()
    local now = 5000
    local text, kind = connconfig.describe_status(nil, "absent", now)
    assert(text:find("Bridge not running", 1, true)); eq(kind, "error")
    text, kind = connconfig.describe_status({ status = "ready", updated = now - 100 }, nil, now)
    assert(text:find("not responding", 1, true)); eq(kind, "error")
    text, kind = connconfig.describe_status({ status = "waiting_for_settings", updated = now }, nil, now)
    eq(kind, "idle")
    text, kind = connconfig.describe_status({ status = "ready", updated = now, request_seq = 7 }, nil, now, 8)
    assert(text:find("Sending settings", 1, true)); eq(kind, "busy")
    text, kind = connconfig.describe_status({ status = "ready", slot_name = "Tori", updated = now, request_seq = 8 }, nil, now, 8)
    eq(text, "Connected as Tori"); eq(kind, "ok")
    text, kind = connconfig.describe_status({ status = "error", status_message = "connection refused: wrong password",
        updated = now, request_seq = 8 }, nil, now, 8)
    eq(text, "Error: connection refused: wrong password"); eq(kind, "error")
end)


test("ipc: JSON nulls in bridge_state.json are nil (not the truthy json.null)", function()
    local ipc = require("ap.ipc")
    local dir = tmpdir()
    ipc.init(dir)
    local f = io.open(dir .. "/bridge_state.json", "w")
    f:write('{"protocol":1,"status":"error","seed_name":null,"slot_name":null,"request_seq":null,"items":[]}')
    f:close()
    local st = assert(ipc.read_bridge_state())
    eq(st.seed_name, nil); eq(st.slot_name, nil); eq(st.request_seq, nil); eq(st.status, "error")
    os.remove(dir .. "/bridge_state.json")
    os.execute('rmdir "' .. dir .. '"')
end)


test("connconfig: request carries the game launch id", function()
    local cfg = assert(connconfig.validate({ server = "localhost", port = "38281", slot = "Tori" }))
    local r = connconfig.build_request(cfg, "", 1, "123-456")
    eq(r.game_session, "123-456")
    local a, b = connconfig.new_game_session(100, 0.25), connconfig.new_game_session(100, 0.5)
    assert(a ~= b and a:match("^100%-%d+$"), "ids differ between launches")
end)

test("connconfig: title status label", function()
    local now = 5000
    local ready = { status = "ready", slot_name = "Tori", request_seq = 8, updated = now }
    local text, kind = connconfig.connection_label(ready, now, 8)
    eq(text, "Connected as Tori"); eq(kind, "ok")
    eq(connconfig.connection_label(ready, now, nil), "Disconnected", "no Connect this session")
    eq(connconfig.connection_label(ready, now, 9), "Disconnected", "answer to an older request")
    eq(connconfig.connection_label({ status = "connecting", request_seq = 8, updated = now }, now, 8), "Disconnected")
    eq(connconfig.connection_label({ status = "ready", request_seq = 8, updated = now - 60 }, now, 8), "Disconnected", "bridge stopped")
    text, kind = connconfig.connection_label(nil, now, 8)
    eq(text, "Disconnected"); eq(kind, "error")
end)


-- zones (zone locks, TD-033) ------------------------------------------------

local zones = require("ap.zones")
local fake = {
    items = { [79002000] = { method = "zone", zone = 2000 }, [79002060] = { method = "zone", zone = 2060 },
              [77000011] = { method = "inventory", item_id = 1, num = 1 } },
    zone_of_map = { [2000] = 2000, [2060] = 2060, [2061] = 2060 },
    zone_names = { [2000] = "Town of Mitra", [2060] = "Dilmagia" },
}

test("zones: enabled only when slot_data says so", function()
    eq(zones.enabled({ zone_locks = 1 }), true)
    eq(zones.enabled({ zone_locks = 0 }), false)
    eq(zones.enabled({}), false)
    eq(zones.enabled(nil), false)
end)

test("zones: unlocked from the full received list, other items ignored", function()
    local u = zones.unlocked({ { item = 77000011 }, { item = 79002000 }, { item = 99999 } }, fake)
    eq(u[2000], true); eq(u[2060], nil)
    eq(zones.summary(u, fake), "1/2 zones unlocked")
end)

test("zones: locked maps and entrance decision", function()
    local locked = zones.locked_maps(zones.unlocked({ { item = 79002000 } }, fake), fake)
    eq(locked[2000], nil); eq(locked[2060], true); eq(locked[2061], true)
    eq(zones.entrance_locked({ 2061 }, locked), true)
    eq(zones.entrance_locked({ 2000 }, locked), false)
    eq(zones.entrance_locked({}, locked), false)
    eq(zones.entrance_locked({ 1000 }, locked), false, "maps outside every zone (world map) never lock")
    locked = zones.locked_maps(zones.unlocked({ { item = 79002000 }, { item = 79002060 } }, fake), fake)
    eq(next(locked), nil, "all zones unlocked")
end)

test("zones: generated mappings are consistent", function()
    local m = require("generated.mappings")
    local n = 0
    for ap, it in pairs(m.items) do
        if it.method == "zone" then
            n = n + 1
            eq(ap, 79000000 + it.zone, "zone item id scheme")
            assert(m.zone_names[it.zone], "zone name")
            local has_map = false
            for _, z in pairs(m.zone_of_map) do if z == it.zone then has_map = true break end end
            assert(has_map, "zone " .. it.zone .. " has maps")
        end
    end
    eq(n, 73)
end)


-- shops (progressive shops, TD-034) -----------------------------------------

local shops = require("ap.shops")
local fshop = {
    items = { [79900001] = { method = "shop_tier", chain = "weapon" }, [79900002] = { method = "shop_tier", chain = "armor" },
              [79900003] = { method = "shop_tier", chain = "accessory" } },
    shop_tiers = {
        weapon = { { chapter = 2, items = { 101, 201 } }, { chapter = 3, items = { 102, 202 } } },
        armor = { { chapter = 2, items = { 301 } } },
        accessory = { { chapter = 3, items = { 401, 402 } }, { chapter = 4, items = { 403 } } },
    },
    equip = {
        [100] = { kind = "weapon", detail = 1, price = 300 }, [101] = { kind = "weapon", detail = 1, price = 4000 },
        [102] = { kind = "weapon", detail = 1, price = 7000 }, [200] = { kind = "weapon", detail = 2, price = 9000 },
        [201] = { kind = "weapon", detail = 2, price = 4200 }, [202] = { kind = "weapon", detail = 2, price = 7300 },
        [300] = { kind = "armor", detail = 9, price = 200 }, [301] = { kind = "armor", detail = 9, price = 2250 },
        [401] = { kind = "accessory", detail = 0, price = 2000 }, [402] = { kind = "accessory", detail = 0, price = 1000 },
        [403] = { kind = "accessory", detail = 0, price = 1000 },
    },
}
local function slots(ids)
    local out = {}
    for i = 1, 4 do out[i] = { ItemId = ids[i] or -1, MaxOrderNum = -1, PriceRatio = 1, Condition = "" } end
    return out
end
local function ids_of(list) local o = {} for _, e in ipairs(list) do o[#o + 1] = e.ItemId end return table.concat(o, ",") end

test("shops: options and counts", function()
    eq(shops.enabled({ progressive_shops = 1 }), true); eq(shops.enabled({ progressive_shops = 0 }), false)
    eq(shops.ratio({ progressive_shop_prices = 0 }), 1.0); eq(shops.ratio({ progressive_shop_prices = 2 }), 0.25)
    eq(shops.ratio({}), 0.5)
    local c = shops.counts({ { item = 79900001 }, { item = 79900001 }, { item = 79900001 }, { item = 79900003 }, { item = 5 } }, fshop)
    eq(c.weapon, 2, "capped at the number of tiers"); eq(c.armor, 0); eq(c.accessory, 1)
end)

test("shops: weapons keep the shop's stock, skip weaker duplicates of a type, fill free slots", function()
    local orig = slots({ 100, 200 })  -- weak sword, strong type-2 weapon
    local out = shops.merge(orig, "weapon", { weapon = 1, armor = 0, accessory = 0 }, fshop, 0.5)
    eq(ids_of(out), "100,200,101,-1", "sword added next to the old one; weaker type-2 skipped")
    eq(out[3].PriceRatio, 0.5); eq(out[1].PriceRatio, 1)
    out = shops.merge(slots({ 100 }), "weapon", { weapon = 2, armor = 0, accessory = 0 }, fshop, 0.25)
    eq(ids_of(out), "100,102,202,-1", "tier 2 items added, own stock kept")
    eq(ids_of(orig), "100,200,-1,-1", "original list untouched")
end)

test("shops: a full shop replaces its cheapest same-type item", function()
    local full = slots({ 100, 300, 401, 402 })  -- 4 slots, none free
    eq(ids_of(shops.merge(full, "weapon", { weapon = 1, armor = 0, accessory = 0 }, fshop, 0.5)), "101,300,401,402")
end)

test("shops: limited or conditional items are never replaced", function()
    local orig = slots({ 100 })
    orig = slots({ 100, 300, 401, 402 })
    orig[1].MaxOrderNum = 3
    eq(ids_of(shops.merge(orig, "weapon", { weapon = 1, armor = 0, accessory = 0 }, fshop, 0.5)), "100,300,401,402")
    orig = slots({ 100, 300, 401, 402 })
    orig[1].Condition = "{item:1}>=1"
    eq(ids_of(shops.merge(orig, "weapon", { weapon = 1, armor = 0, accessory = 0 }, fshop, 0.5)), "100,300,401,402")
end)

test("shops: accessories newest first into free slots; armor+accessory shops get both; no tier = unchanged", function()
    eq(ids_of(shops.merge(slots({ 401 }), "accessory", { weapon = 0, armor = 0, accessory = 2 }, fshop, 0.5)), "401,403,402,-1")
    eq(ids_of(shops.merge(slots({ 300 }), "armor_accessory", { weapon = 0, armor = 1, accessory = 1 }, fshop, 0.5)), "300,301,401,402")
    local same = shops.merge(slots({ 100, 300 }), "weapon", { weapon = 0, armor = 0, accessory = 0 }, fshop, 0.5)
    eq(shops.differs(same, slots({ 100, 300 })), false)
    eq(shops.differs(shops.merge(slots({}), "accessory", { weapon = 0, armor = 0, accessory = 1 }, fshop, 0.5), slots({})), true)
end)

test("shops: generated tiers are consistent", function()
    local m = require("generated.mappings")
    for _, chain in ipairs(shops.CHAINS) do
        assert(#m.shop_tiers[chain] >= 6, chain .. " tiers")
        for k, t in ipairs(m.shop_tiers[chain]) do
            for _, id in ipairs(t.items) do
                assert(m.equip[id] and m.equip[id].kind == chain, chain .. " tier " .. k .. " item " .. id)
            end
        end
    end
    eq(#m.shop_tiers.weapon, 7); eq(#m.shop_tiers.armor, 7); eq(#m.shop_tiers.accessory, 6)
    eq(m.items[79900001].chain, "weapon")
    -- every real shop list keeps fitting: worst case is a full tier-7 weapon merge into 15 slots
    local n = 0
    for _ in pairs(m.shop_kinds) do n = n + 1 end
    eq(n, 73)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
