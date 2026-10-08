-- display_backend.lua — real display control for a Sway/SwayFX session.
--   Outputs (resolution, refresh, scale, power) — via swaymsg (Sway's own IPC).
--   Brightness — brightnessctl.
--   Night light — wlsunset if present (absent on this system; reported as such).
--   Color profiles — via swaymsg output profile; scans common ICC directories.
-- Written against `swaymsg -t get_outputs -r` (JSON).
local M = {}
local util = require("util")

-- Command execution and JSON decoding go through util (single audited,
-- injection-safe implementation). shell() is shimmed to the (out, ok)
-- convention this file's call sites expect: util.shell returns (out, err),
-- so ok is (err == nil).
local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local have = util.have
local json_decode = util.json_decode

-- ── outputs via swaymsg ─────────────────────────────────────────────────────
local SWAY_OK = nil
local function have_sway()
	if SWAY_OK == nil then
		SWAY_OK = have("swaymsg")
	end
	return SWAY_OK
end
M.sway_available = have_sway

function M.get_outputs()
	if not have_sway() then
		return nil, "swaymsg not found"
	end
	local out, ok = shell("swaymsg -t get_outputs -r")
	if not ok or not out then
		return nil, "swaymsg failed"
	end
	local data = json_decode(out)
	if not data then
		return nil, "parse error"
	end
	local outputs = {}
	for _, o in ipairs(data) do
		local cm = o.current_mode or {}
		local modes = {}
		local seen = {}
		for _, m in ipairs(o.modes or {}) do
			local key = m.width .. "x" .. m.height .. "@" .. m.refresh
			if not seen[key] then
				seen[key] = true
				modes[#modes + 1] = { w = m.width, h = m.height, refresh = m.refresh }
			end
		end
		outputs[#outputs + 1] = {
			name = o.name,
			make = o.make,
			model = o.model,
			active = o.active,
			focused = o.focused,
			scale = o.scale or 1.0,
			mode = { w = cm.width, h = cm.height, refresh = cm.refresh },
			modes = modes,
			-- Sway >= 1.7 includes icc_profile field (string; may be null)
			icc_profile = o.icc_profile,
		}
	end
	return outputs, nil
end

function M.mode_label(m)
	if not m or not m.w then
		return "unknown"
	end
	local hz = m.refresh and math.floor(m.refresh / 1000 + 0.5) or 0
	return ("%dx%d @ %dHz"):format(m.w, m.h, hz)
end

function M.set_mode(output, m)
	if not have_sway() then
		return false, "swaymsg not found"
	end
	local hz = m.refresh and (m.refresh / 1000) or nil
	local cmd
	if hz then
		cmd = ("swaymsg output %s mode %dx%d@%.3fHz"):format(output, m.w, m.h, hz)
	else
		cmd = ("swaymsg output %s mode %dx%d"):format(output, m.w, m.h)
	end
	local _, ok = shell(cmd)
	if ok then
		return true, nil
	end
	return false, "set-mode failed"
end

function M.set_scale(output, scale)
	if not have_sway() then
		return false, "swaymsg not found"
	end
	local _, ok = shell(("swaymsg output %s scale %.2f"):format(output, scale))
	if ok then
		return true, nil
	end
	return false, "set-scale failed"
end

function M.set_power(output, on)
	if not have_sway() then
		return false, "swaymsg not found"
	end
	local _, ok = shell(("swaymsg output %s power %s"):format(output, on and "on" or "off"))
	if ok then
		return true, nil
	end
	return false, "set-power failed"
end

-- ── brightness (brightnessctl) ──────────────────────────────────────────────
local BC_OK = nil
local function have_brightnessctl()
	if BC_OK == nil then
		BC_OK = have("brightnessctl")
	end
	return BC_OK
end
M.brightness_available = have_brightnessctl

-- Some panels (notably this machine's amdgpu_bl1) invert/clip at the very top
-- of the backlight range: values above ~96% make the screen DARKER, not
-- brighter — a firmware/driver quirk that bare brightnessctl hits too, and that
-- no kernel parameter fixed on this hardware. To keep the slider usable end to
-- end, we treat SAFE_MAX as the effective ceiling: the UI still shows 0-100%,
-- but that range maps onto 0-SAFE_MAX% of the actual hardware, so the slider's
-- "100%" is the brightest *working* level and the broken zone is unreachable.
-- If a future panel doesn't have this quirk, set SAFE_MAX = 100 to disable it.
local SAFE_MAX = 95

function M.get_brightness()
	if not have_brightnessctl() then
		return nil, "brightnessctl not found"
	end
	local mx = shell("brightnessctl max")
	local cur = shell("brightnessctl get")
	mx = mx and tonumber(mx:match("%d+"))
	cur = cur and tonumber(cur:match("%d+"))
	if not mx or not cur or mx == 0 then
		return nil, "no backlight"
	end
	-- hardware percent, then rescale to the slider's 0-100 (0-SAFE_MAX -> 0-100)
	local hw_pct = cur / mx * 100
	local ui_pct = hw_pct / SAFE_MAX * 100
	return math.floor(math.min(100, ui_pct) + 0.5), nil
end

function M.set_brightness(pct)
	if not have_brightnessctl() then
		return false, "brightnessctl not found"
	end
	-- pct is the SLIDER value (0-100); map it onto the safe hardware range so
	-- the slider's 100% lands on SAFE_MAX% of the backlight, never higher.
	pct = math.max(0, math.min(100, pct))
	local hw = math.floor(pct / 100 * SAFE_MAX + 0.5)
	hw = math.max(1, math.min(SAFE_MAX, hw))
	local _, ok = shell(("brightnessctl set %d%%"):format(hw))
	if ok then
		return true, nil
	end
	return false, "set failed"
end

-- ── night light (wlsunset) ──────────────────────────────────────────────────
-- wlsunset shifts screen colour temperature warm at night. It's launched with
-- the desired night/day temperatures and sunrise/sunset times as arguments, so
-- to change any setting we persist the chosen values and relaunch. Settings are
-- stored in a small state file so they survive across sessions.

local NIGHT_CFG = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/tui-settings/nightlight.conf"

-- Sensible defaults; the night temperature is what the slider adjusts.
local NIGHT_DEFAULTS = {
	night_temp = 4000, -- warm (slider target): 2500 (warmest) .. 6500 (off-ish)
	day_temp = 6500, -- neutral daytime
	sunrise = "07:00",
	sunset = "20:00",
}

-- Bounds for the night-temperature slider (Kelvin). Below ~2500 is unusably
-- orange; at/above day_temp there's no night effect.
M.NIGHT_TEMP_MIN = 2500
M.NIGHT_TEMP_MAX = 6500

function M.night_light_available()
	return have("wlsunset")
end

function M.night_light_on()
	local out = shell("pgrep -x wlsunset")
	return out ~= nil and out:match("%d") ~= nil
end

-- Read persisted night-light settings, falling back to defaults for any missing
-- field. Returns a table { night_temp, day_temp, sunrise, sunset }.
function M.night_light_config()
	local cfg = {}
	for k, v in pairs(NIGHT_DEFAULTS) do
		cfg[k] = v
	end
	local f = io.open(NIGHT_CFG, "r")
	if f then
		for line in f:lines() do
			local key, val = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
			if key == "night_temp" or key == "day_temp" then
				cfg[key] = tonumber(val) or cfg[key]
			elseif key == "sunrise" or key == "sunset" then
				if val:match("^%d%d:%d%d$") then
					cfg[key] = val
				end
			end
		end
		f:close()
	end
	return cfg
end

-- Persist night-light settings to the state file (creating the dir if needed).
function M.night_light_save(cfg)
	local dir = NIGHT_CFG:match("^(.*)/[^/]+$")
	if dir then
		-- single-quote escape (%q uses double quotes, where the shell still
		-- expands $ and backticks); the path derives from $HOME, so treat it
		-- as untrusted rather than assuming.
		local q = "'" .. dir:gsub("'", "'\\''") .. "'"
		os.execute("mkdir -p " .. q .. " 2>/dev/null")
	end
	local f = io.open(NIGHT_CFG, "w")
	if not f then
		return false, "cannot write config"
	end
	f:write("# settings_menu night light\n")
	f:write(("night_temp = %d\n"):format(cfg.night_temp or NIGHT_DEFAULTS.night_temp))
	f:write(("day_temp = %d\n"):format(cfg.day_temp or NIGHT_DEFAULTS.day_temp))
	f:write(("sunrise = %s\n"):format(cfg.sunrise or NIGHT_DEFAULTS.sunrise))
	f:write(("sunset = %s\n"):format(cfg.sunset or NIGHT_DEFAULTS.sunset))
	f:close()
	return true, nil
end

-- (Re)start wlsunset with the persisted settings. Kills any existing instance
-- first so a settings change takes effect immediately.
local function night_light_launch(cfg)
	os.execute("pkill -x wlsunset >/dev/null 2>&1")
	local cmd = ("wlsunset -t %d -T %d -S %q -s %q >/dev/null 2>&1 &"):format(
		cfg.night_temp,
		cfg.day_temp,
		cfg.sunrise,
		cfg.sunset
	)
	os.execute(cmd)
end

function M.night_light_set(on)
	if not have("wlsunset") then
		return false, "wlsunset not found"
	end
	if on then
		night_light_launch(M.night_light_config())
		return true, nil
	else
		os.execute("pkill -x wlsunset >/dev/null 2>&1")
		return true, nil
	end
end

-- Apply a new night temperature (Kelvin), persist it, and if night light is
-- currently running, relaunch so the change is immediate.
function M.night_light_set_temp(kelvin)
	kelvin = math.floor(tonumber(kelvin) or NIGHT_DEFAULTS.night_temp)
	if kelvin < M.NIGHT_TEMP_MIN then
		kelvin = M.NIGHT_TEMP_MIN
	end
	if kelvin > M.NIGHT_TEMP_MAX then
		kelvin = M.NIGHT_TEMP_MAX
	end
	local cfg = M.night_light_config()
	cfg.night_temp = kelvin
	M.night_light_save(cfg)
	if M.night_light_on() then
		night_light_launch(cfg)
	end
	return true, nil
end

-- Apply a new schedule time ("sunrise" or "sunset") as "HH:MM", persist, and
-- relaunch if running. Validates the format; rejects anything else.
function M.night_light_set_time(which, hhmm)
	if which ~= "sunrise" and which ~= "sunset" then
		return false, "bad field"
	end
	if type(hhmm) ~= "string" or not hhmm:match("^%d%d:%d%d$") then
		return false, "time must be HH:MM"
	end
	local h, m = hhmm:match("^(%d%d):(%d%d)$")
	h, m = tonumber(h), tonumber(m)
	if h > 23 or m > 59 then
		return false, "invalid time"
	end
	local cfg = M.night_light_config()
	cfg[which] = hhmm
	M.night_light_save(cfg)
	if M.night_light_on() then
		night_light_launch(cfg)
	end
	return true, nil
end

-- ── color profiles (ICC) ──────────────────────────────────────────────────
-- Scan common directories for .icc / .icm files
function M.get_available_profiles()
	local dirs = {
		os.getenv("HOME") .. "/.local/share/icc",
		"/usr/share/color/icc",
		"/usr/local/share/color/icc",
	}
	local profiles = {}
	for _, dir in ipairs(dirs) do
		local cmd = "find " .. util.shquote(dir)
			.. " -type f \\( -name '*.icc' -o -name '*.icm' \\)"
		for _, line in ipairs(util.shell_lines(cmd)) do
			local name = line:match("([^/]+)$") or line
			table.insert(profiles, { path = line, name = name })
		end
	end
	-- remove duplicates (same path can appear from multiple dirs)
	local seen = {}
	local unique = {}
	for _, p in ipairs(profiles) do
		if not seen[p.path] then
			seen[p.path] = true
			table.insert(unique, p)
		end
	end
	-- sort by name
	table.sort(unique, function(a, b)
		return a.name < b.name
	end)
	return unique
end

-- Get the current ICC profile path for a given output (from swaymsg)
function M.get_current_profile(output_name)
	local out, ok = shell("swaymsg -t get_outputs -r")
	if not ok then
		return nil
	end
	local data = json_decode(out)
	if not data then
		return nil
	end
	for _, o in ipairs(data) do
		if o.name == output_name then
			return o.icc_profile or nil
		end
	end
	return nil
end

-- Apply a profile via swaymsg
function M.set_profile(output_name, profile_path)
	if not have_sway() then
		return false, "swaymsg not found"
	end
	local cmd = ('swaymsg output %s profile "%s"'):format(output_name, profile_path)
	local _, ok = shell(cmd)
	if ok then
		return true, nil
	end
	return false, "set-profile failed"
end

-- ── kanshi monitor arrangement ───────────────────────────────────────────────
-- Reads/writes ~/.config/kanshi/config for multi-monitor arrangement.
-- Arrangement = left-to-right order of outputs, with y=0 (extra vertical
-- pixels always at the bottom, so positions are (0,0), (width1,0), etc).

local kanshi_path = os.getenv("HOME") .. "/.config/kanshi/config"

-- Read the kanshi config file. Returns the raw text or nil.
function M.kanshi_read()
	local f = io.open(kanshi_path, "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

-- Parse kanshi config into profiles. Returns a list of:
--   { name="docked", outputs={ {name="HDMI-A-1", x=0}, {name="eDP-1", x=1920} } }
-- sorted by x position within each profile.
function M.kanshi_profiles()
	local text = M.kanshi_read()
	if not text then
		return nil
	end
	local profiles = {}
	-- match "profile <name> { ... }"
	for pname, body in text:gmatch("profile%s+(%S+)%s*{(.-)}") do
		local outputs = {}
		local seen = {}
		-- match "output <name>" and find its position
		for oname in body:gmatch("output%s+(%S+)") do
			if not seen[oname] then
				seen[oname] = true
				local pat = "output%s+" .. oname:gsub("%-", "%%-") .. "[^\n]*position%s+(%d+)%s*,%s*(%d+)"
				local px, py = body:match(pat)
				outputs[#outputs + 1] = {
					name = oname,
					x = tonumber(px) or 0,
					y = tonumber(py) or 0,
				}
			end
		end
		-- sort by x position (left to right)
		table.sort(outputs, function(a, b)
			return a.x < b.x
		end)
		profiles[#profiles + 1] = { name = pname, outputs = outputs }
	end
	return profiles
end

-- Get the arrangement (left-to-right output name order) for a given profile.
-- Returns a list of output names, e.g. {"HDMI-A-1", "eDP-1"}.
function M.kanshi_arrangement(profile_name)
	local profiles = M.kanshi_profiles()
	if not profiles then
		return nil
	end
	for _, p in ipairs(profiles) do
		if p.name == profile_name then
			local order = {}
			for _, o in ipairs(p.outputs) do
				order[#order + 1] = o.name
			end
			return order
		end
	end
	return nil
end

-- Rewrite kanshi config with a new arrangement for a given profile.
-- new_order is a list of output names in left-to-right order.
-- Uses the current swaymsg output widths (from get_outputs) to compute
-- x positions. All y=0 (extra vertical pixels at the bottom).
function M.kanshi_set_arrangement(profile_name, new_order)
	local text = M.kanshi_read()
	if not text then
		return false, "kanshi config not found"
	end
	-- get widths from swaymsg
	local outputs = M.get_outputs()
	local widths = {}
	for _, o in ipairs(outputs) do
		if o.mode then
			widths[o.name] = o.mode.w or 1920
		else
			widths[o.name] = 1920
		end
	end
	-- build the new profile body
	local x = 0
	local lines = {}
	for _, oname in ipairs(new_order) do
		lines[#lines + 1] = string.format("\toutput %s enable", oname)
		lines[#lines + 1] = string.format("\toutput %s position %d,0", oname, x)
		x = x + (widths[oname] or 1920)
	end
	local new_body = table.concat(lines, "\n")
	-- replace the profile block in the config
	local pattern = "(profile%s+" .. profile_name:gsub("%-", "%%-") .. "%s*{).-(})"
	local new_text, count = text:gsub(pattern, "%1\n" .. new_body .. "\n%2")
	if count == 0 then
		return false, "profile '" .. profile_name .. "' not found"
	end
	-- write back
	local dir = kanshi_path:match("^(.+)/[^/]+$")
	if dir then
		shell("mkdir -p " .. dir)
	end
	local f = io.open(kanshi_path, "w")
	if not f then
		return false, "cannot write kanshi config"
	end
	f:write(new_text)
	f:close()
	-- reload kanshi
	shell("kanshictl reload 2>/dev/null || pkill -USR2 kanshi 2>/dev/null")
	return true, nil
end

-- List profile names from kanshi config.
function M.kanshi_profile_names()
	local profiles = M.kanshi_profiles()
	if not profiles then
		return {}
	end
	local names = {}
	for _, p in ipairs(profiles) do
		names[#names + 1] = p.name
	end
	return names
end

return M
