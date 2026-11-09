--[[
  Title-screen UI research (TD-032). Read-only: nothing is created, changed or clicked.
  Research mode only (config/research.txt = "on"): a dump walks hundreds of widgets on the game
  thread and froze the game for 1-3 s (2026-11-09), so nothing is dumped in normal play.

    uidump.on_title()       schedule dumps after the title map loads (3 s, 12 s, 25 s)
    uidump.dump(label)      dumps/title_ui_<time>_<label>.json + .txt:
                              - every UserWidget in the viewport with its full widget tree
                                (class, name, visibility, enabled, slot layout, text, all
                                reflected properties of text/button/list widgets)
                              - the items of every ListView (title menu entries)
                              - CPP_VM_Title / CPP_DA_Title (EntryPropertyMap) and CPP_TitleTaskMain
    uidump.register_hooks() logs the title menu's click path (OnListButtonEvent, ExecuteEntry)
                            and dumps again 1 s after a menu entry is used
]]

local json = require("lib.json")
local fs = require("util.fs")
local log = require("util.log")
local reflect = require("game.reflect")

local uidump = { mod_dir = nil, on_title_map = false, dumps_this_visit = 0, enabled = false }

local MAX_DUMPS_PER_VISIT = 8
local MAX_TREE_DEPTH = 40
local MAX_NODES = 4000

-- Widget classes whose full reflected properties are worth recording (fonts, styles, layout).
local DETAIL_CLASS_PATTERNS = { "Text", "Button", "ListView", "Border", "Image", "Menu", "Title", "Entry" }

local function safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function valid(obj)
    return obj ~= nil and safe(function() return obj:IsValid() end) == true
end

local function class_name(obj)
    return safe(function() return obj:GetClass():GetFName():ToString() end) or "?"
end

local function obj_name(obj)
    return safe(function() return obj:GetFName():ToString() end) or "?"
end

local function full_name(obj)
    return safe(function() return obj:GetFullName() end) or "?"
end

local function wants_detail(cls)
    for _, p in ipairs(DETAIL_CLASS_PATTERNS) do
        if cls:find(p, 1, true) then return true end
    end
    return false
end

function uidump.init(mod_dir)
    uidump.mod_dir = mod_dir
    -- Decode the title data asset's TMap<ETitleFunctionType, FTitleEntryProperty> values.
    reflect.MAP_VALUE_STRUCT_HINTS.EntryPropertyMap = "/Script/mucha.TitleEntryProperty"
    reflect.MAP_VALUE_STRUCT_HINTS.DifficultyPropertyMap = "/Script/mucha.TitleEntryProperty"
end

