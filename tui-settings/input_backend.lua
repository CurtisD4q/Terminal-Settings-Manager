-- input_backend.lua — mouse & touchpad control via Sway (swaymsg).
-- Reads device settings from `swaymsg -t get_inputs` (JSON) and applies
-- changes with `swaymsg input <id> <setting> <value>`.
--
-- IMPORTANT: swaymsg input changes are RUNTIME ONLY — they take effect
-- immediately but reset when Sway restarts. To persist, the same settings
-- must be written into the Sway config. This module handles the live runtime
-- side; the category notes the non-persistence to the user.
local M = {}
local util = require("util")

-- Command execution and JSON decoding go through util (single audited,
-- injection-safe implementation). shell() is shimmed to the (out, ok)
-- convention this file's call sites expect.
local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local have = util.have
local function have_sway()
	return have("swaymsg")
end
M.available = have_sway

local json_decode = util.json_decode

-- ── device enumeration ──────────────────────────────────────────────────────

-- Fetch all input devices, filtered to pointers and touchpads (the things
-- this category controls). Returns a list of:
--   { id, name, type, libinput = {...} }
-- type is "touchpad" or "pointer". Returns nil, err on failure.
local function get_inputs()
	if not have_sway() then
		return nil, "swaymsg not found"
	end
	local out = shell("swaymsg -t get_inputs -r")
	if not out or out == "" then
		out = shell("swaymsg -t get_inputs")
	end
	if not out or not out:match("%[") then
		return nil, "swaymsg failed"
	end
	local ok, data = pcall(json_decode, out)
	if not ok or type(data) ~= "table" then
		return nil, "parse error"
	end
	return data, nil
end

-- Return the first touchpad device, or nil.
function M.touchpad()
	local devs, err = get_inputs()
	if not devs then
		return nil, err
	end
	for _, d in ipairs(devs) do
		if d.type == "touchpad" then
			return d, nil
		end
	end
	return nil, nil -- no touchpad (e.g. desktop)
end

-- Return the first pointer (mouse) device, or nil.
function M.mouse()
	local devs, err = get_inputs()
	if not devs then
		return nil, err
	end
	for _, d in ipairs(devs) do
		if d.type == "pointer" then
			return d, nil
		end
	end
	return nil, nil
end

-- ── reading libinput settings ───────────────────────────────────────────────
-- Helpers that pull one setting out of a device's libinput table, tolerating
-- the field being absent (not all devices expose all settings).

-- boolean-ish: libinput reports "enabled"/"disabled"
local function is_enabled(dev, key)
	if not dev or type(dev.libinput) ~= "table" then
		return nil
	end
	local v = dev.libinput[key]
	if v == "enabled" then
		return true
	end
	if v == "disabled" then
		return false
	end
	return nil
end
M.is_enabled = is_enabled

-- numeric: accel_speed is -1.0..1.0
local function number_of(dev, key)
	if not dev or type(dev.libinput) ~= "table" then
		return nil
	end
	local v = dev.libinput[key]
	if type(v) == "number" then
		return v
	end
	return nil
end
M.number_of = number_of

-- string: scroll_method, accel_profile, etc.
local function string_of(dev, key)
	if not dev or type(dev.libinput) ~= "table" then
		return nil
	end
	local v = dev.libinput[key]
	if type(v) == "string" then
		return v
	end
	return nil
end
M.string_of = string_of

-- ── applying settings (runtime) ─────────────────────────────────────────────
-- All go through `swaymsg input <identifier> <setting> <value>`. Runtime only.

local function apply(identifier, setting, value)
	if not have_sway() then
		return false, "swaymsg not found"
	end
	if not identifier then
		return false, "no device"
	end
	-- Pass the whole "input ... <value>" as ONE argument to swaymsg. Otherwise
	-- a negative value like pointer_accel -0.40 is parsed by swaymsg as a
	-- command-line option (leading '-'), which is exactly why speeds below the
	-- midpoint silently failed. Quoting the identifier inside the single-quoted
	-- command keeps spaces/colons intact.
	local cmd = string.format("input %q %s %s", identifier, setting, value)
	-- escape single quotes in the command for the shell wrapper, then wrap
	local escaped = cmd:gsub("'", "'\\''")
	local _, ok = shell("swaymsg '" .. escaped .. "'")
	if ok then
		return true, nil
	end
	return false, "swaymsg input failed"
