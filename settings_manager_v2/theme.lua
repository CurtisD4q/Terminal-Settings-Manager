-- theme.lua — colour theming for tui-cinnamon.
--
-- The app draws coloured TEXT (foreground) on top of the terminal's own
-- background; this module decides which colours. It produces a palette table
-- with the seven colour roles the UI uses, plus the bold/dim attributes, ready
-- to drop into core as M.C.
--
-- Sources of a theme, in the order the UI offers them:
--   "default"   the app's built-in purple (fixed 256-colour indices)
--   "terminal"  inherit the user's terminal theme (the 16 ANSI colours), so
--               the app blends into whatever colour scheme the terminal uses
--   named preset  nord / gruvbox / dracula / catppuccin (fixed true-colour RGB)
--   "custom"    RGB read from ~/.config/tui-settings/theme.conf
--
-- Everything is pure Lua, no dependencies. Colours are emitted as SGR escape
-- sequences: indexed (38;5;N) for default, ANSI (3N/9N) for terminal, and
-- true-colour (38;2;R;G;B) for presets and custom.
local M = {}

local ESC = "\27["
local function sgr(...)
	return ESC .. table.concat({ ... }, ";") .. "m"
end

-- attributes shared by every theme
local BOLD = sgr(1)
local DIM = sgr(2)

-- ── colour constructors ──────────────────────────────────────────────────────

-- foreground / background from a fixed 256-colour index (the original style)
local function idx_fg(n)
	return sgr(38, 5, n)
end
local function idx_bg(n)
	return sgr(48, 5, n)
end

-- foreground / background from true-colour RGB
local function rgb_fg(r, g, b)
	return sgr(38, 2, r, g, b)
end
local function rgb_bg(r, g, b)
	return sgr(48, 2, r, g, b)
end

-- ── the seven roles every theme must define ──────────────────────────────────
-- accent  : primary highlight (titles, selection text)
-- bright  : secondary highlight / emphasised values
-- text    : normal body text
-- muted   : secondary/label text
-- on      : "enabled/on/good" state (usually green)
-- amber   : "warning/attention" state
-- selbg   : selection background bar

-- ── default: the built-in purple (unchanged from the original) ───────────────
local function theme_default()
	return {
		accent = idx_fg(141),
		bright = idx_fg(183),
		text = idx_fg(253),
		muted = idx_fg(245),
		on = idx_fg(114),
		amber = idx_fg(214),
		selbg = idx_bg(237),
		bold = BOLD,
		dim = DIM,
	}
end

-- ── terminal: inherit the 16 ANSI colours (follows the terminal theme) ───────
-- Uses ANSI colour codes (30-37 normal, 90-97 bright) so each role maps to a
-- terminal palette slot; the actual hues come from the user's terminal theme.
--   fg 3N = normal colour N, 9N = bright colour N  (N: 0 blk 1 red 2 grn 3 yel
--   4 blu 5 mag 6 cyn 7 wht)
local function theme_terminal()
	return {
		accent = sgr(95), -- bright magenta
		bright = sgr(97), -- bright white
		text = sgr(37), -- white
		muted = sgr(90), -- bright black (grey)
		on = sgr(92), -- bright green
		amber = sgr(93), -- bright yellow
		selbg = sgr(100), -- bright-black background
		bold = BOLD,
		dim = DIM,
	}
end

-- ── named presets (fixed true-colour RGB) ────────────────────────────────────
-- Each is expressed as RGB triples so it looks identical on any true-colour
-- terminal, independent of the terminal's own theme.
local function from_rgb(spec)
	return {
		accent = rgb_fg(spec.accent[1], spec.accent[2], spec.accent[3]),
		bright = rgb_fg(spec.bright[1], spec.bright[2], spec.bright[3]),
		text = rgb_fg(spec.text[1], spec.text[2], spec.text[3]),
		muted = rgb_fg(spec.muted[1], spec.muted[2], spec.muted[3]),
		on = rgb_fg(spec.on[1], spec.on[2], spec.on[3]),
		amber = rgb_fg(spec.amber[1], spec.amber[2], spec.amber[3]),
		selbg = rgb_bg(spec.selbg[1], spec.selbg[2], spec.selbg[3]),
		bold = BOLD,
		dim = DIM,
	}
end

local PRESETS = {
	nord = {
		accent = { 136, 192, 208 }, -- frost cyan
		bright = { 143, 188, 187 },
		text = { 216, 222, 233 },
		muted = { 118, 128, 144 },
		on = { 163, 190, 140 }, -- green
		amber = { 235, 203, 139 }, -- yellow
		selbg = { 59, 66, 82 },
	},
	gruvbox = {
		accent = { 250, 189, 47 }, -- yellow
		bright = { 254, 128, 25 }, -- orange
		text = { 235, 219, 178 },
		muted = { 168, 153, 132 },
		on = { 184, 187, 38 }, -- green
		amber = { 250, 189, 47 },
		selbg = { 60, 56, 54 },
	},
	dracula = {
		accent = { 189, 147, 249 }, -- purple
		bright = { 255, 121, 198 }, -- pink
		text = { 248, 248, 242 },
		muted = { 98, 114, 164 },
		on = { 80, 250, 123 }, -- green
		amber = { 241, 250, 140 }, -- yellow
		selbg = { 68, 71, 90 },
	},
	catppuccin = {
		accent = { 203, 166, 247 }, -- mauve
		bright = { 245, 194, 231 }, -- pink
		text = { 205, 214, 244 },
		muted = { 127, 132, 156 },
		on = { 166, 227, 161 }, -- green
		amber = { 249, 226, 175 }, -- yellow
		selbg = { 49, 50, 68 },
	},
}

