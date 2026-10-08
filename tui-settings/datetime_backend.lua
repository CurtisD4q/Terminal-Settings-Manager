-- datetime_backend.lua — clock settings via timedatectl.
--   Automatic time (NTP): read/set with timedatectl (the set needs root, so
--     toggling it may fail without privilege — handled gracefully).
--   Time zone: read current, and list/set available zones.
--   Current date/time: read-only display.
local M = {}
local util = require("util")

local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local TDC_OK = nil
local function have_timedatectl()
	if TDC_OK == nil then
		local out = shell("command -v timedatectl")
		TDC_OK = (out ~= nil and out:match("%S") ~= nil)
	end
	return TDC_OK
end
M.available = have_timedatectl

-- Parse `timedatectl show` (machine-readable key=value form)
local function show()
	local out, ok = shell("timedatectl show")
	if not ok or not out then
		return nil
	end
	local t = {}
	for k, v in out:gmatch("(%w+)=([^\n]*)") do
		t[k] = v
	end
	return t
end

function M.get_ntp()
	if not have_timedatectl() then
		return nil, "timedatectl not found"
	end
	local t = show()
	if not t then
		return nil, "unavailable"
	end
	return t.NTP == "yes", nil
end

-- NOTE: setting NTP needs root; without it, the command fails and we report
-- that rather than silently pretending it worked.
function M.set_ntp(on)
	if not have_timedatectl() then
		return false, "timedatectl not found"
	end
	local _, ok = shell(("timedatectl set-ntp %s"):format(on and "true" or "false"))
	if ok then
		return true, nil
	end
	return false, "needs root"
end

function M.get_timezone()
	if not have_timedatectl() then
		return nil, "timedatectl not found"
	end
	local t = show()
	if not t or not t.Timezone then
		return nil, "unavailable"
	end
	return t.Timezone, nil
end

-- The full zone list is long; we return it so the UI can cycle. Reading it is
-- cheap enough but we cache it since it never changes during a session.
local ZONES = nil
function M.list_timezones()
	if ZONES then
		return ZONES
	end
	if not have_timedatectl() then
		return nil, "timedatectl not found"
	end
	local out, ok = shell("timedatectl list-timezones")
	if not ok or not out then
		return nil, "unavailable"
	end
	ZONES = {}
	for z in out:gmatch("[^\n]+") do
		ZONES[#ZONES + 1] = z
	end
	if #ZONES == 0 then
		ZONES = nil
		return nil, "unavailable"
	end
	return ZONES
end

function M.set_timezone(tz)
	if not have_timedatectl() then
		return false, "timedatectl not found"
	end
	local _, ok = shell(("timedatectl set-timezone %s"):format(tz))
	if ok then
		return true, nil
	end
	return false, "needs root"
end

-- current wall-clock time as a display string (always available, no tool)
function M.now()
	return os.date("%Y-%m-%d %H:%M")
end

return M
