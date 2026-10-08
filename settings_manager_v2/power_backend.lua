-- power_backend.lua — battery status + power profile control.
--   Battery info: read from /sys/class/power_supply (no tools needed, always
--     present on laptops; a desktop with no battery just reports nil cleanly).
--   Power profiles: powerprofilesctl (power-profiles-daemon) — the same thing
--     GNOME's power panel uses. Falls back gracefully if not installed.
local M = {}
local util = require("util")

local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local v = f:read("*l")
	f:close()
	return v
end

-- find the first battery in sysfs (BAT0, BAT1, ...)
local BAT_PATH = nil
local function battery_path()
	if BAT_PATH ~= nil then
		return BAT_PATH or nil
	end
	local base = "/sys/class/power_supply"
	for _, name in ipairs(util.shell_lines("ls -1 " .. base)) do
		local t = read_file(base .. "/" .. name .. "/type")
		if t == "Battery" then
			BAT_PATH = base .. "/" .. name
			break
		end
	end
	if not BAT_PATH then
		BAT_PATH = false
	end
	return BAT_PATH or nil
end

-- returns { percent=74, status="Charging", present=true } or {present=false}
function M.battery()
	local p = battery_path()
	if not p then
		return { present = false }
	end
	local cap = read_file(p .. "/capacity")
	local status = read_file(p .. "/status")
	return {
		present = true,
		percent = cap and tonumber(cap) or nil,
		status = status or "Unknown",
	}
end

-- battery "health": design vs full-charge capacity, if the kernel exposes it
function M.battery_health()
	local p = battery_path()
	if not p then
		return nil
	end
	local full = read_file(p .. "/energy_full") or read_file(p .. "/charge_full")
	local design = read_file(p .. "/energy_full_design") or read_file(p .. "/charge_full_design")
	if full and design and tonumber(design) and tonumber(design) > 0 then
		return math.floor(tonumber(full) / tonumber(design) * 100 + 0.5)
	end
	return nil
end

-- ── power profiles (powerprofilesctl) ──────────────────────────────────────
local PPD_OK = nil
local function have_ppd()
	if PPD_OK == nil then
		local out = shell("command -v powerprofilesctl")
		PPD_OK = (out ~= nil and out:match("%S") ~= nil)
	end
	return PPD_OK
end
M.profiles_available = have_ppd

function M.get_profile()
	if not have_ppd() then
		return nil, "power-profiles-daemon not found"
	end
	local out, ok = shell("powerprofilesctl get")
	if not ok or not out then
		return nil, "unavailable"
	end
	local p = out:match("%S+")
	return p, nil
end

-- list available profiles, in the order powerprofilesctl reports them
function M.list_profiles()
	if not have_ppd() then
		return nil, "power-profiles-daemon not found"
	end
	local out, ok = shell("powerprofilesctl list")
	if not ok or not out then
		return nil, "unavailable"
	end
	local profiles = {}
	for line in (out .. "\n"):gmatch("(.-)\n") do
		-- lines look like "* balanced:" or "  performance:"
		local name = line:match("^[%*%s]*([%w%-]+):%s*$")
		if name then
			profiles[#profiles + 1] = name
		end
	end
	if #profiles == 0 then
		return nil, "no profiles"
	end
	return profiles, nil
end

function M.set_profile(name)
	if not have_ppd() then
		return false, "power-profiles-daemon not found"
	end
	local _, ok = shell(("powerprofilesctl set %s"):format(name))
	if ok then
		return true, nil
	end
	return false, "set failed"
end

return M
