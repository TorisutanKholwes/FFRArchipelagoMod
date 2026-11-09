--[[
  In-game Archipelago messages (TD-035): popups at the top right of the screen and a "recent"
  list on the left side of the system menu (Esc; not the Tab main menu, whose commands it would hide). The content comes from ap/messages.lua (runtime.messages).

  Host: Overlay_0 of WBP_OverAllLayout_C, the game's persistent root layout (it owns every UI stack
  and survives map changes). Widgets added after the game's stacks draw on top of them. They are
  plain UMG widgets built with StaticConstructObject (outer: the layout's WidgetTree), created once
  and collapsed when not needed; if the layout is ever recreated they are built again.

  Read-only: no input is taken, so nothing changes in the game's menu navigation.
  System menu open: the active widget of the overall layout's Stack_System stack is
  WBP_SystemMenuLayout_C (seen in game; the Tab main menu is WBP_MainMenuLayout_C in the same stack).
  WBP_QuestNotice_C.m_IsOpenSystemMenu was tried first and stays false (2026-11-09).
  Disable with config/overlay.txt containing "off"; "dump" also logs the widgets shown in the
  system stacks (layout research). Any UI error disables the overlay for the
  session after logging it once; it never raises into the game.
]]

local fs = require("util.fs")
local log = require("util.log")
local W = require("ui.widgets")
local Messages = require("ap.messages")

local C, VIS, HALIGN, VALIGN = W.C, W.VIS, W.HALIGN, W.VALIGN
local valid, safe, try = W.valid, W.safe, W.try

local overlay = {
    enabled = true,
    broken = nil,
    runtime = nil,
    research = false,
    on_title = false,
    ticks = 0,
    host = nil, host_addr = nil, outer = nil,
    next_search = 0,
    font_src = nil,
    toast = nil,          -- { box, rows = { { border, text, shown_key, alpha } } }
    menu = nil,           -- { border, box, header, rows = { { size, text, key } } }
    menu_open = false,
    menu_version = -1,    -- messages.version shown in the list
    menu_messages = nil,  -- messages object shown (replaced on a new binding)
    menu_rows_wanted = 0,
    stacks = nil,         -- Stack_System* widgets of the overall layout
    last_stack_classes = nil,
    hidden = true,
    avail_h = nil,
}

