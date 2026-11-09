--[[
  Connection settings for the title-screen "Archipelago Options" panel (TD-032). Pure Lua (unit-tested).

    config/connection.json    {server, port, slot}: saved by the panel, prefills it at startup.
                              NEVER contains the password (owner decision, 2026-11-09).
    ipc/connect_request.json  {protocol, seq, address, slot, password}: one request per click on
                              Connect; the bridge reads it, deletes it and (re)connects.

  The bridge connects only after Connect is pressed in the current game session: nothing is sent
  automatically at startup, so a seed is never applied to a save the player did not choose.
]]

local json = require("lib.json")
local fs = require("util.fs")

local connconfig = {}

connconfig.PROTOCOL = 1
connconfig.MAX_SLOT_LENGTH = 16           -- Archipelago slot names are at most 16 characters
connconfig.DEFAULTS = { server = "localhost", port = 38281, slot = "" }
connconfig.STALE_SECONDS = 15             -- the bridge rewrites bridge_state.json every 5 s

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split a server field into scheme ("ws"/"wss"/nil), host and an embedded port (or nil).
--- Accepts "host", "host:port", "ws://host[:port][/path]", "wss://...", "[ipv6]:port".
function connconfig.parse_server(server)
    local s = trim(server)
    local scheme = nil
    local sch, rest = s:match("^(%a[%w+.-]*)://(.*)$")
    if sch then
        scheme = sch:lower()
        if scheme == "archipelago" then scheme = "ws" end
        s = rest
    end
    s = s:gsub("/.*$", "")
    local host, port
    if s:sub(1, 1) == "[" then
        host, port = s:match("^(%[[^%]]*%])(.*)$")
        if not host then return scheme, s, nil end
        port = port:match("^:(%d+)$")
    else
        host, port = s:match("^([^:]*):(%d+)$")
        if not host then host = s end
    end
    return scheme, host, port and tonumber(port) or nil
end