end
M.apply = apply

-- Toggle-style setters (enabled/disabled)
function M.set_tap(id, on)
	return apply(id, "tap", on and "enabled" or "disabled")
end
function M.set_natural_scroll(id, on)
	return apply(id, "natural_scroll", on and "enabled" or "disabled")
end
function M.set_dwt(id, on)
	return apply(id, "dwt", on and "enabled" or "disabled")
end -- disable-while-typing
function M.set_middle_emulation(id, on)
	return apply(id, "middle_emulation", on and "enabled" or "disabled")
end
function M.set_left_handed(id, on)
	return apply(id, "left_handed", on and "enabled" or "disabled")
end

-- Pointer acceleration: libinput accel_speed is -1.0..1.0. We expose it to the
-- UI as a 0-100 slider and convert. 0 -> -1.0 (slowest), 100 -> 1.0 (fastest).
function M.accel_to_slider(accel)
	local a = tonumber(accel) or 0
	return math.floor((a + 1) / 2 * 100 + 0.5)
end
function M.slider_to_accel(pct)
	local p = math.max(0, math.min(100, tonumber(pct) or 50))
	return (p / 100) * 2 - 1
end
function M.set_accel(id, accel)
	return apply(id, "pointer_accel", string.format("%.2f", accel))
end

-- ── cursor theming (Sway seat + XCURSOR + optional GTK) ─────────────────────
-- Cursor theme and size are set live with `swaymsg seat seat0 xcursor_theme
-- <name> <size>`. Like the libinput settings above, this is RUNTIME ONLY and
-- resets on Sway restart; to persist, the same line goes in the Sway config.
-- GTK apps read their cursor from gsettings, so we optionally push there too.

