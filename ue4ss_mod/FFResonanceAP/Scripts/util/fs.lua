--[[
  File helpers for the FFResonanceAP mod. Pure Lua; works in UE4SS (Windows / Proton)
  and in a stock Lua 5.4 interpreter (used by the offline tests).
]]

local fs = {}

--- Normalise a path to forward slashes, dropping any trailing slash.
function fs.normalize(path)
    local p = path:gsub("\\", "/")
    if #p > 1 then p = p:gsub("/+$", "") end
    return p
end

function fs.join(...)
    local parts = { ... }
    return fs.normalize(table.concat(parts, "/"))
end

function fs.dirname(path)
    local p = fs.normalize(path)
    return p:match("^(.*)/[^/]*$") or "."
end

function fs.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function fs.read_all(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("a")
    f:close()
    return data
end

--- Write `data` to `path` so readers never observe a half-written file.
--- Writes to `path .. ".tmp"`, flushes, then renames over the target.
--- On Windows os.rename fails when the target exists, so the target is removed first;
--- if the process dies in that window the previous content survives in `.tmp` and
--- `fs.read_all_recover` picks it up.
function fs.write_atomic(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, "open " .. tmp .. ": " .. tostring(err) end
    local ok, werr = f:write(data)
    if not ok then f:close() return false, "write " .. tmp .. ": " .. tostring(werr) end
    f:flush()
    f:close()
    local renamed, rerr = os.rename(tmp, path)
    if renamed then return true end
    -- Windows semantics: remove existing target and retry.
    os.remove(path)
    renamed, rerr = os.rename(tmp, path)
    if not renamed then return false, "rename " .. tmp .. " -> " .. path .. ": " .. tostring(rerr) end
    return true
end

--- Read a file written by write_atomic, falling back to the `.tmp` sibling when the
--- final file is missing (crash between remove and rename).
function fs.read_all_recover(path)
    local data = fs.read_all(path)
    if data ~= nil then return data end
    return fs.read_all(path .. ".tmp")
end

--- Like write_atomic, but the previous content is kept as `path .. ".bak"`.
--- Sequence: write .tmp; move current file to .bak; move .tmp to the final name.
function fs.write_atomic_with_backup(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, "open " .. tmp .. ": " .. tostring(err) end
    local ok, werr = f:write(data)
    if not ok then f:close() return false, "write " .. tmp .. ": " .. tostring(werr) end
    f:flush()
    f:close()
    if fs.exists(path) then
        os.remove(path .. ".bak")
        local moved, merr = os.rename(path, path .. ".bak")
        if not moved then return false, "backup " .. path .. ": " .. tostring(merr) end
    end
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then return false, "rename " .. tmp .. " -> " .. path .. ": " .. tostring(rerr) end
    return true
end

--- Candidate contents for a file written by write_atomic(_with_backup), most recent first:
--- the file itself, the pending .tmp (crash between the two renames), then the .bak.
function fs.read_candidates(path)
    local out = {}
    for _, suffix in ipairs({ "", ".tmp", ".bak" }) do
        local data = fs.read_all(path .. suffix)
        if data ~= nil then out[#out + 1] = { source = path .. suffix, data = data } end
    end
    return out
end

function fs.append(path, data)
    local f, err = io.open(path, "ab")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

return fs