-- ── custom RGB from the config file ──────────────────────────────────────────
local THEME_CFG = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/tui-settings/theme.conf"

-- Parse the theme config: lines of `role = R G B` (0-255 each). Missing roles
-- fall back to the default palette so a partial file still works. Returns a
-- palette table, or nil if the file is absent/unreadable.
local function theme_custom()
	local f = io.open(THEME_CFG, "r")
	if not f then
		return nil
	end
	local spec = {}
	for line in f:lines() do
		local role, r, g, b = line:match("^%s*(%a+)%s*=%s*(%d+)%s+(%d+)%s+(%d+)")
		if role then
			r, g, b = tonumber(r), tonumber(g), tonumber(b)
			-- clamp to valid range
			local function c(x)
				return math.max(0, math.min(255, x))
			end
			spec[role] = { c(r), c(g), c(b) }
		end
	end
	f:close()
	-- fill any missing roles from default (as RGB-ish via the purple indices is
	-- awkward, so use sensible neutral RGB fallbacks)
	local fallback = {
		accent = { 141, 120, 210 },
		bright = { 183, 160, 230 },
		text = { 220, 220, 220 },
		muted = { 150, 150, 150 },
		on = { 120, 200, 140 },
		amber = { 220, 180, 90 },
		selbg = { 60, 60, 70 },
	}
	for role, rgb in pairs(fallback) do
		if not spec[role] then
			spec[role] = rgb
		end
	end
	return from_rgb(spec)
end

-- The path, exposed so the UI can tell the user where to edit.
M.CONFIG_PATH = THEME_CFG

-- ── selection ────────────────────────────────────────────────────────────────

-- The list of choosable theme names, in UI order.
M.NAMES = { "default", "terminal", "nord", "gruvbox", "dracula", "catppuccin", "custom" }

-- Which theme is currently selected. Persisted in the theme config as a
-- `theme = <name>` line (separate from the custom RGB roles). Defaults to
-- "default".
local function read_selected_name()
	local f = io.open(THEME_CFG, "r")
	if not f then
		return "default"
	end
	local name = "default"
	for line in f:lines() do
		local n = line:match("^%s*theme%s*=%s*([%a]+)")
		if n then
			name = n
		end
	end
	f:close()
	return name
end

-- Build the palette table for a given theme name. Unknown or "custom" with no
-- file falls back to default, so this never returns nil.
function M.palette(name)
	name = name or read_selected_name()
	if name == "default" then
		return theme_default()
	end
	if name == "terminal" then
		return theme_terminal()
	end
	if PRESETS[name] then
		return from_rgb(PRESETS[name])
	end
	if name == "custom" then
		return theme_custom() or theme_default()
	end
	return theme_default()
end

-- The currently-selected theme name (from config).
function M.current()
	return read_selected_name()
end

-- Persist the selected theme name, preserving any custom RGB role lines already
-- in the file. Returns (ok, err).
function M.set(name)
	-- read existing role lines (so choosing a preset doesn't wipe custom RGB)
	local roles = {}
	local f = io.open(THEME_CFG, "r")
	if f then
		for line in f:lines() do
			if line:match("^%s*%a+%s*=%s*%d+%s+%d+%s+%d+") then
				roles[#roles + 1] = line
			end
		end
		f:close()
	end
	local dir = THEME_CFG:match("^(.*)/[^/]+$")
	if dir then
		os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null")
	end
	local w = io.open(THEME_CFG, "w")
	if not w then
		return false, "cannot write theme config"
	end
	w:write("# tui-cinnamon theme\n")
	w:write("theme = " .. name .. "\n")
	if #roles > 0 then
		w:write("\n# custom RGB (used when theme = custom); role = R G B (0-255)\n")
		for _, l in ipairs(roles) do
			w:write(l .. "\n")
		end
	elseif name == "custom" then
		-- seed a template so the user has something to edit
		w:write("\n# custom RGB (theme = custom); role = R G B (0-255)\n")
		w:write("accent = 124 58 237\n")
		w:write("bright = 167 139 250\n")
		w:write("text = 229 229 229\n")
		w:write("muted = 150 150 150\n")
		w:write("on = 52 211 153\n")
		w:write("amber = 251 191 36\n")
		w:write("selbg = 55 48 107\n")
	end
	w:close()
	return true, nil
end

return M