--- Walk a widget and its children. `ctx` = { nodes = n, lines = {...} }.
local function walk(widget, depth, ctx)
    if not valid(widget) then return nil end
    ctx.nodes = ctx.nodes + 1
    if ctx.nodes > MAX_NODES or depth > MAX_TREE_DEPTH then return { truncated = true } end

    local cls = class_name(widget)
    local node = {
        class = cls,
        class_path = safe(function() return widget:GetClass():GetFullName() end),
        name = obj_name(widget),
        visibility = safe(function() return widget:GetVisibility() end),
        enabled = safe(function() return widget:GetIsEnabled() end),
    }
    local text = safe(function() return widget:GetText():ToString() end)
    if text ~= nil then node.text = text end

    local slot = safe(function() return widget.Slot end)
    if valid(slot) then
        node.slot = { class = class_name(slot), properties = reflect.object_to_table(slot, 2) }
    end
    if wants_detail(cls) then
        node.properties = reflect.object_to_table(widget, 1)
    end

    ctx.lines[#ctx.lines + 1] = string.format("%s%s [%s] vis=%s en=%s%s%s", string.rep("  ", depth), node.name, cls,
        tostring(node.visibility), tostring(node.enabled),
        node.slot and (" slot=" .. node.slot.class) or "",
        text and (" text=" .. string.format("%q", text)) or "")

    local children = {}
    -- Panel widgets.
    local count = safe(function() return widget:GetChildrenCount() end)
    if type(count) == "number" and count > 0 then
        for i = 0, count - 1 do
            local child = safe(function() return widget:GetChildAt(i) end)
            children[#children + 1] = walk(child, depth + 1, ctx)
        end
    end
    -- Content widgets (Border, Button, NamedSlot...).
    if type(count) ~= "number" then
        local content = safe(function() return widget:GetContent() end)
        if valid(content) then children[#children + 1] = walk(content, depth + 1, ctx) end
    end
    -- CommonUI activatable stacks: their displayed widget is not a panel child.
    local active = safe(function() return widget:GetActiveWidget() end)
    if valid(active) then
        ctx.lines[#ctx.lines + 1] = string.rep("  ", depth + 1) .. "<ActiveWidget>"
        children[#children + 1] = walk(active, depth + 1, ctx)
    end
    -- User widgets: descend into their own widget tree.
    local tree = safe(function() return widget.WidgetTree end)
    if valid(tree) then
        local root = safe(function() return tree.RootWidget end)
        if valid(root) then
            ctx.lines[#ctx.lines + 1] = string.rep("  ", depth + 1) .. "<WidgetTree>"
            children[#children + 1] = walk(root, depth + 1, ctx)
        end
    end
    -- List views: their data items (one per menu entry) and generated entry widgets.
    local items = safe(function() return widget:GetListItems() end)
    if items ~= nil then
        node.list_items = {}
        pcall(function()
            items:ForEach(function(_, elem)
                local item = elem:get()
                node.list_items[#node.list_items + 1] = {
                    class = class_name(item), path = full_name(item),
                    properties = reflect.object_to_table(item, 1),
                }
            end)
        end)
        ctx.lines[#ctx.lines + 1] = string.format("%s<ListView items=%d>", string.rep("  ", depth + 1), #node.list_items)
        local entries = safe(function() return widget:GetDisplayedEntryWidgets() end)
        if entries ~= nil then
            node.entry_widgets = {}
            pcall(function()
                entries:ForEach(function(_, elem)
                    node.entry_widgets[#node.entry_widgets + 1] = full_name(elem:get())
                end)
            end)
        end
    end
    if #children > 0 then node.children = children end
    return node
end

local function dump_objects(class, depth)
    local out = {}
    local all = safe(function() return FindAllOf(class) end) or {}
    for _, o in ipairs(all) do
        if valid(o) then
            out[#out + 1] = { path = full_name(o), properties = reflect.object_to_table(o, depth or 0) }
        end
    end
    return out
end

function uidump.dump(label)
    local ctx = { nodes = 0, lines = {} }
    local result = { label = label, time = os.date("%Y-%m-%d %H:%M:%S"), viewport = {}, other_user_widgets = {} }

    local widgets = safe(function() return FindAllOf("UserWidget") end) or {}
    for _, w in ipairs(widgets) do
        if valid(w) then
            if safe(function() return w:IsInViewport() end) then
                ctx.lines[#ctx.lines + 1] = "== " .. full_name(w)
                result.viewport[#result.viewport + 1] = { path = full_name(w), tree = walk(w, 0, ctx) }
            else
                result.other_user_widgets[#result.other_user_widgets + 1] = full_name(w)
            end
        end
    end

    result.vm_title = dump_objects("CPP_VM_Title", 0)
    result.da_title = dump_objects("CPP_DA_Title", 0)
    result.title_task = {}
    for _, t in ipairs(safe(function() return FindAllOf("CPP_TitleTaskMain") end) or {}) do
        if valid(t) then
            result.title_task[#result.title_task + 1] = {
                path = full_name(t),
                user_widget = full_name(safe(function() return t.m_pUserWidget end)),
                controller = full_name(safe(function() return t.m_pTitleController end)),
            }
        end
    end
    result.title_controllers = dump_objects("CPP_TitleController", 0)
    -- Blueprint functions of the title widgets (how entries are created / decided).
    result.functions = {}
    for _, cname in ipairs({ "WBP_TitleLayout_C", "WBP_Title_ListEntry_C", "WBP_DirectionLayoutMenu_C" }) do
        local o = safe(function() return FindFirstOf(cname) end)
        if valid(o) then
            result.functions[cname] = reflect.describe_functions(o:GetClass())
            result.functions[cname .. ".properties"] = reflect.describe_properties(o:GetClass())
        end
    end

    local stamp = os.date("%Y%m%d_%H%M%S")
    local base = fs.join(uidump.mod_dir, "dumps", "title_ui_" .. stamp .. "_" .. label)
    local ok, encoded = pcall(json.encode, result, true)
    if not ok then
        log.error("UI dump: JSON encode failed: %s", tostring(encoded))
        return
    end
    local wok, werr = fs.write_atomic(base .. ".json", encoded)
    local tok, terr = fs.write_atomic(base .. ".txt", table.concat(ctx.lines, "\n") .. "\n")
    if wok and tok then
        log.info("UI dump '%s': %d viewport widgets, %d nodes -> %s.json/.txt", label, #result.viewport, ctx.nodes, base)
    else
        log.error("UI dump '%s' write failed: %s %s", label, tostring(werr), tostring(terr))
    end
end

local function schedule(label, delay_ms)
    ExecuteInGameThreadWithDelay(delay_ms, function()
        if not uidump.on_title_map then return end
        if uidump.dumps_this_visit >= MAX_DUMPS_PER_VISIT then return end
        uidump.dumps_this_visit = uidump.dumps_this_visit + 1
        local ok, err = pcall(uidump.dump, label)
        if not ok then log.error("UI dump '%s' failed: %s", label, tostring(err)) end
    end)
end

--- Called for every InitGameState; dumps only on the title map.
function uidump.on_game_state(full_name_str)
    uidump.on_title_map = tostring(full_name_str):find("/Map/Title/", 1, true) ~= nil
    if not uidump.on_title_map or not uidump.enabled then return end
    uidump.dumps_this_visit = 0
    schedule("t03s", 3000)
    schedule("t12s", 12000)
    schedule("t25s", 25000)
    schedule("t45s", 45000)
end

function uidump.register_hooks()
    local hooks = {
        { "/Script/mucha.CPP_TitleTaskMain:OnListButtonEvent", function(ctx, value)
            local v = safe(function() return value:get() end)
            log.info("TITLE OnListButtonEvent value=%s EventType=%s FunctionType=%s task=%s",
                full_name(v), tostring(safe(function() return v.EventType end)),
                tostring(safe(function() return v.FunctionType end)), full_name(safe(function() return ctx:get() end)))
            if uidump.enabled then schedule("after_event", 1000) end
        end },
        { "/Script/mucha.CPP_VM_Title:ExecuteEntry", function(_, in_type)
            log.info("TITLE ExecuteEntry InType=%s", tostring(safe(function() return in_type:get() end)))
        end },
        { "/Script/mucha.CPP_TitleController:InputMenu", function()
            log.debug("TITLE InputMenu")
        end },
    }
    local n = 0
    for _, h in ipairs(hooks) do
        local ok, err = pcall(RegisterHook, h[1], h[2])
        if ok then n = n + 1 else log.warn("UI hook not registered: %s (%s)", h[1], tostring(err)) end
    end
    log.info("Registered %d/%d title UI hooks", n, #hooks)
end

return uidump
