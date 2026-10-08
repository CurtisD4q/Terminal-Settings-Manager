#!/usr/bin/env lua5.4
-- Package Management (App 2) — installed package inventory and removal.
--   Count       : total rpm packages + flatpaks (read-only)
--   Package list: grouped by family (biggest first), base/protected hidden,
--                 behind local toggle switches inside each respective section
--                 so the heavy scan only runs when requested.
--   Uninstall   : singleton packages can be removed (confirmation + pkexec);
--                 multi-package families are display-only.
local dir = (arg and arg[0] or ""):match("^(.)/[^/]$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local app = require("applications_backend")
local pkgmanager = require("pkgmanager")

-- Separate toggles for singular and grouped lists to prevent unnecessary scans
local show_singular = false
local show_grouped = false

-- Cache of the expensive package scan, plus a dirty flag. prefetch fills this
-- once; it's only re-scanned when pkg_dirty is set (on first reveal of a list,
-- or after a package is removed).
local pkg_cache = {}
local pkg_dirty = false

local function packages_are_shown()
	return show_singular or show_grouped
end

-- Separate sections for singular and grouped packages
local singular_section = { "Installed Packages (singular)", { { "Loading…", "", "" } } }
local grouped_section = { "Installed Packages (grouped)", { { "Loading…", "", "" } } }

local function build_singular_rows(cache)
	local rows = {}

	-- Insert the inline toggle at the top of the Singular Packages section
	rows[#rows + 1] = {
		"Show singular packages",
		"",
		"toggle",
		{
			get = function()
				return show_singular
			end,
			set = function(v)
				show_singular = v and true or false
				if show_singular then
					pkg_dirty = true
				end
			end,
		},
	}

	if not show_singular then
		return rows
	end

	local pf = cache.pkgfam
	if not pf then
		rows[#rows + 1] = { "Loading…", "", "" }
		return rows
	end
	if pf.err then
		rows[#rows + 1] = { pf.err, "", "" }
		return rows
	end

	local singletons = {}
	for _, g in ipairs(pf.groups or {}) do
		if g.package then
			table.insert(singletons, g)
		end
	end

	if #singletons == 0 then
		rows[#rows + 1] = { "No singular packages available", "", "" }
		return rows
	end

	rows[#rows + 1] = { "Singular Packages", "(" .. #singletons .. " can be uninstalled)", "" }
	for _, g in ipairs(singletons) do
		rows[#rows + 1] = {
			g.family,
			"uninstall",
			"button",
			{
				get = function()
					return "uninstall"
				end,
				set = function()
					local pkg = g.package
					local ok = core.run_confirm(
						"Uninstall '" .. pkg .. "'?",
						"This removes the package '"
							.. pkg
							.. "' from your system.\nDependencies it pulled in are not removed."
					)
					if ok then
						-- distro-neutral: the abstraction builds the right remove
						-- command (dnf/apt/pacman/...) with the name shell-quoted.
						local cmd = pkgmanager.remove_cmd(pkg)
						if cmd then
							core.run_pkexec(cmd, "Uninstall package '" .. pkg .. "'")
							pkg_dirty = true -- package set changed; re-scan next frame
						end
					end
				end,
			},
		}
	end

	return rows
end

local function build_grouped_rows(cache)
	local rows = {}

	-- Insert the inline toggle at the top of the Grouped Packages section
	rows[#rows + 1] = {
		"Show grouped packages",
		"",
		"toggle",
		{
			get = function()
				return show_grouped
			end,
			set = function(v)
				show_grouped = v and true or false
				if show_grouped then
					pkg_dirty = true
				end
			end,
		},
	}

	if not show_grouped then
		return rows
	end

	local pf = cache.pkgfam
	if not pf then
		rows[#rows + 1] = { "Loading…", "", "" }
		return rows
	end
	if pf.err then
		rows[#rows + 1] = { pf.err, "", "" }
		return rows
	end

	local grouped = {}
	for _, g in ipairs(pf.groups or {}) do
		if not g.package then
			table.insert(grouped, g)
		end
	end

	-- Sort grouped packages alphabetically by family name
	table.sort(grouped, function(a, b)
		return a.family:lower() < b.family:lower()
	end)

	if #grouped == 0 then
		rows[#rows + 1] = { "No grouped packages available", "", "" }
		return rows
	end

	local head = (pf.total and (pf.total .. " total") or "unknown")
	if pf.hidden and pf.hidden > 0 then
		head = head .. "  ·  " .. pf.hidden .. " base hidden"
	end
	rows[#rows + 1] = { "Grouped Packages", head, "" }

	for _, g in ipairs(grouped) do
		rows[#rows + 1] = { g.family, "×" .. g.count, "" }
	end

	return rows
end

local CAT = {
	id = "packagemgmt",
	label = "Package Management",
	icon = "▦",
	sections = {
		{
			"Overview",
			{
				{
					"Installed",
					"—",
					"",
					{
						get = function(c)
							local ct = c.counts or {}
							local parts = {}
							if ct.rpm then
								parts[#parts + 1] = ct.rpm .. " packages"
							end
							if ct.flatpak then
								parts[#parts + 1] = ct.flatpak .. " flatpaks"
							end
							return (#parts > 0 and table.concat(parts, ", ") or "unknown")
						end,
					},
				},
			},
		},
		singular_section,
		grouped_section,
	},
	prefetch = function(cache)
		-- Package data is expensive (rpm -qa scan + flatpak list) and only
		-- changes when packages are installed/removed. Cache it and re-fetch
		-- only when dirty — set on entry and after a remove action below.
		if pkg_cache.counts == nil or pkg_dirty then
			pkg_cache.counts = app.installed_counts()
			if packages_are_shown() then
				pkg_cache.pkgfam = app.package_families()
			else
				pkg_cache.pkgfam = nil
			end
			pkg_dirty = false
		end
		cache.counts = pkg_cache.counts
		cache.pkgfam = pkg_cache.pkgfam
		singular_section[2] = build_singular_rows(cache)
		grouped_section[2] = build_grouped_rows(cache)
	end,
}

return core.define_category(CAT)
