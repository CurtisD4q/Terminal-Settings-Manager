#!/usr/bin/env lua5.4
-- Region & Language — LIVE. Locale and keymap are now writable via pkexec
-- (localectl needs root; the polkit agent prompts for a password). Time zone
-- stays read-only here (change it in Date & Time).
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local r = require("region_users_backend")

local function cycle_in(list, cur, step)
	if not list or #list == 0 then
		return nil
	end
	local idx = 1
	for i, v in ipairs(list) do
		if v == cur then
			idx = i
			break
		end
	end
	local n = #list
	return list[((idx - 1 + step) % n + n) % n + 1]
end

-- preview state: values shown while cycling, before applying with Enter
local locale_preview, keymap_preview = nil, nil

local CAT = {
	id = "region",
	label = "Region & Language",
	icon = "◍",
	sections = {
		{
			"Language",
			{
				{
					"System locale",
					"—",
					"choice",
					{
						get = function(c)
							if locale_preview and locale_preview ~= c.locale then
								return locale_preview .. " *", nil
							end
							return c.locale, nil
						end,
						set = function(step, c)
							if step == 0 then
								if locale_preview and locale_preview ~= c.locale then
									core.run_pkexec(
										"localectl set-locale LANG=" .. locale_preview,
										"Set system locale to " .. locale_preview
									)
									locale_preview = nil
								end
							else
								locale_preview = cycle_in(c.locales, locale_preview or c.locale, step)
							end
						end,
					},
				},
			},
		},
		{
			"Formats",
			{
				{
					"Keyboard layout",
					"—",
					"choice",
					{
						get = function(c)
							if keymap_preview and keymap_preview ~= c.keymap then
								return keymap_preview .. " *", nil
							end
							return c.keymap, nil
						end,
						set = function(step, c)
							if step == 0 then
								if keymap_preview and keymap_preview ~= c.keymap then
									core.run_pkexec(
										"localectl set-keymap " .. keymap_preview,
										"Set keyboard layout to " .. keymap_preview
									)
									keymap_preview = nil
								end
							else
								keymap_preview = cycle_in(c.keymaps, keymap_preview or c.keymap, step)
							end
						end,
					},
				},
				{ "Time zone", "—", "", {
					get = function()
						return r.timezone()
					end,
				} },
			},
		},
	},
	prefetch = function(cache)
		cache.locale = r.system_locale()
		cache.keymap = r.keymap()
		cache.locales = r.list_locales()
		cache.keymaps = r.list_keymaps()
	end,
}

return core.define_category(CAT)
