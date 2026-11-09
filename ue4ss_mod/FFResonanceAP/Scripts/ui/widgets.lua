--[[
  Shared helpers for UMG widgets built at runtime (TD-032, TD-035): class paths, enums, safe calls,
  construction with StaticConstructObject, widget-tree search, text blocks with a copied game font.
  Used by ui/apmenu.lua (title screen) and ui/overlay.lua (in-game messages).
]]

local log = require("util.log")

local W = {}

W.C = {
    Button = "/Script/UMG.Button",
    TextBlock = "/Script/UMG.TextBlock",
    EditableTextBox = "/Script/UMG.EditableTextBox",
    VerticalBox = "/Script/UMG.VerticalBox",
    HorizontalBox = "/Script/UMG.HorizontalBox",
    Border = "/Script/UMG.Border",
    SizeBox = "/Script/UMG.SizeBox",
}

W.VIS = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
W.HALIGN = { Fill = 0, Left = 1, Center = 2, Right = 3 }
W.VALIGN = { Fill = 0, Top = 1, Center = 2, Bottom = 3 }

function W.safe(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

function W.valid(obj)
    return obj ~= nil and W.safe(function() return obj:IsValid() end) == true
end

function W.addr(obj)
    return W.safe(function() return obj:GetAddress() end)
end

function W.cls_name(obj)
    return W.safe(function() return obj:GetClass():GetFName():ToString() end) or "?"
end

function W.name_of(obj)
    return W.safe(function() return obj:GetFName():ToString() end) or "?"
end

function W.find_class(path)
    local c = StaticFindObject(path)
    if not W.valid(c) then error("class not found: " .. path) end
    return c
end

function W.construct(path, outer)
    local obj = StaticConstructObject(W.find_class(path), outer)
    if not W.valid(obj) then error("StaticConstructObject failed for " .. path) end
    return obj
end

function W.slate_color(c)
    return { SpecifiedColor = c, ColorUseRule = 0 }
end

--- Call obj:fname(...) and log a failure (never raises).
function W.try(obj, fname, ...)
    local args = table.pack(...)
    local ok, err = pcall(function() return obj[fname](obj, table.unpack(args, 1, args.n)) end)
    if not ok then log.warn("UI: %s.%s failed: %s", W.name_of(obj), fname, tostring(err)) end
    return ok
end

--- Depth-first search of a widget tree by widget name (panels, content widgets, user widgets).
function W.find_widget(widget, wanted, depth)
    depth = depth or 0
    if not W.valid(widget) or depth > 30 then return nil end
    if W.name_of(widget) == wanted then return widget end
    local count = W.safe(function() return widget:GetChildrenCount() end)
    if type(count) == "number" then
        for i = 0, count - 1 do
            local found = W.find_widget(W.safe(function() return widget:GetChildAt(i) end), wanted, depth + 1)
            if found then return found end
        end
    else
        local content = W.safe(function() return widget:GetContent() end)
        if W.valid(content) then
            local found = W.find_widget(content, wanted, depth + 1)
            if found then return found end
        end
    end
    return nil
end

--- A TextBlock with the font of `font_src` (a live game text block; the game ships no Slate font
--- files, so an unset font draws nothing) at `size`.
function W.make_text(outer, text, size, color, font_src)
    local t = W.construct(W.C.TextBlock, outer)
    if font_src and W.valid(font_src) then
        local ok, err = pcall(function() t:SetFont(font_src.Font) end)
        if not ok then log.warn("UI: copying the game font failed: %s", tostring(err)) end
    end
    pcall(function() t.Font.Size = size end)
    W.try(t, "SetText", FText(text))
    W.try(t, "SetColorAndOpacity", W.slate_color(color or { R = 1, G = 1, B = 1, A = 1 }))
    return t
end

return W
