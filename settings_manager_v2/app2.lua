#!/usr/bin/env lua5.4
-- App 2 — System Administration (C1, flash-free). Owns the terminal for the whole session and
-- runs category screens in-process — no subprocess spawning, no flash.
package.loaded["__settings_home__"] = true -- signal so category files don't self-run
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local util = require("util")
util.warm_tools() -- detect all external tools in one pass (fast category opens)

local CATEGORIES = {
	{ id = "packagemgmt", label = "Package Management", icon = "▦", desc = "Installed packages and removal" },
	{ id = "sysinfo", label = "System Information", icon = "▣", desc = "Hardware and OS overview" },
	{ id = "kernel_boot", label = "Kernel & Boot", icon = "◈", desc = "Kernel versions and boot loader" },
	{ id = "kernel_tuning", label = "Kernel Tuning", icon = "▦", desc = "sysctl and low-level tuning" },
	{ id = "services", label = "Services", icon = "⚙", desc = "systemd units and logs" },
	{ id = "storage", label = "Storage & Filesystems", icon = "▤", desc = "Disks, volumes, and mounts" },
	{ id = "encryption", label = "Disk Encryption", icon = "▥", desc = "LUKS and disk encryption" },
}
local PREFIX = "a2_"
local HOMETITLE = "◈ Advanced Settings"

-- show categories alphabetically by label
table.sort(CATEGORIES, function(a, b)
	return a.label:lower() < b.label:lower()
end)

-- map id -> module file (loaded lazily, once, then cached)
local loaded = {}
local function category_module(id)
	if loaded[id] == nil then
		local ok, mod = pcall(require, PREFIX .. id)
		loaded[id] = ok and mod or false
	end
	return loaded[id]
end

local function session()
	local sel = 1
	while true do
		local choice = core.run_home(CATEGORIES, sel, HOMETITLE)
		if choice == nil then
			return
		end -- q at the grid -> quit
		sel = choice
		local id = CATEGORIES[choice].id
		local mod = category_module(id)
		local result
		if mod and mod.run then
			result = mod.run() -- in-process, no flash
		else
			result = "home"
		end
		if result == "quit" then
			return
		end -- q inside a category -> quit all
	end
end

core.screen_enter()
local ok, err = pcall(session)
core.screen_leave()
if not ok then
	io.stderr:write("error: " .. tostring(err) .. "\n")
	os.exit(1)
end
os.exit(0)
