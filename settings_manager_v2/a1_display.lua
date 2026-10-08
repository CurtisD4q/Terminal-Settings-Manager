#!/usr/bin/env lua5.4
-- Display & Graphics — LIVE via swaymsg (Sway IPC) + brightnessctl.
-- Built for a real multi-output Sway session: one section per connected
-- monitor, each with its live resolution/refresh (cycles the monitor's own
-- supported modes), scale, and power. Plus laptop backlight brightness.
--
-- Night Light: needs wlsunset (not installed on this system) — shown as such
-- rather than faked. Install wlsunset to enable, and tell me to wire it.
--
-- Color Profiles: uses ICC profiles from standard directories; each monitor
-- can be assigned a profile via `swaymsg output <name> profile <path>`.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local display = require("display_backend")

-- find output record in cache by name
local function find_output(cache, name)
	for _, o in ipairs(cache.outputs or {}) do
		if o.name == name then
			return o
		end
	end
	return nil
end

-- cycle the current mode of a given output forward/backward through its modes
local function cycle_mode(name, step, cache)
	if step == 0 then
		step = 1
	end -- Enter re-advances (non-root: apply immediately)
	local o = find_output(cache, name)
	if not o or #o.modes == 0 then
		return
	end
	local cur = 1
	for i, m in ipairs(o.modes) do
		if m.w == o.mode.w and m.h == o.mode.h and m.refresh == o.mode.refresh then
			cur = i
			break
		end
	end
	local n = #o.modes
	local nextidx = ((cur - 1 + step) % n + n) % n + 1
	display.set_mode(name, o.modes[nextidx])
end

-- cycle scale through a sensible set of common values
local SCALES = { 1.0, 1.25, 1.5, 1.75, 2.0 }
local function cycle_scale(name, step, cache)
	if step == 0 then
		step = 1
	end -- Enter re-advances (non-root: apply immediately)
	local o = find_output(cache, name)
	if not o then
		return
	end
	local cur = 1
	for i, s in ipairs(SCALES) do
		if math.abs(s - o.scale) < 0.01 then
			cur = i
			break
		end
	end
	local n = #SCALES
	local nextidx = ((cur - 1 + step) % n + n) % n + 1
	display.set_scale(name, SCALES[nextidx])
end

-- cycle through available ICC profiles for a given output
local function cycle_profile(name, step, cache)
	local profiles = cache.available_profiles or {}
	if #profiles == 0 then
		return
	end
	local current = display.get_current_profile(name) or ""
	local cur_idx = 0
	for i, p in ipairs(profiles) do
		if p.path == current then
			cur_idx = i
			break
		end
	end
	local n = #profiles
	local next_idx = ((cur_idx - 1 + step) % n + n) % n + 1
	local selected = profiles[next_idx]
	display.set_profile(name, selected.path)
end

-- Build the sections dynamically from the actual connected outputs, so the
-- panel always matches your real hardware (two monitors now, but it adapts
-- if you plug/unplug).
-- Cycle a "HH:MM" time by half-hour steps, wrapping at the day boundary.
-- Used by the night-light schedule choosers (dir -1/+1; 0 treated as +1).
local function cycle_time(hhmm, dir)
	local h, m = hhmm:match("^(%d%d):(%d%d)$")
	h, m = tonumber(h) or 7, tonumber(m) or 0
	local total = h * 60 + m
	local step = (dir == -1) and -30 or 30
	total = (total + step) % (24 * 60)
	return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

