#!/usr/bin/env lua5.4
-- Date & Time — LIVE via timedatectl.
--   Automatic time (NTP) — toggle (needs root; reports "needs root" if denied)
--   Time zone             — cycle through the full tz database
--   Current time          — read-only display
-- Clock format is a display preference with no system backing, kept static.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local dt = require("datetime_backend")

-- preview state: the timezone shown while cycling, before applying
local tz_preview = nil

local function cycle_tz(step, cache)
	local zones = cache.zones
	if not zones or #zones == 0 then
		return
	end
	local cur = tz_preview or cache.tz
	if step == 0 then
		-- Enter: apply the previewed timezone (needs root -> pkexec)
		if tz_preview and tz_preview ~= cache.tz then
			core.run_pkexec("timedatectl set-timezone " .. tz_preview, "Set time zone to " .. tz_preview)
			tz_preview = nil
		end
		return
	end
	-- left/right: just preview locally, no password
	local idx = 1
	for i, z in ipairs(zones) do
		if z == cur then
			idx = i
			break
		end
	end
	local n = #zones
	tz_preview = zones[((idx - 1 + step) % n + n) % n + 1]
end

local CAT = {
	id = "datetime",
	label = "Date & Time",
	icon = "◷",
	sections = {
		{
			"Clock Source",
			{
				{
					"Automatic time",
					"—",
					"toggle",
					{
						get = function(c)
							return c.ntp, c.ntp_err
						end,
						set = function(v, c)
							core.run_pkexec(
								"timedatectl set-ntp " .. (v and "true" or "false"),
								"Turn automatic time " .. (v and "on" or "off")
							)
						end,
					},
				},
				{ "Current time", "—", "", {
					get = function(c)
						return c.now, nil
					end,
				} },
			},
		},
		{
			"Zone & Format",
			{
				{
					"Time zone",
					"—",
					"choice",
					{
						get = function(c)
							if tz_preview and tz_preview ~= c.tz then
								return tz_preview .. " *", c.tz_err -- * = pending, press Enter to apply
							end
							return c.tz, c.tz_err
						end,
						set = function(step, c)
							cycle_tz(step, c)
						end,
					},
				},
				{ "Clock format", "24-hour", "" }, -- static (display preference)
			},
		},
	},
	prefetch = function(cache)
		local ntp, nerr = dt.get_ntp()
		cache.ntp, cache.ntp_err = ntp, nerr
		local tz, terr = dt.get_timezone()
		cache.tz, cache.tz_err = tz, terr
		cache.zones = dt.list_timezones()
		cache.now = dt.now()
	end,
}

return core.define_category(CAT)
