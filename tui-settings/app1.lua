#!/usr/bin/env lua5.4
-- App 1 — Settings (C1, flash-free). Owns the terminal for the whole session and
-- runs category screens in-process — no subprocess spawning, no flash.
package.loaded["__settings_home__"] = true -- signal so category files don't self-run
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local util = require("util")
util.warm_tools() -- detect all external tools in one pass (fast category opens)

local CATEGORIES = {
	{ id = "network", label = "Network", icon = "⇄", desc = "Wi-Fi, connections, and IP" },
	{ id = "bluetooth", label = "Bluetooth & Devices", icon = "❖", desc = "Pair and manage devices" },
	{ id = "display", label = "Display & Graphics", icon = "▭", desc = "Monitors, resolution, brightness" },
	{ id = "input", label = "Mouse & Touchpad", icon = "➜", desc = "Pointer, tap, and scrolling" },
	{ id = "sound", label = "Sound", icon = "♪", desc = "Volume, devices, and per-app audio" },
	{ id = "power", label = "Power", icon = "▮", desc = "Battery, profiles, and sleep" },
	{ id = "notifications", label = "Notifications", icon = "✉", desc = "Do Not Disturb and alerts" },
	{ id = "privacy", label = "Privacy & Security", icon = "◈", desc = "Screen lock and permissions" },
	{ id = "applications", label = "Applications", icon = "▦", desc = "Default apps and startup" },
	{ id = "users", label = "Users & Accounts", icon = "◎", desc = "Accounts, groups, and sessions" },
	{ id = "region", label = "Region & Language", icon = "◍", desc = "Locale, language, and formats" },
	{ id = "datetime", label = "Date & Time", icon = "◷", desc = "Clock, time zone, and automatic time" },
	{ id = "appearance", label = "Appearance", icon = "◇", desc = "Colour theme and aesthetics" },
}
local PREFIX = "a1_"
local HOMETITLE = "◈ Settings"

-- show categories alphabetically by label
table.sort(CATEGORIES, function(a, b)
	return a.label:lower() < b.label:lower()
end)

-- map id -> module file (loaded lazily, once, then cached)
local loaded = {}
local function category_module(id)
	if loaded[id] == nil then
		local module_name = PREFIX .. id
		local ok, mod = pcall(require, module_name)
		if not ok then
			io.stderr:write("ERROR: Failed to load module: " .. module_name .. "\n")
			io.stderr:write("ERROR: " .. tostring(mod) .. "\n")
			loaded[id] = false
		else
			loaded[id] = mod
		end
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
			io.stderr:write("DEBUG: Running module: " .. id .. "\n")
			result = mod.run() -- in-process, no flash
		else
			io.stderr:write("WARNING: Module " .. id .. " not available, returning home\n")
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
