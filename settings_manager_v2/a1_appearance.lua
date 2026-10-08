#!/usr/bin/env lua5.4
-- Appearance — choose the colour theme for tui-cinnamon.
--   Theme       — cycle: default (purple) / terminal (inherit) / nord /
--                 gruvbox / dracula / catppuccin / custom
--   A note tells the user changes apply next launch, and where the custom
--   config file lives.
-- The app draws coloured foreground text on the terminal's own background, so
-- theming affects text/accents/highlights, not the background.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local theme = require("theme")

local CAT

-- friendly labels for the theme names
local LABELS = {
	default = "Default (purple)",
	terminal = "Terminal (inherit)",
	nord = "Nord",
	gruvbox = "Gruvbox",
	dracula = "Dracula",
	catppuccin = "Catppuccin",
	custom = "Custom (config file)",
}

local function label_for(name)
	return LABELS[name] or name
end

-- cycle to the next/previous theme name in the list
local function cycle(name, dir)
	local names = theme.NAMES
	local idx = 1
	for i, n in ipairs(names) do
		if n == name then
			idx = i
			break
		end
	end
	local n = #names
	if dir == 0 then
		dir = 1
	end
	local nextidx = ((idx - 1 + dir) % n + n) % n + 1
	return names[nextidx]
end

CAT = {
	id = "appearance",
	label = "Appearance",
	icon = "◇",
	sections = {
		{
			"Theme",
			{
				{
					"Colour theme",
					"—",
					"choice",
					{
						get = function(c)
							return label_for(c.theme_name or "default")
						end,
						set = function(step, c)
							local cur = c.theme_name or "default"
							local nextname = cycle(cur, step)
							theme.set(nextname)
							c.theme_name = nextname
						end,
					},
				},
			},
		},
		{
			"Notes",
			{
				{ "Applies", "on next launch", "" },
				{ "Custom colours", "edit config file", "" },
				{ "  file", theme.CONFIG_PATH, "" },
				{ "Scope", "text & accents (not background)", "" },
			},
		},
	},
	prefetch = function(cache)
		cache.theme_name = theme.current()
	end,
}

return core.define_category(CAT)
