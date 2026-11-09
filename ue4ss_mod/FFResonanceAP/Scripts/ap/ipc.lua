--[[
  File-based IPC with the ffr_bridge process (TD-002). Both sides write complete JSON snapshots
  atomically (tmp + rename) and poll each other's file, so a lost or repeated read is harmless.

    ipc/bridge_state.json  written by the bridge: connection status, seed/slot, the full
                           server-ordered list of received items, server-checked locations,
                           recent server messages.
    ipc/game_state.json    written by the mod: bound seed/slot, all checked locations,
                           applied item count, goal flag.
]]

local json = require("lib.json")
local fs = require("util.fs")

local ipc = { dir = nil }

ipc.PROTOCOL = 1

function ipc.init(dir)
    ipc.dir = dir
end

--- Returns the decoded bridge state, or nil (+ reason) if absent/invalid.
function ipc.read_bridge_state()
    local raw = fs.read_all_recover(fs.join(ipc.dir, "bridge_state.json"))
    if not raw then return nil, "absent" end
    local ok, state = pcall(json.decode, raw)
    if not ok or type(state) ~= "table" then return nil, "invalid json: " .. tostring(state) end
    -- Top-level JSON nulls (seed_name/slot_name before authentication, request_seq...) become nil:
    -- json.null is a truthy sentinel and must not pass "if st.seed_name then" checks.
    for k, v in pairs(state) do
        if v == json.null then state[k] = nil end
    end
    if state.protocol ~= ipc.PROTOCOL then
        return nil, "protocol mismatch (bridge " .. tostring(state.protocol) .. ", mod " .. ipc.PROTOCOL .. ")"
    end
    return state
end

function ipc.write_game_state(state)
    state.protocol = ipc.PROTOCOL
    return fs.write_atomic(fs.join(ipc.dir, "game_state.json"), json.encode(state))
end

--- A JSON-file store for ap.session: <dir>/<key>.json (+ .bak with the previous version).
--- Loading uses the newest candidate that decodes; a damaged file is never fatal while a valid
--- older copy exists. `on_warning(msg)` is told when a fallback copy was used.
function ipc.file_store(dir, on_warning)
    return {
        load = function(key)
            local path = fs.join(dir, key .. ".json")
            local candidates = fs.read_candidates(path)
            if #candidates == 0 then return nil end
            for i, c in ipairs(candidates) do
                local ok, t = pcall(json.decode, c.data)
                if ok and type(t) == "table" then
                    if i > 1 and on_warning then
                        on_warning("session state " .. key .. ".json unreadable; recovered from " .. c.source)
                    end
                    return t
                end
            end
            error("all copies of session state " .. key .. ".json are corrupted")
        end,
        save = function(key, t)
            local ok, err = fs.write_atomic_with_backup(fs.join(dir, key .. ".json"), json.encode(t))
            if not ok then error("cannot persist session state: " .. tostring(err)) end
        end,
    }
end

return ipc