local function build_sections(cache)
	local sections = {}

	for _, o in ipairs(cache.outputs or {}) do
		local name = o.name
		local title = name
		if o.make or o.model then
			title = name .. "  (" .. ((o.make or "") .. " " .. (o.model or "")):gsub("^%s+", ""):gsub("%s+$", "") .. ")"
		end
		sections[#sections + 1] = {
			title,
			{
				{
					"Resolution",
					"—",
					"choice",
					{
						get = function(c)
							local oo = find_output(c, name)
							return oo and display.mode_label(oo.mode) or "unknown"
						end,
						set = function(step, c)
							cycle_mode(name, step, c)
						end,
					},
				},
				{
					"Scale",
					"—",
					"choice",
					{
						get = function(c)
							local oo = find_output(c, name)
							return oo and (("%.2f×"):format(oo.scale)) or "unknown"
						end,
						set = function(step, c)
							cycle_scale(name, step, c)
						end,
					},
				},
				{
					"Power",
					"—",
					"toggle",
					{
						get = function(c)
							local oo = find_output(c, name)
							-- swaymsg get_outputs marks inactive/off outputs active=false
							return oo and oo.active or false
						end,
						set = function(v, c)
							display.set_power(name, v)
						end,
					},
				},
			},
		}
	end

	if #sections == 0 then
		sections[1] = { "Monitors", { { "Status", "no outputs / swaymsg unavailable", "" } } }
	end

	-- Brightness (laptop backlight) — always its own section
	sections[#sections + 1] = {
		"Brightness",
		{
			{
				"Level",
				"—",
				"slider",
				{
					get = function(c)
						return c.brightness, c.brightness_err
					end,
					set = function(v, c)
						display.set_brightness(v)
					end,
				},
			},
		},
	}

	-- Color section: Night Light (toggle + warmth slider + schedule)
	sections[#sections + 1] = {
		"Color",
		{
			{
				"Night Light",
				"—",
				"toggle",
				{
					get = function(c)
						if not c.night_available then
							return nil, "install wlsunset"
						end
						return c.night_on or false
					end,
					set = function(v, c)
						display.night_light_set(v)
					end,
				},
			},
			-- Warmth slider: maps 0..100 onto the night colour-temperature range
			-- (2500K warmest .. 6500K neutral). Higher slider = warmer, so we
			-- invert: slider 100 -> min Kelvin (warmest), slider 0 -> max.
			{
				"Warmth",
				"—",
				"slider",
				{
					get = function(c)
						if not c.night_available then
							return nil, "install wlsunset"
						end
						local t = (c.night_cfg and c.night_cfg.night_temp) or 4000
						local lo, hi = display.NIGHT_TEMP_MIN, display.NIGHT_TEMP_MAX
						-- invert so more-slider = warmer (lower Kelvin)
						local frac = (hi - t) / (hi - lo)
						return math.floor(frac * 100 + 0.5)
					end,
					set = function(v, c)
						local lo, hi = display.NIGHT_TEMP_MIN, display.NIGHT_TEMP_MAX
						local frac = (tonumber(v) or 0) / 100
						local kelvin = hi - frac * (hi - lo)
						display.night_light_set_temp(kelvin)
						if c then
							c.night_cfg = display.night_light_config()
						end
					end,
				},
			},
			-- Schedule: sunrise / sunset as cyclable preset times (on the hour
			-- and half-hour), applied live. Presets keep it simple and avoid a
			-- free-text time entry.
			{
				"Turns off at (sunrise)",
				"—",
				"choice",
				{
					get = function(c)
						if not c.night_available then
							return nil, "install wlsunset"
						end
						return (c.night_cfg and c.night_cfg.sunrise) or "07:00"
					end,
					set = function(dir, c)
						local cur = (c.night_cfg and c.night_cfg.sunrise) or "07:00"
						local nextt = cycle_time(cur, dir)
						display.night_light_set_time("sunrise", nextt)
						if c then
							c.night_cfg = display.night_light_config()
						end
					end,
				},
			},
			{
				"Turns on at (sunset)",
				"—",
				"choice",
				{
					get = function(c)
						if not c.night_available then
							return nil, "install wlsunset"
						end
						return (c.night_cfg and c.night_cfg.sunset) or "20:00"
					end,
					set = function(dir, c)
						local cur = (c.night_cfg and c.night_cfg.sunset) or "20:00"
						local nextt = cycle_time(cur, dir)
						display.night_light_set_time("sunset", nextt)
						if c then
							c.night_cfg = display.night_light_config()
						end
					end,
				},
			},
		},
	}

	-- Color Profiles section (separate section with its own title)
	local profile_rows = {}
	local profiles = cache.available_profiles or {}
	if cache.outputs and #cache.outputs > 0 then
		for _, o in ipairs(cache.outputs) do
			local name = o.name
			local current_profile = display.get_current_profile(name) or "none"
			local display_name = current_profile:match("([^/]+)$") or current_profile
			if display_name == "" or display_name == "none" then
				display_name = "none"
			end
			table.insert(profile_rows, {
				"Profile (" .. name .. ")",
				display_name,
				"choice",
				{
					get = function(c)
						local prof = display.get_current_profile(name) or "none"
						local fname = prof:match("([^/]+)$") or prof
						return (fname == "" and "none") or fname
					end,
					set = function(step, c)
						cycle_profile(name, step, c)
					end,
				},
			})
		end
		if #profiles == 0 then
			table.insert(profile_rows, { "No ICC profiles found", "", "" })
		end
	else
		table.insert(profile_rows, { "No monitors available", "", "" })
	end
	sections[#sections + 1] = { "Color Profiles", profile_rows }

	-- ── Monitor Arrangement (kanshi) ────────────────────────────────────
	-- Shows left-to-right order (top=leftmost). Only for multi-monitor
	-- profiles. Reordering writes kanshi config and reloads.
	local arr_rows = {}
	local kprofiles = display.kanshi_profile_names()
	if #kprofiles > 0 then
		-- find the multi-monitor profile (>1 output)
		local all_kp = display.kanshi_profiles()
		local active_profile = nil
		for _, kp in ipairs(all_kp or {}) do
			if #kp.outputs > 1 then
				active_profile = kp
				break
			end
		end
		if active_profile then
			cache._kanshi_profile = active_profile.name
			cache._kanshi_order = {}
			for _, o in ipairs(active_profile.outputs) do
				cache._kanshi_order[#cache._kanshi_order + 1] = o.name
			end
			arr_rows[#arr_rows + 1] = { "Profile", active_profile.name, "" }
			arr_rows[#arr_rows + 1] = { "Order", "top = leftmost", "" }
			for idx, oname in ipairs(cache._kanshi_order) do
				local pos_label = (idx == 1) and "left" or (idx == #cache._kanshi_order) and "right" or tostring(idx)
				arr_rows[#arr_rows + 1] = {
					oname,
					pos_label,
					"button",
					{
						get = function()
							return pos_label
						end,
						set = function()
							-- swap this monitor with the one above it (move left)
							local order = cache._kanshi_order
							if not order then
								return
							end
							-- find current position of this output
							local cur = nil
							for i, n in ipairs(order) do
								if n == oname then
									cur = i
									break
								end
							end
							if not cur then
								return
							end
							-- swap with previous (wrapping: if first, swap with last)
							local swap = (cur > 1) and (cur - 1) or #order
							order[cur], order[swap] = order[swap], order[cur]
							display.kanshi_set_arrangement(cache._kanshi_profile, order)
						end,
					},
				}
			end
		else
			arr_rows[#arr_rows + 1] = { "Single monitor", "no arrangement needed", "" }
		end
	else
		arr_rows[#arr_rows + 1] = { "kanshi", "config not found", "" }
	end
	sections[#sections + 1] = { "Arrangement", arr_rows }

	return sections
end

local dynamic_sections = { { "Monitors", { { "Loading…", "", "" } } } }

local CAT = {
	id = "display",
	label = "Display & Graphics",
	icon = "▭",
	sections = dynamic_sections,
	prefetch = function(cache)
		cache.outputs = display.get_outputs()
		local b, berr = display.get_brightness()
		cache.brightness, cache.brightness_err = b, berr
		cache.night_available = display.night_light_available()
		cache.night_on = cache.night_available and display.night_light_on() or false
		if cache.night_available then
			cache.night_cfg = display.night_light_config()
		end
		-- fetch available ICC profiles once
		cache.available_profiles = display.get_available_profiles()
		-- rebuild the section list in place from the live outputs
		local built = build_sections(cache)
		for i = 1, math.max(#dynamic_sections, #built) do
			dynamic_sections[i] = built[i]
		end
	end,
}

return core.define_category(CAT)