--- Validate panel fields. Returns cfg {server, port, slot, scheme, host} or nil, {error messages}.
--- `port` may be a string (from the text box) or a number; an empty Port field falls back to a port
--- typed in the server field.
function connconfig.validate(fields)
    local errors = {}
    local scheme, host, embedded_port = connconfig.parse_server(fields.server)
    if scheme ~= nil and scheme ~= "ws" and scheme ~= "wss" then
        errors[#errors + 1] = "Server: use ws:// or wss:// (or no prefix)"
    end
    if host == nil or host == "" then
        errors[#errors + 1] = "Server: enter an address (e.g. archipelago.gg or localhost)"
    elseif host:find("[%s\"'\\]") then
        errors[#errors + 1] = "Server: the address cannot contain spaces or quotes"
    end
    local port_text = trim(fields.port)
    local port
    if port_text == "" then
        port = embedded_port
    else
        port = port_text:match("^%d+$") and tonumber(port_text) or nil
        if port == nil then errors[#errors + 1] = "Port: digits only" end
    end
    if port_text == "" and port == nil then
        errors[#errors + 1] = "Port: enter the room's port (1-65535)"
    elseif port ~= nil and (port < 1 or port > 65535) then
        errors[#errors + 1] = "Port: must be between 1 and 65535"
    end
    local slot = trim(fields.slot)
    if slot == "" then
        errors[#errors + 1] = "Slot: enter your slot name (the 'name' in your YAML)"
    elseif #slot > connconfig.MAX_SLOT_LENGTH * 4 or utf8.len(slot) == nil or utf8.len(slot) > connconfig.MAX_SLOT_LENGTH then
        errors[#errors + 1] = "Slot: at most 16 characters"
    end
    if #errors > 0 then return nil, errors end
    local server = (scheme and (scheme .. "://") or "") .. host
    return { server = server, port = port, slot = slot, scheme = scheme, host = host }
end

--- Address passed to the bridge: "wss://host:port" when a scheme was typed, else "host:port"
--- (the bridge tries ws:// then falls back to wss://, like the Archipelago text client).
function connconfig.address(cfg)
    return (cfg.scheme and (cfg.scheme .. "://") or "") .. cfg.host .. ":" .. tostring(cfg.port)
end

--- Load saved settings (defaults for anything missing or unreadable).
function connconfig.load(path)
    local out = { server = connconfig.DEFAULTS.server, port = connconfig.DEFAULTS.port, slot = connconfig.DEFAULTS.slot }
    local raw = fs.read_all_recover(path)
    if not raw then return out, "absent" end
    local ok, t = pcall(json.decode, raw)
    if not ok or type(t) ~= "table" then return out, "unreadable" end
    if type(t.server) == "string" then out.server = t.server end
    if math.type(t.port) == "integer" and t.port >= 1 and t.port <= 65535 then out.port = t.port end
    if type(t.slot) == "string" then out.slot = t.slot end
    return out
end

--- Save {server, port, slot}. Only these three keys are written: never the password.
function connconfig.save(path, cfg)
    return fs.write_atomic(path, json.encode({ server = cfg.server, port = cfg.port, slot = cfg.slot }, true))
end

--- Request sequence number: grows with every click, also across game restarts (time based).
function connconfig.next_seq(last, now)
    local base = math.floor((now or os.time()) * 1000)
    if last and last >= base then return last + 1 end
    return base
end

--- `game_session` = this game launch's id (also written in game_state.json): the bridge disconnects
--- and forgets the password when the game that sent the request is closed or restarted.
function connconfig.build_request(cfg, password, seq, game_session)
    return {
        protocol = connconfig.PROTOCOL,
        seq = seq,
        address = connconfig.address(cfg),
        slot = cfg.slot,
        password = (password ~= nil and password ~= "") and password or nil,
        game_session = game_session,
    }
end

--- A launch id that differs between game launches.
function connconfig.new_game_session(now, clock)
    return string.format("%d-%d", now or os.time(), math.floor((clock or os.clock()) * 1000000) % 1000000000)
end

--- Status shown under the title button: "Connected as <slot>" (kind "ok") only when the bridge is
--- authenticated for the Connect pressed in this game session; otherwise "Disconnected" ("error").
function connconfig.connection_label(state, now, armed_seq)
    now = now or os.time()
    if type(state) == "table" and armed_seq ~= nil and state.request_seq == armed_seq and state.status == "ready"
        and type(state.updated) == "number" and now - state.updated <= connconfig.STALE_SECONDS then
        return "Connected as " .. tostring(state.slot_name or "?"), "ok"
    end
    return "Disconnected", "error"
end

function connconfig.write_request(ipc_dir, request)
    return fs.write_atomic(fs.join(ipc_dir, "connect_request.json"), json.encode(request))
end

local STATUS_TEXT = {
    waiting_for_settings = "Bridge running - waiting for settings",
    disconnected = "Disconnected",
    connecting = "Connecting...",
    connected = "Connected - authenticating...",
    ready = "Connected",
    reconnecting = "Connection lost - reconnecting...",
    error = "Error",
}

--- Human-readable bridge status for the panel.
--- `state` = decoded bridge_state.json (or nil), `problem` = why it is missing, `pending_seq` = the
--- last request sent by this panel (nil if none). Returns text, kind ("ok"|"busy"|"error"|"idle").
function connconfig.describe_status(state, problem, now, pending_seq)
    now = now or os.time()
    if state == nil then
        if problem == "absent" or problem == nil then
            return "Bridge not running - start ffr_bridge, then press Connect", "error"
        end
        return "Bridge state unreadable: " .. tostring(problem), "error"
    end
    if type(state.updated) == "number" and now - state.updated > connconfig.STALE_SECONDS then
        return "Bridge not responding (last update " .. tostring(now - state.updated) .. " s ago)", "error"
    end
    if pending_seq ~= nil and state.request_seq ~= pending_seq then
        return "Sending settings to the bridge...", "busy"
    end
    local status = tostring(state.status)
    local text = STATUS_TEXT[status] or status
    local kind = "busy"
    if status == "ready" then
        kind = "ok"
        if state.slot_name then text = text .. " as " .. tostring(state.slot_name) end
    elseif status == "error" then
        kind = "error"
        if state.status_message and state.status_message ~= "" then text = text .. ": " .. tostring(state.status_message) end
    elseif status == "waiting_for_settings" or status == "disconnected" then
        kind = "idle"
    elseif state.status_message and state.status_message ~= "" and status ~= "connected" then
        text = text .. " (" .. tostring(state.status_message) .. ")"
    end
    return text, kind
end

return connconfig
