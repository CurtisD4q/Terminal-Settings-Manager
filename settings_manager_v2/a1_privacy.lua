#!/usr/bin/env lua5.4
-- Privacy & Security — the genuinely-doable parts only. Rows that would need
-- editing PAM, xdg-desktop-portal, or swayidle config were removed (see README).
--   Firewall        : live status + enable/disable (pkexec)
--   Secure Boot     : read-only status
--   Disk encryption : read-only status
--   Clear system logs: action (pkexec journal vacuum) with confirmation
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local p = require("privacy_backend")

local CAT = {
	id = "privacy",
	label = "Privacy & Security",
	icon = "◈",
	sections = {
		{
			"Firewall",
			{
				{
					"Firewall",
					"—",
					"toggle",
					{
						get = function(c)
							return c.fw, c.fw_err
						end,
						set = function(v, c)
							-- the firewall driver runs its own pkexec internally;
							-- we inject core.run_pkexec and get back only ok/err.
							p.firewall_set(v, core.run_pkexec)
						end,
					},
				},
				{
					"Default zone",
					"—",
					"",
					{
						get = function(c)
							return c.fw_zone or "—", nil
						end,
					},
				},
			},
		},
		{
			"System Protection (read-only)",
			{
				{ "Secure Boot", "—", "", {
					get = function(c)
						return c.sb
					end,
				} },
				{ "Disk encryption", "—", "", {
					get = function(c)
						return c.enc
					end,
				} },
			},
		},
		{
			"Data",
			{
				{
					"Clear system logs",
					"",
					"button",
					{
						get = function()
							return ""
						end,
						set = function()
							local ok = core.run_confirm(
								"Clear old system logs?",
								"Removes journal logs older than 7 days.\nRecent logs are kept; this frees disk space."
							)
							if ok then
								core.run_pkexec(p.cmd_log_vacuum(7), "Clear system logs older than 7 days")
							end
						end,
					},
				},
			},
		},
	},
	prefetch = function(cache)
		local fw, fwerr = p.firewall_enabled()
		cache.fw, cache.fw_err = fw, fwerr
		cache.fw_zone = p.firewall_detail()
		cache.sb = p.secure_boot()
		cache.enc = p.disk_encryption()
	end,
}

return core.define_category(CAT)