-- List installed cursor themes. A directory is a cursor theme if it contains a
-- "cursors/" subdirectory. Scans the standard icon locations. Returns a
-- sorted, de-duplicated list of theme names.
function M.cursor_themes()
	local home = os.getenv("HOME") or ""
	local dirs = {
		home ~= "" and (home .. "/.icons") or nil,
		home ~= "" and (home .. "/.local/share/icons") or nil,
		"/usr/share/icons",
		"/usr/local/share/icons",
	}
	local seen, themes = {}, {}
	for _, base in ipairs(dirs) do
		-- list immediate subdirs that contain a cursors/ folder
		local cmd = string.format('for d in %q/*/; do [ -d "$d/cursors" ] && basename "$d"; done 2>/dev/null', base)
		local out = shell(cmd)
		if out then
			for name in out:gmatch("[^\n]+") do
				name = name:gsub("%s+$", "")
				if name ~= "" and not seen[name] then
					seen[name] = true
					themes[#themes + 1] = name
				end
			end
		end
	end
	table.sort(themes, function(a, b)
		return a:lower() < b:lower()
	end)
	return themes
end

-- Current cursor theme/size. Sway doesn't report the active xcursor_theme back
-- through the IPC, so we read the environment (what the session started with)
-- and fall back to gsettings for GTK. Returns theme (string|nil), size (num|nil).
function M.cursor_current()
	local theme = os.getenv("XCURSOR_THEME")
	local size = tonumber(os.getenv("XCURSOR_SIZE"))
	if not theme and have("gsettings") then
		local t = shell("gsettings get org.gnome.desktop.interface cursor-theme")
		if t then
			theme = t:match("'([^']+)'")
		end
	end
	if not size and have("gsettings") then
		local s = shell("gsettings get org.gnome.desktop.interface cursor-size")
		if s then
			size = tonumber(s:match("%d+"))
		end
	end
	return theme, size
end

-- Apply cursor theme + size live to the Sway seat. Runtime only.
function M.set_cursor(theme, size)
	if not have_sway() then
		return false, "swaymsg not found"
	end
	if not theme then
		return false, "no theme"
	end
	size = tonumber(size) or 24
	local _, ok = shell(string.format("swaymsg seat seat0 xcursor_theme %q %d", theme, size))
	if ok then
		return true, nil
	end
	return false, "swaymsg seat failed"
end

-- Push cursor theme + size to GTK (gsettings), so GTK apps match. Persistent
-- for GTK since gsettings is stored, unlike the Sway seat command.
function M.set_cursor_gtk(theme, size)
	if not have("gsettings") then
		return false, "gsettings not found"
	end
	if not theme then
		return false, "no theme"
	end
	size = tonumber(size) or 24
	shell(string.format("gsettings set org.gnome.desktop.interface cursor-theme %q", theme))
	shell(string.format("gsettings set org.gnome.desktop.interface cursor-size %d", size))
	return true, nil
end

-- Common cursor sizes to cycle through.
M.CURSOR_SIZES = { 16, 24, 32, 48, 64 }

-- ── per-cursor composite theme builder ──────────────────────────────────────
-- There is no runtime API to change one cursor at a time: apps request cursors
-- by name and the compositor resolves them from the ACTIVE theme's cursors/
-- dir. To mix cursors per-role, we build a COMPOSITE theme on disk: a new
-- theme dir whose cursors/ folder symlinks each role from whichever source
-- theme the user chose. Point Sway at that composite and you get a mix.
--
-- Each logical ROLE maps to a canonical cursor name plus known ALIASES; when
-- we link a role we create links for every alias too, so any app finds it
-- regardless of which name it asks for.

M.CURSOR_ROLES = {
	{ key = "default", label = "Normal arrow", names = { "left_ptr", "default", "arrow", "top_left_arrow" } },
	{ key = "text", label = "Text (I-beam)", names = { "text", "xterm", "ibeam" } },
	{ key = "pointer", label = "Link (hand)", names = { "pointer", "hand2", "hand1", "hand", "pointing_hand" } },
	{ key = "wait", label = "Busy (wait)", names = { "watch", "wait" } },
	{ key = "progress", label = "Busy (working)", names = { "progress", "left_ptr_watch", "half-busy" } },
	{ key = "crosshair", label = "Crosshair", names = { "crosshair", "cross", "tcross" } },
	{ key = "grab", label = "Grab (open)", names = { "grab", "openhand", "hand1" } },
	{ key = "grabbing", label = "Grabbing", names = { "grabbing", "closedhand", "dnd-none", "fleur" } },
	{ key = "move", label = "Move", names = { "move", "fleur", "all-scroll", "size_all" } },
	{
		key = "not_allowed",
		label = "Forbidden",
		names = { "not-allowed", "crossed_circle", "forbidden", "no-drop" },
	},
	{
		key = "help",
		label = "Help",
		names = { "help", "question_arrow", "whats_this", "left_ptr_help" },
	},
	{ key = "context", label = "Context menu", names = { "context-menu" } },
	{ key = "cell", label = "Cell select", names = { "cell", "plus" } },
	{ key = "copy", label = "Drag-copy", names = { "copy", "dnd-copy" } },
	{ key = "alias", label = "Drag-link", names = { "alias", "dnd-link", "link" } },
	{ key = "zoom_in", label = "Zoom in", names = { "zoom-in", "zoom_in" } },
	{ key = "zoom_out", label = "Zoom out", names = { "zoom-out", "zoom_out" } },
	{
		key = "v_resize",
		label = "Resize ↕",
		names = { "ns-resize", "sb_v_double_arrow", "size_ver", "v_double_arrow", "top_side", "bottom_side" },
	},
	{
		key = "h_resize",
		label = "Resize ↔",
		names = { "ew-resize", "sb_h_double_arrow", "size_hor", "h_double_arrow", "left_side", "right_side" },
	},
	{
		key = "bdiag_resize",
		label = "Resize ⤢",
		names = { "nesw-resize", "size_bdiag", "fd_double_arrow", "bottom_left_corner", "top_right_corner" },
	},
	{
		key = "fdiag_resize",
		label = "Resize ⤡",
		names = { "nwse-resize", "size_fdiag", "bd_double_arrow", "top_left_corner", "bottom_right_corner" },
	},
	{ key = "col_resize", label = "Column resize", names = { "col-resize", "sb_h_double_arrow", "split_h" } },
	{ key = "row_resize", label = "Row resize", names = { "row-resize", "sb_v_double_arrow", "split_v" } },
}

-- The directory that holds all cursor theme search paths, for reading sources.
local function icon_dirs()
	local home = os.getenv("HOME") or ""
	return {
		home ~= "" and (home .. "/.icons") or nil,
		home ~= "" and (home .. "/.local/share/icons") or nil,
		"/usr/share/icons",
		"/usr/local/share/icons",
	}
end

-- Find the on-disk cursors/ directory for a named theme (first match wins).
local function theme_cursor_dir(theme)
	for _, base in ipairs(icon_dirs()) do
		local p = base .. "/" .. theme .. "/cursors"
		-- test existence via ls
		local out = shell(string.format("[ -d %q ] && echo yes", p))
		if out and out:match("yes") then
			return p
		end
	end
	return nil
end

-- Does a theme provide a given role? Returns the concrete filename (one of the
-- role's names) that exists in the theme's cursors dir, or nil.
function M.theme_has_role(theme, role)
	local dir = theme_cursor_dir(theme)
	if not dir then
		return nil
	end
	for _, name in ipairs(role.names) do
		local out = shell(string.format("[ -e %q ] && echo yes", dir .. "/" .. name))
		if out and out:match("yes") then
			return name
		end
	end
	return nil
end

-- For a given role, which installed themes provide it? Returns a list of
-- theme names. Used to populate the per-role chooser.
function M.themes_for_role(role, all_themes)
	local out = {}
	for _, t in ipairs(all_themes) do
		if M.theme_has_role(t, role) then
			out[#out + 1] = t
		end
	end
	return out
end

M.COMPOSITE_NAME = "custom-mix"

-- Build (or rebuild) the composite theme from a role->theme mapping.
--   mapping: { [role_key] = source_theme_name, ... }
-- For every role, symlink the concrete cursor file (and all its aliases) from
-- the chosen source theme into the composite's cursors/ dir. Roles left unset
-- fall back to `base_theme` so the composite is always complete.
-- Returns true, composite_path or false, err.
function M.build_composite(mapping, base_theme)
	local home = os.getenv("HOME") or ""
	if home == "" then
		return false, "no HOME"
	end
	local dest_base = home .. "/.local/share/icons/" .. M.COMPOSITE_NAME
	local dest = dest_base .. "/cursors"
	-- fresh start: remove old composite, recreate
	shell(string.format("rm -rf %q", dest_base))
	shell(string.format("mkdir -p %q", dest))
	-- write an index.theme so it's a valid, listable theme
	local idx = io.open(dest_base .. "/index.theme", "w")
	if idx then
		idx:write(
			"[Icon Theme]\nName=" .. M.COMPOSITE_NAME .. "\nComment=Per-cursor composite built by settings_menu\n"
		)
		if base_theme then
			idx:write("Inherits=" .. base_theme .. "\n")
		end
		idx:close()
	end
	-- link each role
	for _, role in ipairs(M.CURSOR_ROLES) do
		local src_theme = mapping[role.key] or base_theme
		if src_theme then
			local src_dir = theme_cursor_dir(src_theme)
			local concrete = M.theme_has_role(src_theme, role)
			if src_dir and concrete then
				local target = src_dir .. "/" .. concrete
				-- link the canonical name and every alias to that one file
				for _, name in ipairs(role.names) do
					shell(string.format("ln -sf %q %q", target, dest .. "/" .. name))
				end
			end
		end
	end
	return true, dest_base
end

-- Read back the current composite mapping if one exists, so the UI can show
-- what each role is currently sourced from. Returns { [role_key]=theme } or {}.
-- We infer the source theme by resolving each role's symlink and matching its
-- path back to a theme directory.
function M.composite_mapping()
	local home = os.getenv("HOME") or ""
	if home == "" then
		return {}
	end
	local comp = home .. "/.local/share/icons/" .. M.COMPOSITE_NAME
	local dest = comp .. "/cursors"
	local mapping = {}
	for _, role in ipairs(M.CURSOR_ROLES) do
		local link = dest .. "/" .. role.names[1]
		-- only follow ONE hop (readlink, not readlink -f) so we see the direct
		-- target theme, and ignore links that point back into the composite.
		local out = shell(string.format("readlink %q 2>/dev/null", link))
		if out then
			out = out:gsub("%s+$", "")
			local theme = out:match("/([^/]+)/cursors/[^/]+$")
			if theme and theme ~= M.COMPOSITE_NAME then
				mapping[role.key] = theme
			end
		end
	end
	return mapping
end

return M
