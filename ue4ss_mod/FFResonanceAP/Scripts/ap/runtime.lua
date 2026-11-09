--[[
  Archipelago runtime inside the game (M5). Connects the verified game mechanisms
  (TD-010, TD-013, TD-014) to the session logic and the bridge IPC.

  Activation (TD-032, owner decision 2026-11-09): the runtime does nothing to the game until the player
  presses Connect in the title-screen "Archipelago Options" panel during this game session, and the
  bridge answers that exact request (bridge_state.request_seq). No binding is restored at startup, and
  a stale bridge_state.json from an earlier session is ignored. This keeps saves that are not meant
  for Archipelago (e.g. a normal playthrough) untouched. Once bound, the binding stays for the session,
  so checks are still recorded if the bridge or server goes away.

  Game-thread loop (1 s):
    1. read ipc/bridge_state.json, bind the session to its seed/slot;
    2. apply pending received items (CPP_BFL_SaveDataInventory:AddInventory /
       CPP_BFL_SaveDataPlayer:AddCurrentMoney), in order, only after the game reported a load;
    3. every 10 s, rebuild checked chests from the live save object (covers offline play);
    4. write ipc/game_state.json when something changed (or every 5 s as a heartbeat).
  Chest hook (TryGetItem pre-hook): randomized chests are emptied and their check recorded.
  Save-data rebuild (10 s): opened chests, owned Visions, completed requests (State 2), event flags
  (Espers, Chamber of Arms), Colosseum rank battles (Status 3), main story progress {progress:0}
  for chapter checks and the goal (>= 9000, TD-017).
  Save/load: save-object replacement / SavedDateTime.Ticks polling + ApplySaveGameData hook
  (game.savewatch, ap.saveevents; TD-015).
  DeathLink (TD-030, ap.deathlink + game.battle): game overs (CPP_UI_BattleSubsystem:HandleBeginGameOver)
  are counted for the bridge; deaths received from other players wipe the party in battle, or at the
  start of the next battle.
]]

local json = require("lib.json")
local fs = require("util.fs")
local log = require("util.log")
local mappings = require("generated.mappings")
local Session = require("ap.session")
local SaveEvents = require("ap.saveevents")
local DeathLink = require("ap.deathlink")
local battle = require("game.battle")
local ipc = require("ap.ipc")
local notify = require("ap.notify")
local gamestate = require("game.gamestate")
local Messages = require("ap.messages")
local shops = require("ap.shops")

local runtime = {
    session = nil,
    events = nil,
    in_field = false,
    field_since = nil,
    bridge = nil,
    bridge_problem = nil,
    dirty = true,
    last_write = 0,
    last_rebuild = 0,
    seen_messages = 0,
    messages = Messages.new(), -- in-game messages: popups + pause-menu history (TD-035)
    messages_saved = 0,        -- messages.version last persisted
    messages_saved_at = 0,
    delivery_error = nil,
    mod_version = "?",
    deathlink = DeathLink.new(),
    deathlink_broken = nil,   -- reason the party cannot be killed (receiving disabled until restart)
    armed_seq = nil,          -- seq of the Connect request sent this session (nil: runtime inactive)
    game_session = nil,       -- id of this game launch (game_state.json + connect requests, TD-032)
    ignored_bridge_seq = false, -- last bridge request_seq ignored (log once per value)
}

local LIB_INVENTORY = "/Script/mucha.Default__CPP_BFL_SaveDataInventory"
local LIB_PLAYER = "/Script/mucha.Default__CPP_BFL_SaveDataPlayer"
local LIB_ITEM = "/Script/mucha.Default__CPP_BFL_Item"
local TREASURE_BOX_CLASS = "/Script/mucha.CPP_MapGimmick_TreasureBox"
local FIELD_GAMEMODE = "CPP_MuchaGameModeField"
local SETTLE_DELAY = 5            -- seconds in the field without a load event before settling on the current save
local MAX_ITEMS_PER_TICK = 5

local function lib(path)
    local o = StaticFindObject(path)
    if not o or not o:IsValid() then error("library object not found: " .. path) end
    return o
end

-- Game state readers ------------------------------------------------------

