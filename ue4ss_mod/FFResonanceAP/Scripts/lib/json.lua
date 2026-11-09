--[[
  Minimal JSON encoder/decoder for the FFResonanceAP UE4SS mod.
  Written for this project (no third-party code). Pure Lua 5.4, no C modules.

  json.encode(value [, pretty]) -> string
    - tables with only consecutive integer keys 1..n are arrays, other tables are objects
    - an empty table encodes as an array ("[]"); json.empty_object encodes as "{}"
    - object keys are sorted so the output is deterministic
    - NaN/inf are rejected (raise an error)
  json.decode(text) -> value
    - JSON null decodes to json.null (a sentinel), so arrays keep their length
]]

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end, __name = "json.null" })
json.empty_object = setmetatable({}, { __name = "json.empty_object" })

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if math.type(k) ~= "integer" or k < 1 then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

local encode_value

local function encode_table(t, pretty, indent, seen)
    if t == json.null then return "null" end
    if t == json.empty_object then return "{}" end
    if seen[t] then error("json.encode: circular reference") end
    seen[t] = true
    local nl, ind, ind2, sep = "", "", "", ":"
    if pretty then
        nl = "\n"; ind = string.rep("  ", indent); ind2 = string.rep("  ", indent + 1); sep = ": "
    end
    local out = {}
    local arr, n = is_array(t)
    local result
    if arr then
        if n == 0 then
            seen[t] = nil
            return "[]"
        end
        for i = 1, n do
            out[i] = ind2 .. encode_value(t[i], pretty, indent + 1, seen)
        end
        result = "[" .. nl .. table.concat(out, "," .. nl) .. nl .. ind .. "]"
    else
        local keys = {}
        for k in pairs(t) do
            local kt = type(k)
            if kt ~= "string" and kt ~= "number" then
                error("json.encode: unsupported key type " .. kt)
            end
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for i, k in ipairs(keys) do
            out[i] = ind2 .. escape_string(tostring(k)) .. sep .. encode_value(t[k], pretty, indent + 1, seen)
        end
        result = "{" .. nl .. table.concat(out, "," .. nl) .. nl .. ind .. "}"
    end
    seen[t] = nil
    return result
end

encode_value = function(v, pretty, indent, seen)
    local vt = type(v)
    if v == nil then
        return "null"
    elseif vt == "boolean" then
        return v and "true" or "false"
    elseif vt == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("json.encode: cannot encode NaN or infinity")
        end
        if math.type(v) == "integer" then return string.format("%d", v) end
        return string.format("%.17g", v)
    elseif vt == "string" then
        return escape_string(v)
    elseif vt == "table" then
        return encode_table(v, pretty, indent, seen)
    end
    error("json.encode: unsupported type " .. vt)
end

function json.encode(v, pretty)
    return encode_value(v, pretty, 0, {})
end

-- Decoder ---------------------------------------------------------------

local function decode_error(str, pos, msg)
    error(string.format("json.decode: %s at position %d", msg, pos), 0)
end

local function skip_ws(str, pos)
    return str:find("[^ \t\r\n]", pos) or (#str + 1)
end

local function utf8_from_codepoint(cp)
    return utf8.char(cp)
end

local decode_value

local function decode_string(str, pos)
    -- pos points at the opening quote
    local buf = {}
    local i = pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then decode_error(str, i, "unterminated string") end
        if c == '"' then
            return table.concat(buf), i + 1
        elseif c == "\\" then
            local e = str:sub(i + 1, i + 1)
            local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
            if map[e] then
                buf[#buf + 1] = map[e]
                i = i + 2
            elseif e == "u" then
                local hex = str:sub(i + 2, i + 5)
                if not hex:match("^%x%x%x%x$") then decode_error(str, i, "invalid \\u escape") end
                local cp = tonumber(hex, 16)
                i = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local lo = str:match("^\\u(%x%x%x%x)", i)
                    if not lo then decode_error(str, i, "missing low surrogate") end
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (tonumber(lo, 16) - 0xDC00)
                    i = i + 6
                end
                buf[#buf + 1] = utf8_from_codepoint(cp)
            else
                decode_error(str, i, "invalid escape")
            end
        elseif c:byte() < 0x20 then
            decode_error(str, i, "control character in string")
        else
            local j = str:find('["\\%c]', i)
            if not j then decode_error(str, i, "unterminated string") end
            buf[#buf + 1] = str:sub(i, j - 1)
            i = j
        end
    end
end

local function decode_number(str, pos)
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num or num == "" or num == "-" then decode_error(str, pos, "invalid number") end
    local v
    if num:find("[%.eE]") then
        v = tonumber(num)
    else
        v = math.tointeger(tonumber(num)) or tonumber(num)
    end
    if v == nil then decode_error(str, pos, "invalid number") end
    return v, pos + #num
end

decode_value = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "expected string key") end
            local key
            key, pos = decode_string(str, pos)
            pos = skip_ws(str, pos)
            if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
            local val
            val, pos = decode_value(str, pos + 1)
            obj[key] = val
            pos = skip_ws(str, pos)
            local d = str:sub(pos, pos)
            if d == "}" then return obj, pos + 1 end
            if d ~= "," then decode_error(str, pos, "expected ',' or '}'") end
            pos = skip_ws(str, pos + 1)
        end
    elseif c == "[" then
        local arr = {}
        pos = skip_ws(str, pos + 1)
        if str:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local val
            val, pos = decode_value(str, pos)
            arr[#arr + 1] = val
            pos = skip_ws(str, pos)
            local d = str:sub(pos, pos)
            if d == "]" then return arr, pos + 1 end
            if d ~= "," then decode_error(str, pos, "expected ',' or ']'") end
            pos = pos + 1
        end
    elseif c == '"' then
        return decode_string(str, pos)
    elseif c == "-" or c:match("%d") then
        return decode_number(str, pos)
    elseif str:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif str:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif str:sub(pos, pos + 3) == "null" then
        return json.null, pos + 4
    end
    decode_error(str, pos, "unexpected character '" .. c .. "'")
end

function json.decode(str)
    if type(str) ~= "string" then error("json.decode: expected string", 2) end
    local v, pos = decode_value(str, 1)
    pos = skip_ws(str, pos)
    if pos <= #str then decode_error(str, pos, "trailing garbage") end
    return v
end

return json
