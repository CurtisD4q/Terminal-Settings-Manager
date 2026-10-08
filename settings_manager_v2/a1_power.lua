#!/usr/bin/env lua5.4
-- Power settings — LIVE category. Wired via:
--   Battery status  — /sys/class/power_supply (read-only)
--   Power profile   — powerprofilesctl (power-profiles-daemon)
-- Sleep/idle timeouts stay static — under Sway those live in your idle-daemon
-- config (swayidle), not a settings daemon, so there's no uniform CLI to hook.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local power = require("power_backend")

local function cycle_profile(step, cache)
	if step == 0 then
		step = 1
	end -- Enter re-advances (non-root: apply immediately)
	local list = cache.profiles
	if not list or #list == 0 then
		return
	end
	local cur = cache.profile
	local idx = 1
	for i, p in ipairs(list) do
		if p == cur then
			idx = i
			break
		end
	end
	local n = #list
	local nextidx = ((idx - 1 + step) % n + n) % n + 1
	power.set_profile(list[nextidx])
end

local CAT = {
	id = "power",
	label = "Power",
	icon = "▮",
	sections = {
		{
			"Battery",
			{
				{
					"Charge level",
					"—",
					"",
					{
						get = function(c)
							if not c.bat or not c.bat.present then
								return nil, "no battery"
							end
							return (c.bat.percent and (c.bat.percent .. "%") or "unknown")
								.. (c.bat.status and (" · " .. c.bat.status) or ""),
								nil
						end,
					},
				},
				{
					"Health",
					"—",
					"",
					{
						get = function(c)
							if c.bat_health then
								return c.bat_health .. "%", nil
							end
							return nil, "n/a"
						end,
					},
				},
			},
		},
		{
			"Power Profile",
			{
				{
					"Profile",
					"—",
					"choice",
					{
						get = function(c)
							return c.profile, c.profile_err
						end,
						set = function(step, c)
							cycle_profile(step, c)
						end,
					},
				},
			},
		},
		{
			"Sleep & Idle",
			{
				{ "Screen blank", "5 min", "" },
				{ "Auto-suspend", "15 min", "" },
				{ "Lid action", "Suspend", "" },
			},
		},
	},
	prefetch = function(cache)
		cache.bat = power.battery()
		cache.bat_health = power.battery_health()
		local prof, perr = power.get_profile()
		cache.profile, cache.profile_err = prof, perr
		cache.profiles = power.list_profiles()
	end,
}

return core.define_category(CAT)