local function save_object()
    local s = FindFirstOf("CPP_MuchaGameSaveData")
    if s and s:IsValid() then return s end
    return nil
end

local function current_ticks()
    local s = save_object()
    if not s then return nil end
    return s.Player.SavedDateTime.Ticks
end

--- All opened chests (table ID) and world-map pickups (ID -1, unique id) in the live save that map
--- to AP locations.
local function opened_chest_locations()
    local s = save_object()
    if not s then return {} end
    local found = {}
    s.Map.mapGimmick:ForEach(function(key, value)
        local map_id = key:get()
        local list = value:get().treasureBox.treasureBoxList
        list:ForEach(function(_, elem)
            local box = elem:get()
            if box.IsOpen then
                local loc
                if box.ID >= 0 then
                    local key = string.format("%d:%d", map_id, box.ID)
                    loc = mappings.chests[key] or mappings.chests_keep[key]
                else
                    -- ID -1: gimmick without a table row (world-map pickups), keyed by unique id (TD-027)
                    loc = mappings.pickups[string.format("%d:%d", map_id, box.UniqueID)]
                end
                if loc then found[#found + 1] = loc end
            end
        end)
    end)
    return found
end

--- First element of an int TArray (TArray:ForEach visits elements in order).
local function first_int(tarray)
    local first
    tarray:ForEach(function(_, elem)
        first = elem:get()
        return true
    end)
    return first
end

--- Non-chest progress from the live save: owned Vision ids, completed request ids, main progress.
local function save_progress()
    local s = save_object()
    if not s then return nil end
    local visions, requests = {}, {}
    s.visionList:ForEach(function(_, elem)
        visions[#visions + 1] = elem:get().ID
    end)
    s.request.DataMap:ForEach(function(key, value)
        if value:get().State == 2 then -- ERequestState.Completed
            requests[#requests + 1] = key:get()
        end
    end)
    -- Event flags (Espers, Chamber of Arms): eventFlag is a TArray<bool>; flag N is element N
    -- (0-based; verified with Siren's flag 90 in the tester's save, TD-025).
    local flags = {}
    local i = 0
    s.Progress.eventFlag:ForEach(function(_, elem)
        if elem:get() then flags[i] = true end
        i = i + 1
    end)
    -- Colosseum rank battles: colosseumProgress.RankBattle[FName row] .Status == 3 (Clear).
    local colosseum = {}
    pcall(function()
        s.colosseumProgress.RankBattle:ForEach(function(key, value)
            if value:get().Status == 3 then colosseum[#colosseum + 1] = key:get():ToString() end
        end)
    end)
    -- Tablet Shards collected = held + handed in at Oblivion Palace (TD-029):
    -- inventory[] {ItemId, Num} and tranferTargetInventory.inventory[map].inventory[target].inventoryList[].
    local sh = mappings.shards
    local held, handed_in = 0, 0
    s.inventory:ForEach(function(_, e)
        local it = e:get()
        if it.ItemId == sh.item_id then held = held + it.Num end
    end)
    pcall(function()
        s.tranferTargetInventory.inventory:ForEach(function(map_key, by_target)
            if map_key:get() ~= sh.turnin_map then return end
            by_target:get().inventory:ForEach(function(target_key, list)
                if target_key:get() ~= sh.turnin_target then return end
                list:get().inventoryList:ForEach(function(_, e)
                    local it = e:get()
                    if it.ItemId == sh.item_id then handed_in = handed_in + it.Num end
                end)
            end)
        end)
    end)
    return { visions = visions, requests = requests, main_progress = first_int(s.Progress.Progress),
             flags = flags, colosseum = colosseum, shards_held = held, shards_handed_in = handed_in }
end

-- Item delivery -----------------------------------------------------------

--- Apply one received item. Returns true on success, false + reason otherwise.
local function apply_item(entry)
    local m = mappings.items[entry.item]
    if not m then
        return false, string.format("unknown item id %s (mod mappings out of date?)", tostring(entry.item))
    end
    if m.method == "inventory" then
        local item_lib = lib(LIB_ITEM)
        local before = item_lib:GetInventoryItemNum(m.item_id)
        lib(LIB_INVENTORY):AddInventory(m.item_id, m.num)
        local after = item_lib:GetInventoryItemNum(m.item_id)
        local gained = (tonumber(after) or 0) - (tonumber(before) or 0)
        if gained < m.num then
            -- The game clamps at the per-item maximum (CPP_BFL_Item:GetMaxItemNumById); the excess is
            -- lost exactly as for a vanilla pickup. Recorded so it is visible, then treated as applied.
            local okm, max = pcall(function() return item_lib:GetMaxItemNumById(m.item_id) end)
            log.warn("Item %d: only %d of %d added (count %s -> %s, max %s): inventory full for this item",
                m.item_id, gained, m.num, tostring(before), tostring(after), okm and tostring(max) or "?")
            runtime.capped = (runtime.capped or 0) + (m.num - gained)
        end
        if gained > 0 then notify.push(m.item_id, gained) end
        return true
    elseif m.method == "shop_tier" then
        -- Nothing to add to the save: game/shopgate.lua rebuilds the shop lists from the received items.
        log.info("Progressive %s shop received", tostring(m.chain))
        return true
    elseif m.method == "zone" then
        -- Nothing to add to the save: game/zonegate.lua opens the zone from the received-item list.
        log.info("Zone unlocked: %s", tostring(mappings.zone_names[m.zone] or m.zone))
        return true
    elseif m.method == "money" then
        local before = lib(LIB_PLAYER):GetCurrentMoney()
        lib(LIB_PLAYER):AddCurrentMoney(m.amount, false)
        local after = lib(LIB_PLAYER):GetCurrentMoney()
        log.info("Gil %s -> %s", tostring(before), tostring(after))
        return true
    end
    return false, "unknown apply method " .. tostring(m.method)
end

--- Items are applied only while the game is idle in the field (TD-018): never during a battle,
--- cutscene, dialog or menu, where the game may hold its own copy of the inventory.
local function delivery_allowed()
    if runtime.idle_check_broken then return true end
    local ok, idle, reason = pcall(gamestate.idle)
    if not ok then
        runtime.idle_check_broken = true
        log.error("Idle check unavailable (%s); delivering items without waiting for idle", tostring(idle))
        return true
    end
    if not idle and reason ~= runtime.last_wait_reason then
        log.info("Item delivery waiting (%s)", reason)
    end
    runtime.last_wait_reason = (not idle) and reason or nil
    return idle
end

--- In-game message for an applied item (TD-035). Names come from the bridge (data package).
function runtime.message_for_item(index, it)
    local m = mappings.items[it.item]
    if not m then return end
    local own_slot = runtime.bridge and runtime.bridge.slot
    local loc = tonumber(it.location) or -1
    local info = {
        name = it.item_name or ("Item " .. tostring(it.item)),
        sender = it.sender or ("Player " .. tostring(it.player)),
        location = it.location_name,
        own = own_slot ~= nil and it.player == own_slot and loc >= 0,
        method = m.method,
        amount = m.amount,
        chain = m.chain,
        zone_name = m.zone and (mappings.zone_names[m.zone] or tostring(m.zone)),
    }
    if m.method == "shop_tier" then
        local upto = {}
        for i = 1, index do upto[i] = runtime.bridge.items[i] end
        local n = shops.counts(upto, mappings)[m.chain] or 0
        local tier = mappings.shop_tiers[m.chain] and mappings.shop_tiers[m.chain][n]
        if tier then info.tier, info.chapter = n, tier.chapter end
    end
    -- Starting inventory (location -2, e.g. the chapter-1 zones): listed, no popup.
    local quiet = it.player == 0 and loc == -2
    runtime.messages:add(Messages.item_kind(m.method), Messages.item_text(info), "item:" .. index,
        { item_index = index, history_only = quiet })
end

local function deliver_items()
    local s = runtime.session
    if not (s:is_bound() and s.loaded and runtime.in_field and runtime.bridge) then return end
    if runtime.delivery_error then return end
    local pending = s:pending_items(runtime.bridge.items or {})
    if #pending == 0 or not delivery_allowed() then return end
    for i = 1, math.min(#pending, MAX_ITEMS_PER_TICK) do
        local p = pending[i]
        local ok, res, reason = pcall(apply_item, p.item)
        if ok and res then
            s:mark_applied(p.index)
            runtime.dirty = true
            log.info("ITEM %d applied: ap_item=%s from player %s (location %s)",
                p.index, tostring(p.item.item), tostring(p.item.player), tostring(p.item.location))
            local mok, merr = pcall(runtime.message_for_item, p.index, p.item)
            if not mok then log.error("Message for item #%d failed: %s", p.index, tostring(merr)) end
        else
            runtime.delivery_error = string.format("item #%d (%s): %s", p.index, tostring(p.item.item),
                tostring(ok and reason or res))
            log.error("ITEM delivery stopped: %s", runtime.delivery_error)
            runtime.dirty = true
            return
        end
    end
end

-- Checks ------------------------------------------------------------------

local function record_check(loc, source)
    if runtime.session:add_checked(loc) then
        log.info("CHECK %d recorded (%s)", loc, source)
        runtime.dirty = true
    end
end

local function rebuild_checks()
    if not runtime.session:is_bound() then return end
    local ok, locs = pcall(opened_chest_locations)
    if not ok then
        log.warn("Chest state rebuild failed: %s", tostring(locs))
        return
    end
    for _, loc in ipairs(locs) do record_check(loc, "save data") end

    local pok, prog = pcall(save_progress)
    if not pok or not prog then
        log.warn("Progress rebuild failed: %s", tostring(prog))
        return
    end
    for _, id in ipairs(prog.visions) do
        local loc = mappings.visions[id]
        if loc then record_check(loc, "vision " .. id) end
    end
    for _, id in ipairs(prog.requests) do
        local loc = mappings.requests[id]
        if loc then record_check(loc, "request " .. id .. " completed") end
    end
    for flag, loc in pairs(mappings.event_flags) do
        if prog.flags[flag] then record_check(loc, "event flag " .. flag) end
    end
    local shards = prog.shards_held + prog.shards_handed_in
    if shards ~= runtime.last_shards then
        log.info("Tablet Shards collected: %d (held %d + handed in %d)", shards, prog.shards_held, prog.shards_handed_in)
        runtime.last_shards = shards
    end
    for n = 1, shards do
        local loc = mappings.shards.locations[n]
        if loc then record_check(loc, "tablet shards " .. n) end
    end
    for _, row in ipairs(prog.colosseum) do
        local loc = mappings.colosseum[row]
        if loc then record_check(loc, "colosseum " .. row) end
    end
    local mp = prog.main_progress
    if type(mp) == "number" then
        if mp ~= runtime.last_main_progress then
            log.info("Main story progress: %d", mp)
            runtime.last_main_progress = mp
        end
        for _, ch in ipairs(mappings.chapters) do
            if mp >= ch.min_progress then record_check(ch.location, "story progress " .. mp) end
        end
        if mp >= mappings.goal.min_progress and runtime.session:set_goal() then
            log.info("GOAL reached: story progress %d >= %d", mp, mappings.goal.min_progress)
            runtime.messages:add("goal", "Goal complete!", "goal")
            runtime.dirty = true
        end
    end
end

local function on_try_get_item(ctx)
    local actor = ctx:get()
    if not actor or not actor:IsValid() or not actor:IsA(TREASURE_BOX_CLASS) then return end
    local data = actor.m_TreasureBoxData
    local key = string.format("%d:%d", data.mapId, data.ID)
    local keep_loc = mappings.chests_keep[key]
    if keep_loc then
        -- Check-only chest (Oblivion Palace safe with a valuable reward, TD-031): vanilla reward kept.
        if runtime.session:is_bound() then
            record_check(keep_loc, string.format("chest map=%d id=%d (vanilla reward kept)", data.mapId, data.ID))
        end
        return
    end
    local loc = mappings.chests[key]
    if not loc then
        log.info("Chest map=%d id=%d is not randomized; vanilla reward kept", data.mapId, data.ID)
        return
    end
    if not runtime.session:is_bound() then
        if runtime.incompatible then
            log.warn("Chest map=%d id=%d: vanilla reward kept (connected seed is incompatible with this mod)",
                data.mapId, data.ID)
        else
            log.warn("Chest map=%d id=%d opened before any Archipelago connection: vanilla reward kept, check will be sent from save data later",
                data.mapId, data.ID)
        end
        return
    end
    -- Empty the reward (verified: game shows "0 Gil", grants nothing).
    data.ItemId = -1
    data.ItemNum = 0
    data.Money = -1
    actor.m_ItemId = -1
    actor.m_ItemNum = 0
    actor.m_Money = -1
    record_check(loc, string.format("chest map=%d id=%d", data.mapId, data.ID))
end

-- Save / load -------------------------------------------------------------

local function on_save_event(_, new_ticks, reason)
    local s = runtime.session
    local kind, slot = runtime.events:classify(reason, s:is_bound() and s.loaded)
    if not s:is_bound() then
        log.info("Save event (%s, %s) ignored: not bound to an Archipelago seed yet", kind, reason)
        return
    end
    if kind == "save" then
        s:on_saved(new_ticks, slot)
        log.info("SAVE recorded (%s): slot=%s ticks=%s applied_index=%d", reason, tostring(slot), tostring(new_ticks),
            s.state.applied_index)
    else
        local idx, known = s:on_loaded(new_ticks)
        log.info("LOAD detected (%s): ticks=%s -> applied_index=%d (%s save)", reason, tostring(new_ticks), idx,
            known and "known" or "unknown")
        runtime.delivery_error = nil
        runtime.last_rebuild = 0
    end
    runtime.dirty = true
end

--- Called once with the first observed Ticks (mod start or hot reload).
local function on_initial_ticks(ticks)
    if ticks ~= 0 then
        runtime.in_field = true  -- hot reload during play: no InitGameState will come
        local s = runtime.session
        if s:is_bound() and s.state.current_ticks == ticks then
            s.loaded = true      -- resume: game memory still matches the persisted applied_index
            log.info("Resumed session after mod reload (ticks=%s, applied_index=%d)", tostring(ticks), s.state.applied_index)
        elseif s:is_bound() then
            -- Unknown relation between the running game and the persisted state: applying items now
            -- could duplicate them, so wait for an explicit save load.
            log.warn("Mod reloaded mid-game with a different save state; items are paused until you load a save")
        end
    end
end

-- Bridge ------------------------------------------------------------------

local function read_bridge()
    local st, problem = ipc.read_bridge_state()
    if not st then
        if problem ~= runtime.bridge_problem then
            log.info("Bridge state: %s", problem)
            runtime.bridge_problem = problem
        end
        runtime.bridge = nil
        return
    end
    runtime.bridge_problem = nil
    if runtime.armed_seq == nil or st.request_seq ~= runtime.armed_seq then
        -- Not an answer to a Connect pressed in this game session: stale file or another request.
        if st.request_seq ~= runtime.ignored_bridge_seq then
            runtime.ignored_bridge_seq = st.request_seq
            log.info("Bridge state ignored (request %s, this session's Connect: %s)%s", tostring(st.request_seq),
                tostring(runtime.armed_seq), runtime.armed_seq == nil and "; press Connect in Archipelago Options" or "")
        end
        runtime.bridge = nil
        return
    end
    if st.seed_name and st.slot_name then
        -- Compatibility guard: the seed must have been generated from the same data as this mod.
        local sd = type(st.slot_data) == "table" and st.slot_data or {}
        if sd.data_version ~= mappings.data_version then
            local msg = string.format("seed data_version %s does not match mod data_version %s; "
                .. "use the mod release that matches the .apworld used to generate this seed",
                tostring(sd.data_version), tostring(mappings.data_version))
            if msg ~= runtime.incompatible then log.error("INCOMPATIBLE SEED: %s", msg) end
            runtime.incompatible = msg
            runtime.bridge = nil
            if runtime.session:is_bound() and runtime.session.state.seed_name == st.seed_name then
                -- Drop a binding restored at startup: no chest emptying, no delivery for this seed.
                runtime.session = Session.new(runtime.session.store)
                os.remove(fs.join(runtime.state_dir, "current.json"))
            end
            runtime.dirty = true
            return
        end
        runtime.incompatible = nil
    end
    runtime.bridge = st
    if st.seed_name and st.slot_name then
        if runtime.session:bind(st.seed_name, st.slot_name) then
            log.info("Bound to seed %s, slot %s", st.seed_name, st.slot_name)
            runtime.load_messages()
            fs.write_atomic(fs.join(runtime.state_dir, "current.json"),
                json.encode({ seed_name = st.seed_name, slot_name = st.slot_name }))
            -- A binding made while already in game: treat the current save as loaded.
            local ticks = current_ticks()
            if ticks and ticks ~= 0 and runtime.in_field then
                local idx, known = runtime.session:on_loaded(ticks)
                log.info("Bound in game: ticks=%s applied_index=%d (%s save)", tostring(ticks), idx, known and "known" or "unknown")
            end
            runtime.dirty = true
        end
    end
    local was_enabled = runtime.deathlink.enabled
    local new_deaths = runtime.deathlink:on_bridge(runtime.session:is_bound() and st.death_link or nil)
    if runtime.deathlink.enabled ~= was_enabled then
        log.info("DeathLink %s", runtime.deathlink.enabled and "enabled" or "disabled")
    end
    for _, d in ipairs(new_deaths) do
        log.info("DEATHLINK received #%s from %s: %s", tostring(d.id), tostring(d.source), tostring(d.cause))
        runtime.messages:add("death", Messages.death_received_text(d.source, d.cause),
            string.format("death:%s:%s", tostring(st.death_link and st.death_link.session), tostring(d.id)))
        if runtime.deathlink_broken then
            runtime.deathlink:drop_pending()
            log.warn("DeathLink death ignored: the party cannot be killed (%s)", runtime.deathlink_broken)
        end
    end
    -- Log messages: ids restart with every bridge connection ("epoch" changes with them).
    if st.epoch ~= runtime.seen_epoch then
        runtime.seen_epoch = st.epoch
        runtime.seen_messages = 0
    end
    for _, m in ipairs(st.messages or {}) do
        if (m.id or 0) > runtime.seen_messages then
            runtime.seen_messages = m.id
            log.info("AP: %s", tostring(m.text))
        end
    end
    -- Hints and chat for the in-game messages; the history keys make a re-read harmless.
    if runtime.session:is_bound() then
        for _, e in ipairs(st.events or {}) do
            if type(e) == "table" and (e.kind == "hint" or e.kind == "chat") then
                runtime.messages:add(e.kind, tostring(e.text), string.format("ev:%s:%s", tostring(st.epoch), tostring(e.id)))
            end
        end
    end
end

-- Message history persistence (state/<seed>__<slot>.messages.json) ----------

function runtime.load_messages()
    runtime.messages = Messages.new()
    local ok, t = pcall(runtime.session.store.load, runtime.session.key .. ".messages")
    if not ok then
        log.warn("Message history unreadable (%s); starting a new one", tostring(t))
    elseif t then
        runtime.messages:load_table(t)
        log.info("Message history: %d entr%s restored", #runtime.messages.history,
            #runtime.messages.history == 1 and "y" or "ies")
    end
    runtime.messages_saved = runtime.messages.version
end

local function save_messages()
    local m = runtime.messages
    if not runtime.session:is_bound() or m.version == runtime.messages_saved then return end
    if os.time() - runtime.messages_saved_at < 2 then return end
    local ok, err = pcall(runtime.session.store.save, runtime.session.key .. ".messages", m:to_table())
    runtime.messages_saved_at = os.time()
    if ok then
        runtime.messages_saved = m.version
    else
        log.error("Cannot save the message history: %s", tostring(err))
    end
end

local function write_game_state()
    local s = runtime.session
    local now = os.time()
    if not runtime.dirty and now - runtime.last_write < 5 then return end
    local state = {
        mod_version = runtime.mod_version,
        updated = now,
        game_session = runtime.game_session,
        bound = s:is_bound(),
        in_game = s:is_bound() and s.loaded and runtime.in_field or false,
        goal = s:is_bound() and s.state.goal == true or false,
        main_progress = runtime.last_main_progress,
        delivery_error = runtime.delivery_error,
        incompatible = runtime.incompatible,
        data_version = mappings.data_version,
        delivery_waiting = runtime.last_wait_reason,
        items_lost_to_cap = runtime.capped,
        deaths = runtime.deathlink:report(),
        death_link_error = runtime.deathlink_broken,
    }
    if s:is_bound() then
        state.seed_name = s.state.seed_name
        state.slot_name = s.state.slot_name
        state.checked = s:checked_list()
        state.applied_index = s.state.applied_index
    end
    local ok, err = ipc.write_game_state(state)
    if ok then
        runtime.dirty = false
        runtime.last_write = now
    else
        log.error("Cannot write game_state.json: %s", tostring(err))
    end
end

-- DeathLink ---------------------------------------------------------------

local function apply_pending_death()
    local dl = runtime.deathlink
    if not dl.pending or runtime.deathlink_broken then return end
    local ok, fighting = pcall(battle.in_battle)
    if not ok then
        runtime.deathlink_broken = "battle state unreadable: " .. tostring(fighting)
        log.error("DeathLink: %s; received deaths are ignored", runtime.deathlink_broken)
        dl:drop_pending()
        runtime.dirty = true
        return
    end
    if not dl:should_kill(fighting) then
        if not fighting and not runtime.death_wait_logged then
            log.info("DeathLink: death from %s queued until the next battle", tostring(dl.pending.source))
            runtime.death_wait_logged = true
        end
        return
    end
    runtime.death_wait_logged = false
    local death = dl.pending
    local kok, requested, how = pcall(battle.kill_party)
    if kok and requested then
        dl:on_killed()
        runtime.wipe_requested_at = os.time()
        runtime.wipe_result_logged = false
        runtime.out_of_battle_since = nil
        log.info("DEATHLINK applied for death #%s from %s: %s", tostring(death.id), tostring(death.source), tostring(how))
        return
    end
    local reason = kok and tostring(how) or tostring(requested)
    if kok and reason:find("^not ready") then
        if reason ~= runtime.death_not_ready then log.info("DeathLink: %s; retrying", reason) end
        runtime.death_not_ready = reason
        return
    end
    runtime.deathlink_broken = reason
    dl:drop_pending()
    runtime.dirty = true
    log.error("DeathLink: could not kill the party (%s); received deaths are ignored until the mod restarts", reason)
end

--- After a requested wipe: log the result once, and end the echo suppression if the battle ends
--- without a game over (out of battle for 5 s in a row).
local function watch_requested_wipe()
    local t = runtime.wipe_requested_at
    if t and not runtime.wipe_result_logged and os.time() - t >= 10 then
        runtime.wipe_result_logged = true
        local ok, alive = pcall(battle.allies_alive)
        log.info("DeathLink: %d s after the wipe request, living allies: %s (the game shows the game over after the next action)",
            os.time() - t, ok and tostring(alive) or ("? " .. tostring(alive)))
    end
    if not runtime.deathlink.suppress then return end
    local ok, fighting = pcall(battle.in_battle)
    if ok and not fighting then
        runtime.out_of_battle_since = runtime.out_of_battle_since or os.time()
        if os.time() - runtime.out_of_battle_since >= 5 and runtime.deathlink:battle_over() then
            log.warn("DeathLink: the battle of the forced wipe ended without a game over")
            runtime.wipe_requested_at = nil
        end
    else
        runtime.out_of_battle_since = nil
    end
end

local function on_game_over()
    if not runtime.session:is_bound() then return end
    if runtime.wipe_requested_at then
        log.info("DeathLink wipe confirmed: game over %d s after the request", os.time() - runtime.wipe_requested_at)
        runtime.wipe_requested_at = nil
    end
    if runtime.deathlink:on_game_over(os.time()) then
        log.info("GAME OVER #%d%s", runtime.deathlink.count,
            runtime.deathlink.enabled and " (DeathLink: sending)" or "")
        if runtime.deathlink.enabled then
            runtime.messages:add("death", "You died: DeathLink sent",
                string.format("deathsent:%s:%d", tostring(runtime.game_session), runtime.deathlink.count))
        end
    else
        log.info("GAME OVER caused by a received DeathLink: not sent back")
    end
    runtime.dirty = true
end

-- Main --------------------------------------------------------------------

local function tick()
    read_bridge()
    local s = runtime.session
    -- In the field for a while without a load event (new game, or a load that changed neither the
    -- save object nor its timestamp): settle on the current save timestamp.
    if s:is_bound() and not s.loaded and runtime.in_field and runtime.field_since
        and os.time() - runtime.field_since >= SETTLE_DELAY then
        local ok, ticks = pcall(current_ticks)
        if ok and ticks ~= nil then
            local idx, known = s:on_loaded(ticks)
            log.info("In game without load event: ticks=%s -> applied_index=%d (%s save%s)", tostring(ticks), idx,
                known and "known" or "unknown", ticks == 0 and ", new game" or "")
            runtime.dirty = true
        end
    end
    deliver_items()
    apply_pending_death()
    watch_requested_wipe()
    if runtime.in_field then notify.flush() end
    if s:is_bound() and s.loaded and os.time() - runtime.last_rebuild >= 10 then
        runtime.last_rebuild = os.time()
        rebuild_checks()
    end
    write_game_state()
    save_messages()
end

function runtime.init(mod_dir, mod_version, savewatch)
    runtime.mod_version = mod_version
    runtime.game_session = require("ap.connconfig").new_game_session()
    runtime.state_dir = fs.join(mod_dir, "state")
    ipc.init(fs.join(mod_dir, "ipc"))
    runtime.session = Session.new(ipc.file_store(runtime.state_dir, function(msg) log.warn("%s", msg) end))
    runtime.events = SaveEvents.new()
    notify.init(mod_dir)

    -- The last binding is NOT restored (TD-032): the runtime stays inactive until Connect is pressed.
    local raw = fs.read_all(fs.join(runtime.state_dir, "current.json"))
    if raw then
        local ok, cur = pcall(json.decode, raw)
        if ok and type(cur) == "table" and cur.seed_name and cur.slot_name then
            log.info("Last binding: seed %s, slot %s (inactive until Connect in Archipelago Options)",
                cur.seed_name, cur.slot_name)
        end
    end

    savewatch.on_initial(on_initial_ticks)
    savewatch.on_change(on_save_event)
end

--- Called by the options panel when the player presses Connect: only bridge states answering this
--- request may bind the session.
function runtime.arm(seq)
    runtime.armed_seq = seq
    runtime.ignored_bridge_seq = false
    log.info("Connect pressed (request %s): Archipelago runtime armed for this session", tostring(seq))
end

function runtime.on_game_state(class_name, full_name)
    local was_in_field = runtime.in_field
    runtime.in_field = class_name == FIELD_GAMEMODE
    if runtime.in_field and not was_in_field then runtime.field_since = os.time() end
    if not runtime.in_field then runtime.field_since = nil end
    if tostring(full_name):find("/Map/Title/", 1, true) and runtime.session.loaded then
        -- Back on the title screen: the next game in the field is a (new) load.
        runtime.session.loaded = false
        log.info("Title screen: waiting for a save to be loaded")
        if runtime.deathlink:drop_pending() then log.info("DeathLink: queued death dropped (title screen)") end
    end
end

function runtime.register_hooks()
    local hooks = {
        { "/Script/mucha.CPP_MapGimmick_ItemObjectBase:TryGetItem", on_try_get_item },
        { "/Script/mucha.CPP_BFL_SaveData:ApplySaveGameData", function(_, slot)
            local ok, v = pcall(function() return slot:get() end)
            runtime.events:on_save_hook(ok and v or nil)
        end },
        { "/Script/mucha.CPP_UI_BattleSubsystem:HandleBeginGameOver", function() on_game_over() end },
        { "/Script/mucha.CPP_UI_BattleSubsystem:HandleBeginBtl", function()
            if runtime.deathlink.pending then
                log.info("DeathLink: battle started with a queued death")
            end
        end },
    }
    for _, h in ipairs(hooks) do
        local ok, err = pcall(RegisterHook, h[1], function(...)
            local hok, herr = pcall(h[2], ...)
            if not hok then log.error("hook %s error: %s", h[1], tostring(herr)) end
        end)
        if ok then log.info("AP hook registered: %s", h[1]) else log.error("AP hook NOT registered: %s (%s)", h[1], tostring(err)) end
    end
end

function runtime.start(interval_ms)
    LoopInGameThreadWithDelay(interval_ms or 1000, function()
        local ok, err = pcall(tick)
        if not ok then log.error("AP tick error: %s", tostring(err)) end
    end)
    log.info("AP runtime started")
end

return runtime
