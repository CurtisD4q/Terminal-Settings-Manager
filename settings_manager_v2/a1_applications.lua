#!/usr/bin/env lua5.4
-- Applications — non-admin functions only (no root, no config editing).
--   Default apps  : browser / mail / file-manager, cycle with ←/→ (xdg tools)
--   Autostart     : READ-ONLY merged list (user overrides system), name + state
--   Installed apps: READ-ONLY count + GUI app list
-- Uninstall, repositories, and update policy need root and are omitted.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local app = require("applications_backend")

-- cycle a default app among its installed candidates (←/→)
local function cycle_default(which, step, cache)
	local cands = cache["cand_" .. which]
	if not cands or #cands == 0 then
		return
	end
	local cur = cache["def_" .. which]
	local cur_id = cur and cur.id
	local idx = 1
	for i, c in ipairs(cands) do
		if c.id == cur_id then
			idx = i
			break
		end
	end
	local n = #cands
	local nextidx = ((idx - 1 + step) % n + n) % n + 1
	app.set_default(which, cands[nextidx].id)
end

-- open a full picker of installed apps to set the default for `which` (Enter).
-- This searches ALL .desktop applications, not just ones that pre-declare the
-- kind's MIME type, so anything installed can be chosen. MIME-matching apps are
-- listed first and marked, but the whole app list is available and filterable.
local function pick_default(which, label, cache)
	local apps = app.candidates_or_all(which)
	if #apps == 0 then
		return
	end
	local items = {}
	for _, a in ipairs(apps) do
		local tag = a.recommended and "  ★" or ""
		items[#items + 1] = { label = a.name .. tag, value = a.id }
	end
	local chosen = core.run_picker("Set default: " .. label, items, "★ = advertises support   ·   type to filter")
	if chosen then
		app.set_default(which, chosen)
		-- refresh this default in the cache so the row updates immediately
		local d = app.get_default(which)
		cache["def_" .. which] = d
	end
end

local function default_row(label, which)
	return {
		label,
		"—",
		"choice",
		{
			get = function(c)
				local d = c["def_" .. which]
				if not d then
					return nil, (c["err_" .. which] or "unset")
				end
				return d.name
			end,
			set = function(step, c)
				if step == 0 then
					-- Enter/apply: open the full app picker
					pick_default(which, label, c)
				else
					-- ←/→: quick-cycle among advertised candidates
					cycle_default(which, step, c)
				end
			end,
		},
	}
end

-- dynamic sections rebuilt each prefetch
local autostart_section = { "Autostart (read-only)", { { "Loading…", "", "" } } }
local installed_section = { "Installed Apps (read-only)", { { "Loading…", "", "" } } }

local function build_autostart_rows(cache)
	-- Deferred: scanning autostart dirs is filesystem work we don't do on open.
	-- Until the user presses "Show autostart entries", show that button instead.
	if not cache._autostart_loaded then
		return {
			{
				"Show autostart entries",
				"",
				"button",
				{
					get = function()
						return ""
					end,
					set = function(_, c)
						c._load_autostart = true
					end,
				},
			},
		}
	end
	local list = cache.autostart
	if not list or #list == 0 then
		return { { "No autostart entries", "", "" } }
	end
	local rows = {}
	for _, e in ipairs(list) do
		local state = e.enabled and "enabled" or "disabled"
		local tag = (e.scope == "user") and "user" or "system"
		rows[#rows + 1] = { e.name, state .. "  ·  " .. tag, "" }
	end
	return rows
end

local function build_installed_rows(cache)
	-- Deferred: enumerating every installed app's .desktop file is the slowest
	-- thing this category does. Until the user presses "Show installed apps",
	-- show that button instead of scanning on open.
	if not cache._installed_loaded then
		return {
			{
				"Show installed apps",
				"",
				"button",
				{
					get = function()
						return ""
					end,
					set = function(_, c)
						c._load_installed = true
					end,
				},
			},
		}
	end
	local rows = {}
	-- Export button first, so it's easy to reach without scrolling the whole
	-- list. Its value cell shows where the file was written after a press.
	rows[#rows + 1] = {
		"Export to Downloads",
		cache.export_msg or "",
		"button",
		{
			get = function()
				return cache.export_msg or ""
			end,
			set = function(_, c)
				local path, err = app.export_installed_apps()
				if path then
					c.export_msg = "saved: " .. path
				else
					c.export_msg = "failed: " .. (err or "unknown")
				end
			end,
		},
	}
	-- GUI app names only (the package/flatpak COUNT moved to App 2's Package
	-- Management category). The list can be long but the screen scrolls fine.
	for _, name in ipairs(cache.apps or {}) do
		rows[#rows + 1] = { name, "", "" }
	end
	if #rows == 1 then
		rows[#rows + 1] = { "No apps found", "", "" }
	end
	return rows
end

local CAT = {
	id = "applications",
	label = "Applications",
	icon = "▦",
	sections = {
		{
			"Default Apps",
			{
				default_row("Web browser", "browser"),
				default_row("Email", "mail"),
				default_row("File manager", "files"),
				default_row("Text & code", "text"),
				default_row("Documents", "documents"),
				default_row("Presentations", "presentations"),
				default_row("Spreadsheets", "spreadsheets"),
			},
		},
		autostart_section,
		installed_section,
	},
	prefetch = function(cache)
		for _, which in ipairs({
			"browser",
			"mail",
			"files",
			"text",
			"documents",
			"presentations",
			"spreadsheets",
		}) do
			local d, err = app.get_default(which)
			cache["def_" .. which] = d
			cache["err_" .. which] = err
			cache["cand_" .. which] = app.candidates(which)
		end
		-- Autostart and installed-apps lists are deferred: both scan directories
		-- full of .desktop files, which is the slow part of this category. They
		-- load only when the user presses their "Show…" button (which sets the
		-- corresponding flag), keeping the category fast to open. The default-app
		-- rows above are quick individual lookups, so they stay eager.
		if cache._load_autostart then
			cache.autostart = app.autostart()
			cache._autostart_loaded = true
			cache._load_autostart = false
		end
		if cache._load_installed then
			cache.apps = app.installed_apps()
			cache._installed_loaded = true
			cache._load_installed = false
		end
		autostart_section[2] = build_autostart_rows(cache)
		installed_section[2] = build_installed_rows(cache)
	end,
}

return core.define_category(CAT)
