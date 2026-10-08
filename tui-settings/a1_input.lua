#!/usr/bin/env lua5.4
-- Mouse & Touchpad (App 1) — live libinput settings via Sway (swaymsg).
-- Reads devices from `swaymsg -t get_inputs` and applies changes with
-- `swaymsg input <id> <setting> <value>`.
--
-- NOTE: these changes are RUNTIME ONLY — they apply instantly but reset when
-- Sway restarts. To make them permanent, add the equivalent `input` lines to
-- your Sway config. The category shows a reminder of this.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local inp = require("input_backend")

local CAT -- forward-declared so prefetch can rebuild sections

-- ── row builders ────────────────────────────────────────────────────────────

local function touchpad_rows(cache)
	local tp = cache.touchpad
	if not inp.available() then
		return { { "Unavailable", "swaymsg not found", "" } }
	end
	if not tp then
		return { { "No touchpad detected", "", "" } }
	end
	local id = tp.identifier
	local rows = {}
	rows[#rows + 1] = { "Device", tp.name or id, "" }
	-- tap to click
	if inp.is_enabled(tp, "tap") ~= nil then
		rows[#rows + 1] = {
			"Tap to click",
			"—",
			"toggle",
			{
				get = function()
					return inp.is_enabled(cache.touchpad, "tap"), nil
				end,
				set = function(v)
					inp.set_tap(id, v)
				end,
			},
		}
	end
	-- natural scrolling
	if inp.is_enabled(tp, "natural_scroll") ~= nil then
		rows[#rows + 1] = {
			"Natural scrolling",
			"—",
			"toggle",
			{
				get = function()
					return inp.is_enabled(cache.touchpad, "natural_scroll"), nil
				end,
				set = function(v)
					inp.set_natural_scroll(id, v)
				end,
			},
		}
	end
	-- disable while typing
	if inp.is_enabled(tp, "dwt") ~= nil then
		rows[#rows + 1] = {
			"Disable while typing",
			"—",
			"toggle",
			{
				get = function()
					return inp.is_enabled(cache.touchpad, "dwt"), nil
				end,
				set = function(v)
					inp.set_dwt(id, v)
				end,
			},
		}
	end
	-- middle-click emulation
	if inp.is_enabled(tp, "middle_emulation") ~= nil then
		rows[#rows + 1] = {
			"Middle-click emulation",
			"—",
			"toggle",
			{
				get = function()
					return inp.is_enabled(cache.touchpad, "middle_emulation"), nil
				end,
				set = function(v)
					inp.set_middle_emulation(id, v)
				end,
			},
		}
	end
	-- pointer speed
	if inp.number_of(tp, "accel_speed") ~= nil then
		rows[#rows + 1] = {
			"Pointer speed",
			"—",
			"slider",
			{
				get = function()
					return inp.accel_to_slider(inp.number_of(cache.touchpad, "accel_speed")), nil
				end,
				set = function(v)
					inp.set_accel(id, inp.slider_to_accel(v))
				end,
			},
		}
	end
	return rows
end

local function mouse_rows(cache)
	local ms = cache.mouse
	if not inp.available() then
		return { { "Unavailable", "swaymsg not found", "" } }
	end
	if not ms then
		return { { "No mouse detected", "", "" } }
	end
	local id = ms.identifier
	local rows = {}
	rows[#rows + 1] = { "Device", ms.name or id, "" }
	if inp.is_enabled(ms, "natural_scroll") ~= nil then
		rows[#rows + 1] = {
			"Natural scrolling",
			"—",
			"toggle",
			{
				get = function()
					return inp.is_enabled(cache.mouse, "natural_scroll"), nil
				end,
				set = function(v)
					inp.set_natural_scroll(id, v)
				end,
			},
		}
	end
	if inp.is_enabled(ms, "left_handed") ~= nil then
		rows[#rows + 1] = {
			"Left-handed mode",
			"—",
			"toggle",
			{
				get = function()
					return inp.is_enabled(cache.mouse, "left_handed"), nil
				end,
				set = function(v)
					inp.set_left_handed(id, v)
				end,
			},
		}
	end
	if inp.is_enabled(ms, "middle_emulation") ~= nil then
		rows[#rows + 1] = {
			"Middle-click emulation",
			"—",
			"toggle",
			{
				get = function()
					return inp.is_enabled(cache.mouse, "middle_emulation"), nil
				end,
				set = function(v)
					inp.set_middle_emulation(id, v)
				end,
			},
		}
	end
	if inp.number_of(ms, "accel_speed") ~= nil then
		rows[#rows + 1] = {
			"Pointer speed",
			"—",
			"slider",
			{
				get = function()
					return inp.accel_to_slider(inp.number_of(cache.mouse, "accel_speed")), nil
				end,
				set = function(v)
					inp.set_accel(id, inp.slider_to_accel(v))
				end,
			},
		}
	end
	return rows
end

-- ── prefetch ────────────────────────────────────────────────────────────────

local function cursor_rows(cache)
	local rows = {}
	if not inp.available() then
		return { { "Unavailable", "swaymsg not found", "" } }
	end
	local themes = cache.cursor_themes or {}
	local cur_theme = cache.cursor_theme
	local cur_size = cache.cursor_size or 24

	-- current (read-only)
	rows[#rows + 1] = { "Current", (cur_theme or "default") .. "  ·  " .. cur_size .. "px", "" }

	-- theme chooser
	if #themes > 0 then
		rows[#rows + 1] = {
			"Theme",
			"—",
			"choice",
			{
				get = function(c)
					local t = c.sel_theme or c.cursor_theme or themes[1]
					return t, nil
				end,
				set = function(step, c)
					local list = c.cursor_themes or {}
					local n = #list
					if n == 0 then
						return
					end
					-- find current index
					local cur = 1
					local active = c.sel_theme or c.cursor_theme
					for i, t in ipairs(list) do
						if t == active then
							cur = i
							break
						end
					end
					if step == 0 then
						step = 1
					end
					local nextidx = ((cur - 1 + step) % n + n) % n + 1
					c.sel_theme = list[nextidx]
					inp.set_cursor(c.sel_theme, c.sel_size or c.cursor_size or 24)
				end,
			},
		}
	else
		rows[#rows + 1] = { "Theme", "no themes found", "" }
	end

	-- size chooser
	rows[#rows + 1] = {
		"Size",
		"—",
		"choice",
		{
			get = function(c)
				local sz = c.sel_size or c.cursor_size or 24
				return sz .. "px", nil
			end,
			set = function(step, c)
				local sizes = inp.CURSOR_SIZES
				local n = #sizes
				local cur = 1
				local active = c.sel_size or c.cursor_size or 24
				for i, s in ipairs(sizes) do
					if s == active then
						cur = i
						break
					end
				end
				if step == 0 then
					step = 1
				end
				local nextidx = ((cur - 1 + step) % n + n) % n + 1
				c.sel_size = sizes[nextidx]
				local theme = c.sel_theme or c.cursor_theme
				if theme then
					inp.set_cursor(theme, c.sel_size)
				end
			end,
		},
	}

	-- apply to GTK apps
	rows[#rows + 1] = {
		"Apply to GTK apps",
		"",
		"button",
		{
			get = function()
				return "apply"
			end,
			set = function(_, c)
				local theme = c.sel_theme or c.cursor_theme
				local size = c.sel_size or c.cursor_size or 24
				if theme then
					inp.set_cursor_gtk(theme, size)
				end
			end,
		},
	}

	return rows
end

local function percursor_rows(cache)
	local rows = {}
	if not inp.available() then
		return { { "Unavailable", "swaymsg not found", "" } }
	end
	local themes = cache.cursor_themes or {}
	if #themes == 0 then
		return { { "No cursor themes installed", "", "" } }
	end
	-- cache.role_choice[role_key] = chosen theme (or nil = inherit base)
	cache.role_choice = cache.role_choice or {}

	rows[#rows + 1] = { "Mix cursors from different themes", "", "" }
	rows[#rows + 1] = {
		"Base theme",
		"—",
		"choice",
		{
			get = function(c)
				return c.mix_base or (c.cursor_themes or {})[1] or "—", nil
			end,
			set = function(step, c)
				local list = c.cursor_themes or {}
				local n = #list
				if n == 0 then
					return
				end
				local cur = 1
				for i, t in ipairs(list) do
					if t == (c.mix_base or list[1]) then
						cur = i
						break
					end
				end
				if step == 0 then
					step = 1
				end
				c.mix_base = list[((cur - 1 + step) % n + n) % n + 1]
			end,
		},
	}

	-- one chooser per role: cycles through [inherit] + themes that provide it
	for _, role in ipairs(inp.CURSOR_ROLES) do
		local providers = cache.role_providers and cache.role_providers[role.key]
		if providers and #providers > 0 then
			-- options: "(base)" plus each provider theme
			local rkey = role.key
			rows[#rows + 1] = {
				"  " .. role.label,
				"—",
				"choice",
				{
					get = function(c)
						local ch = c.role_choice[rkey]
						return ch or "(base)", nil
					end,
					set = function(step, c)
						local opts = { "(base)" }
						for _, t in ipairs(providers) do
							opts[#opts + 1] = t
						end
						local n = #opts
						local active = c.role_choice[rkey] or "(base)"
						local cur = 1
						for i, o in ipairs(opts) do
							if o == active then
								cur = i
								break
							end
						end
						if step == 0 then
							step = 1
						end
						local pick = opts[((cur - 1 + step) % n + n) % n + 1]
						c.role_choice[rkey] = (pick == "(base)") and nil or pick
					end,
				},
			}
		end
	end

	-- build + apply
	rows[#rows + 1] = {
		"Build & apply mix",
		"",
		"button",
		{
			get = function()
				return "build"
			end,
			set = function(_, c)
				local base = c.mix_base or (c.cursor_themes or {})[1]
				local mapping = {}
				for k, v in pairs(c.role_choice) do
					mapping[k] = v
				end
				inp.build_composite(mapping, base)
				-- activate the composite live at the current size
				inp.set_cursor(inp.COMPOSITE_NAME, c.sel_size or c.cursor_size or 24)
				c._mix_built = true
			end,
		},
	}
	if cache._mix_built then
		rows[#rows + 1] = { "  Active", "custom-mix applied", "" }
	end

	return rows
end

local function prefetch(cache)
	cache.touchpad = select(1, inp.touchpad())
	cache.mouse = select(1, inp.mouse())
	-- cursor info: scan themes once (static), read current setting
	if cache.cursor_themes == nil then
		cache.cursor_themes = inp.cursor_themes()
		local t, s = inp.cursor_current()
		cache.cursor_theme = t
		cache.cursor_size = s or 24
		-- precompute which themes provide each role (one-time, static)
		cache.role_providers = {}
		for _, role in ipairs(inp.CURSOR_ROLES) do
			cache.role_providers[role.key] = inp.themes_for_role(role, cache.cursor_themes)
		end
		-- seed role choices from any existing composite
		cache.role_choice = inp.composite_mapping()
	end
	CAT.sections[1][2] = touchpad_rows(cache)
	CAT.sections[2][2] = mouse_rows(cache)
	CAT.sections[3][2] = cursor_rows(cache)
	CAT.sections[4][2] = percursor_rows(cache)
end

CAT = {
	id = "input",
	label = "Mouse & Touchpad",
	icon = "➜",
	sections = {
		{ "Touchpad", { { "Loading…", "", "" } } },
		{ "Mouse", { { "Loading…", "", "" } } },
		{ "Cursor", { { "Loading…", "", "" } } },
		{ "Per-Cursor Mix", { { "Loading…", "", "" } } },
		{
			"Note",
			{
				{ "Changes are live", "reset on Sway restart", "" },
				{ "To persist", "add lines to Sway config", "" },
			},
		},
	},
	prefetch = prefetch,
}

return core.define_category(CAT)
