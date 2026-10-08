#!/usr/bin/env lua5.4
-- System Information (App 2) — LIVE, read-only. All values from /proc,
-- /etc/os-release, /sys DMI, and standard unprivileged tools.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local s = require("sysinfo_backend")

-- Static values (OS, kernel, CPU, host, RAM total, etc.) never change during a
-- session, so we fetch each once and cache it. Only the "Live" section values
-- (memory used, uptime) are re-read each frame — and those are cheap /proc
-- reads. This replaces the old per-row-per-frame probing where even the static
-- DMI/CPU lookups re-ran on every redraw.
local sc = {}
local function once(key, fn)
	if sc[key] == nil then
		local ok, v = pcall(fn)
		sc[key] = ok and v or "—"
	end
	return sc[key]
end

local CAT = {
	id = "sysinfo",
	label = "System Information",
	icon = "▣",
	sections = {
		{
			"Software",
			{
				{ "OS", "—", "", {
					get = function()
						return once("os", s.os_name)
					end,
				} },
				{ "Kernel", "—", "", {
					get = function()
						return once("kernel", s.kernel)
					end,
				} },
				{ "Desktop", "—", "", {
					get = function()
						return once("desktop", s.desktop)
					end,
				} },
				{ "Shell", "—", "", {
					get = function()
						return once("shell", s.shell)
					end,
				} },
				{ "Terminal", "—", "", {
					get = function()
						return once("term", s.terminal)
					end,
				} },
			},
		},
		{
			"Hardware",
			{
				{ "Host", "—", "", {
					get = function()
						return once("host", s.host_model)
					end,
				} },
				{ "CPU", "—", "", {
					get = function()
						return once("cpu", s.cpu_model)
					end,
				} },
				{ "Cores", "—", "", {
					get = function()
						return once("cores", s.cpu_topology)
					end,
				} },
				{ "GPU", "—", "", {
					get = function()
						return once("gpu", s.gpu)
					end,
				} },
				{ "Memory", "—", "", {
					get = function()
						return once("memtotal", s.mem_total)
					end,
				} },
				{ "Disk", "—", "", {
					get = function()
						return once("disk", s.disk_used)
					end,
				} },
			},
		},
		{
			"Live",
			{
				-- re-read each frame: these genuinely change
				{ "Memory used", "—", "", {
					get = function()
						return s.mem_used()
					end,
				} },
				{ "Uptime", "—", "", {
					get = function()
						return s.uptime()
					end,
				} },
			},
		},
	},
	prefetch = function() end,
}

return core.define_category(CAT)