-- Layout (design units of the game's ScaleBox, about 1920x1080).
-- Texts are cut to max_chars (no auto-wrap: a wrapped text in an unconstrained slot can measure
-- zero width) and every box clips to its bounds.
local TOAST = { right = 40, top = 40, width = 760, size = 20, rows = 4, gap = 6, max_chars = 60 }
local MENU = { left = 32, top = 110, bottom = 90, width = 520, size = 16, row_h = 28, header_h = 44, max_chars = 40 }
local CLIP_TO_BOUNDS = 1  -- EWidgetClipping::ClipToBounds

local KIND_COLORS = {
    item = { R = 1, G = 1, B = 1, A = 1 },
    gil = { R = 1.0, G = 0.92, B = 0.45, A = 1 },
    zone = { R = 0.50, G = 1.0, B = 0.60, A = 1 },
    shop = { R = 1.0, G = 0.78, B = 0.30, A = 1 },
    death = { R = 1.0, G = 0.42, B = 0.40, A = 1 },
    goal = { R = 1.0, G = 0.80, B = 0.25, A = 1 },
    hint = { R = 0.45, G = 0.90, B = 1.0, A = 1 },
    chat = { R = 0.80, G = 0.80, B = 0.85, A = 1 },
}
local BG = { R = 0.02, G = 0.03, B = 0.08, A = 0.72 }
local MENU_BG = { R = 0.02, G = 0.03, B = 0.08, A = 0.80 }
local HEADER_COLOR = { R = 0.75, G = 0.85, B = 1.0, A = 1 }
local OVERFLOW_ELLIPSIS = 1  -- ETextOverflowPolicy::Ellipsis

local function fail(what, err)
    overlay.broken = string.format("%s: %s", what, tostring(err))
    log.error("OVERLAY disabled for this session (%s)", overlay.broken)
    pcall(function()
        if overlay.toast then try(overlay.toast.box, "SetVisibility", VIS.Collapsed) end
        if overlay.menu then try(overlay.menu.border, "SetVisibility", VIS.Collapsed) end
    end)
end

-- Font --------------------------------------------------------------------

--- A live game text block using the ADVText font (the game's dialog/menu font, TD-035).
local function find_font_source()
    local fallback
    for _, cls in ipairs({ "CommonTextBlock", "TextBlock" }) do
        for _, t in ipairs(safe(function() return FindAllOf(cls) end) or {}) do
            local fn = safe(function() return t:GetFullName() end) or ""
            if not fn:find("Default__", 1, true) then
                local font = safe(function() return t.Font.FontObject:GetFullName() end) or ""
                if font:find("ADVText", 1, true) then
                    if fn:find("/Engine/Transient", 1, true) then return t, fn, font end
                    fallback = fallback or { t, fn, font }
                end
            end
        end
    end
    if fallback then return fallback[1], fallback[2], fallback[3] end
    return nil
end

local function make_text(text, size, color)
    local t = W.make_text(overlay.outer, text, size, color, overlay.font_src)
    pcall(function() t.Font.OutlineSettings.OutlineSize = 1 end)
    -- Our own first text block keeps the font for every later row (the game's may be destroyed).
    if not overlay.own_font then overlay.own_font = true; overlay.font_src = t end
    return t
end

-- Host --------------------------------------------------------------------

local function host_alive()
    return overlay.host ~= nil and valid(overlay.host) and W.addr(overlay.host) == overlay.host_addr
end

local function overlay_height()
    local h
    pcall(function()
        local geo = overlay.host:GetCachedGeometry()
        local size = StaticFindObject("/Script/UMG.Default__SlateBlueprintLibrary"):GetLocalSize(geo)
        if size and size.Y and size.Y > 100 then h = size.Y end
    end)
    return h
end

local function add_to_overlay(widget, halign, valign, padding)
    local slot = overlay.host:AddChildToOverlay(widget)
    if not slot then error("AddChildToOverlay failed") end
    slot:SetHorizontalAlignment(halign)
    slot:SetVerticalAlignment(valign)
    slot:SetPadding(padding)
    return slot
end

local function build_toast()
    local box = W.construct(C.VerticalBox, overlay.outer)
    local rows = {}
    for i = 1, TOAST.rows do
        local border = W.construct(C.Border, overlay.outer)
        try(border, "SetBrushColor", BG)
        try(border, "SetPadding", { Left = 14, Top = 6, Right = 14, Bottom = 6 })
        local text = make_text("", TOAST.size, KIND_COLORS.item)
        local size = W.construct(C.SizeBox, overlay.outer)
        try(size, "SetMaxDesiredWidth", TOAST.width)
        try(size, "SetClipping", CLIP_TO_BOUNDS)
        try(size, "SetContent", text)
        try(border, "SetContent", size)
        local slot = box:AddChildToVerticalBox(border)
        pcall(function()
            slot:SetHorizontalAlignment(HALIGN.Right)
            slot:SetPadding({ Left = 0, Top = i > 1 and TOAST.gap or 0, Right = 0, Bottom = 0 })
        end)
        try(border, "SetVisibility", VIS.Collapsed)
        rows[i] = { border = border, text = text, key = nil, kind = nil, alpha = nil }
    end
    add_to_overlay(box, HALIGN.Right, VALIGN.Top, { Left = 0, Top = TOAST.top, Right = TOAST.right, Bottom = 0 })
    try(box, "SetVisibility", VIS.HitTestInvisible)
    overlay.toast = { box = box, rows = rows }
end

local function build_menu()
    local border = W.construct(C.Border, overlay.outer)
    try(border, "SetBrushColor", MENU_BG)
    try(border, "SetPadding", { Left = 16, Top = 10, Right = 16, Bottom = 10 })
    local box = W.construct(C.VerticalBox, overlay.outer)
    local header = make_text("Archipelago - recent", MENU.size + 3, HEADER_COLOR)
    local hsize = W.construct(C.SizeBox, overlay.outer)
    try(hsize, "SetHeightOverride", MENU.header_h - 10)
    try(hsize, "SetContent", header)
    box:AddChildToVerticalBox(hsize)
    try(border, "SetContent", box)
    local sizer = W.construct(C.SizeBox, overlay.outer)
    try(sizer, "SetWidthOverride", MENU.width)
    try(sizer, "SetClipping", CLIP_TO_BOUNDS)
    try(sizer, "SetContent", border)
    add_to_overlay(sizer, HALIGN.Left, VALIGN.Top, { Left = MENU.left, Top = MENU.top, Right = 0, Bottom = 0 })
    try(sizer, "SetVisibility", VIS.Collapsed)
    overlay.menu = { border = sizer, box = box, header = header, rows = {} }
end

local function ensure_host()
    if host_alive() then return true end
    if overlay.host then
        log.info("OVERLAY: game layout replaced; rebuilding the message widgets")
        overlay.host, overlay.toast, overlay.menu, overlay.stacks = nil, nil, nil, nil
        overlay.own_font, overlay.font_src = nil, nil
    end
    if overlay.ticks < overlay.next_search then return false end
    overlay.next_search = overlay.ticks + 10
    local layout = FindFirstOf("WBP_OverAllLayout_C")
    if not valid(layout) then return false end
    local root = safe(function() return layout.WidgetTree.RootWidget end)
    local host = W.find_widget(root, "Overlay_0")
    if not valid(host) then return false end
    local src, src_name, font = find_font_source()
    if not src then
        if not overlay.font_warned then
            log.warn("OVERLAY: no game text with the ADVText font found yet; waiting")
            overlay.font_warned = true
        end
        return false
    end
    overlay.font_src = src
    overlay.host, overlay.host_addr, overlay.outer = host, W.addr(host), layout.WidgetTree
    local ok, err = pcall(function()
        build_toast()
        build_menu()
    end)
    if not ok then
        fail("building widgets", err)
        return false
    end
    overlay.avail_h = overlay_height()
    log.info("OVERLAY built in %s (font from %s, %s; overlay height %s)", W.name_of(host), src_name, font,
        tostring(overlay.avail_h))
    return true
end

-- Popups ------------------------------------------------------------------

local function update_toast(messages)
    local vis = messages:visible(overlay.ticks / 10)
    for i, row in ipairs(overlay.toast.rows) do
        local v = vis[i]
        if v then
            if row.key ~= v.entry.key then
                row.key = v.entry.key
                try(row.text, "SetText", FText(Messages.shorten(v.entry.text, TOAST.max_chars)))
                log.info("OVERLAY popup: %s", v.entry.text)
                if row.kind ~= v.entry.kind then
                    row.kind = v.entry.kind
                    try(row.text, "SetColorAndOpacity", W.slate_color(KIND_COLORS[v.entry.kind] or KIND_COLORS.item))
                end
                try(row.border, "SetVisibility", VIS.HitTestInvisible)
            end
            local a = math.floor(v.alpha * 10 + 0.5) / 10
            if a ~= row.alpha then
                row.alpha = a
                try(row.border, "SetRenderOpacity", a)
            end
        elseif row.key then
            row.key = nil
            try(row.border, "SetVisibility", VIS.Collapsed)
        end
    end
end

-- Pause-menu list -----------------------------------------------------------

local SYSTEM_STACKS = { "Stack_System", "Stack_System_Front1", "Stack_System_Front2" }

--- Classes of the widgets active in the system stacks ("" when a stack shows nothing).
local function stack_classes()
    if not overlay.stacks then
        overlay.stacks = {}
        local root = safe(function() return overlay.outer.RootWidget end)
        for _, name in ipairs(SYSTEM_STACKS) do overlay.stacks[name] = W.find_widget(root, name) end
    end
    local out = {}
    for _, name in ipairs(SYSTEM_STACKS) do
        local st = overlay.stacks[name]
        local active = valid(st) and safe(function() return st:GetActiveWidget() end)
        out[#out + 1] = valid(active) and W.cls_name(active) or ""
    end
    return out
end

local SYSTEM_MENU_CLASS = "WBP_SystemMenuLayout_C"

local function menu_is_open()
    local classes = stack_classes()
    local open = false
    for _, c in ipairs(classes) do
        if c == SYSTEM_MENU_CLASS then open = true end
    end
    if overlay.research then
        local sig = table.concat(classes, " | ")
        if sig ~= overlay.last_stack_classes then
            overlay.last_stack_classes = sig
            log.info("OVERLAY dump: system stacks [%s], system menu %s", sig, open and "open" or "closed")
        end
    end
    return open
end

local function menu_row()
    local text = make_text("", MENU.size, KIND_COLORS.item)
    pcall(function() text:SetTextOverflowPolicy(OVERFLOW_ELLIPSIS) end)
    local size = W.construct(C.SizeBox, overlay.outer)
    try(size, "SetHeightOverride", MENU.row_h)
    try(size, "SetWidthOverride", MENU.width - 32)
    try(size, "SetClipping", CLIP_TO_BOUNDS)
    try(size, "SetContent", text)
    overlay.menu.box:AddChildToVerticalBox(size)
    return { size = size, text = text, key = nil, kind = nil }
end

local function refresh_menu(messages)
    local avail = (overlay.avail_h or overlay_height() or 1080) - MENU.top - MENU.bottom
    local n = Messages.fit_count(avail - 20, MENU.row_h, MENU.header_h)
    local entries = messages:recent(n)
    local rows = overlay.menu.rows
    while #rows < math.min(n, math.max(#entries, 1)) do rows[#rows + 1] = menu_row() end
    for i, row in ipairs(rows) do
        local e = entries[i]
        if i == 1 and not e then
            if row.key ~= "" then
                row.key = ""
                try(row.text, "SetText", FText("No Archipelago message yet"))
                try(row.text, "SetColorAndOpacity", W.slate_color(KIND_COLORS.chat))
                row.kind = "chat"
            end
            try(row.size, "SetVisibility", VIS.HitTestInvisible)
        elseif e then
            if row.key ~= e.key then
                row.key = e.key
                try(row.text, "SetText", FText(os.date("%H:%M", e.t) .. "  " .. Messages.shorten(e.text, MENU.max_chars)))
                if row.kind ~= e.kind then
                    row.kind = e.kind
                    try(row.text, "SetColorAndOpacity", W.slate_color(KIND_COLORS[e.kind] or KIND_COLORS.item))
                end
            end
            try(row.size, "SetVisibility", VIS.HitTestInvisible)
        else
            row.key = nil
            try(row.size, "SetVisibility", VIS.Collapsed)
        end
    end
    overlay.menu_version = messages.version
    overlay.menu_messages = messages
    if n ~= overlay.menu_rows_wanted then
        overlay.menu_rows_wanted = n
        log.info("OVERLAY: system-menu list shows %d row(s) (height %s)", n, tostring(overlay.avail_h))
    end
end

local function update_menu(messages)
    local open = menu_is_open()
    if open ~= overlay.menu_open then
        overlay.menu_open = open
        if open then
            overlay.avail_h = overlay_height() or overlay.avail_h
            refresh_menu(messages)
            try(overlay.menu.border, "SetVisibility", VIS.HitTestInvisible)
        else
            try(overlay.menu.border, "SetVisibility", VIS.Collapsed)
        end
    elseif open and (messages.version ~= overlay.menu_version or messages ~= overlay.menu_messages) then
        refresh_menu(messages)
    end
end

-- Main --------------------------------------------------------------------

local function hide_all()
    if overlay.hidden then return end
    overlay.hidden = true
    if overlay.toast then
        for _, row in ipairs(overlay.toast.rows) do
            row.key = nil
            try(row.border, "SetVisibility", VIS.Collapsed)
        end
    end
    if overlay.menu then try(overlay.menu.border, "SetVisibility", VIS.Collapsed) end
    overlay.menu_open = false
end

local function tick()
    overlay.ticks = overlay.ticks + 1
    local rt = overlay.runtime
    local active = not overlay.on_title and rt.session ~= nil and rt.session:is_bound()
    if not active then
        hide_all()
        return
    end
    if not ensure_host() then return end
    overlay.hidden = false
    local messages = rt.messages
    local ok, err = pcall(update_toast, messages)
    if not ok then return fail("popups", err) end
    ok, err = pcall(update_menu, messages)
    if not ok then return fail("system-menu list", err) end
end

function overlay.init(mod_dir, runtime)
    overlay.runtime = runtime
    local cfg = fs.read_all(fs.join(mod_dir, "config", "overlay.txt"))
    if cfg and cfg:match("^%s*off") then overlay.enabled = false end
    overlay.research = cfg ~= nil and cfg:match("^%s*dump") ~= nil
    log.info("In-game messages overlay: %s", overlay.enabled and "on" or "off")
end

function overlay.on_game_state(full_name)
    local title = tostring(full_name):find("/Map/Title/", 1, true) ~= nil
    if title and not overlay.on_title then
        -- Popups of the previous game are not carried to the next one (they stay in the list).
        if overlay.runtime and overlay.runtime.messages then overlay.runtime.messages:clear_popups() end
    end
    overlay.on_title = title
end

function overlay.start()
    if not overlay.enabled then return end
    LoopInGameThreadWithDelay(100, function()
        if overlay.broken then return end
        local ok, err = pcall(tick)
        if not ok then fail("tick", err) end
    end)
end

return overlay
