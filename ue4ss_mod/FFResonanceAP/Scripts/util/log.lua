--[[
  Logging for the FFResonanceAP mod.
  Writes to the UE4SS console/log (via print) and to <mod>/logs/ffr_ap.log.
  Never pass passwords or other secrets to these functions.
]]

local fs = require("util.fs")

local log = {
    file = nil,       -- absolute path of the mod log file, set by log.init
    level = 2,        -- 1=debug 2=info 3=warn 4=error
}

local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }

function log.init(log_path, level)
    log.file = log_path
    log.level = level or log.level
end

local function emit(level, fmt, ...)
    if level < log.level then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = fmt .. " <format error: " .. tostring(msg) .. ">" end
    local line = string.format("[%s] [FFResonanceAP] [%s] %s", os.date("%Y-%m-%d %H:%M:%S"), LEVEL_NAMES[level], msg)
    print(line .. "\n")
    if log.file then fs.append(log.file, line .. "\n") end
end

function log.debug(fmt, ...) emit(1, fmt, ...) end
function log.info(fmt, ...) emit(2, fmt, ...) end
function log.warn(fmt, ...) emit(3, fmt, ...) end
function log.error(fmt, ...) emit(4, fmt, ...) end

return log
