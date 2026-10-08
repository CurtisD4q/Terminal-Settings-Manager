#!/usr/bin/env lua5.4
-- Services (App 2) — systemd unit inventory and control.
-- Reads (unit lists, states, default target, journal info) are unprivileged
-- and cached, refreshed live via a dbus-monitor stream on the systemd manager.
-- Actions (start/stop/enable/disable) are privileged: they go through
-- core.run_pkexec with a confirmation prompt, then mark the cache dirty.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local svc = require("services_backend")
local EC = require("event_cache")

local CAT -- forward-declared so builders/prefetch can reference it
local cache_impl -- forward-declared so row setters can mark it dirty

-- ── event cache ──────────────────────────────────────────────────────────────
-- The systemd manager emits D-Bus signals (JobNew/JobRemoved/UnitNew/...) when
-- any unit starts or stops. dbus-monitor turns those into lines; each one means
-- "something changed", so we mark the whole view dirty and refetch. This keeps
-- idle cost at zero while staying live as services come and go.
cache_impl = EC.new({
	fetchers = {
		view = function()
			local v = svc.categorized(40)
			return v
		end,
		target = function()
			return svc.default_target()
		end,
		journal_size = function()
			return svc.journal_disk_usage()
		end,
		journal_persist = function()
			return svc.journal_persistent()
		end,
	},
	stream = "dbus-monitor --system \"type='signal',sender='org.freedesktop.systemd1'\"",
	classify = function(_line)
		-- any systemd signal potentially changes unit state; refetch the view.
		return "view"
	end,
})

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Short display name: strip the ".service" suffix for readability.
local function short(unit)
	return (unit:gsub("%.service$", ""))
end

-- Build the action rows for one unit: a start/stop toggle-button and an
-- enable/disable toggle-button, each confirmed and run via pkexec.
local function unit_action_rows(u)
	local rows = {}
	local unit = u.unit
	local is_running = (u.active == "active")
	local is_enabled = (u.enabled == "enabled")

	-- start / stop
	rows[#rows + 1] = {
		"  " .. short(unit),
		is_running and "running" or (u.active or "inactive"),
		"button",
		{
			get = function()
				return is_running and "stop" or "start"
			end,
			set = function()
				local action = is_running and "stop" or "start"
				local ok = core.run_confirm(
					action:gsub("^%l", string.upper) .. " " .. unit .. "?",
					"This will " .. action .. " the service now."
				)
				if ok then
					local cmd = is_running and svc.cmd_stop(unit) or svc.cmd_start(unit)
					core.run_pkexec(cmd, action:gsub("^%l", string.upper) .. " " .. unit)
					cache_impl:mark_all_dirty()
				end
			end,
		},
	}
	-- enable / disable (only if the unit file supports it — not static/masked)
	if u.enabled == "enabled" or u.enabled == "disabled" then
		rows[#rows + 1] = {
			"    boot",
			is_enabled and "enabled" or "disabled",
			"button",
			{
				get = function()
					return is_enabled and "disable" or "enable"
				end,
				set = function()
					local action = is_enabled and "disable" or "enable"
					local ok = core.run_confirm(
						action:gsub("^%l", string.upper) .. " " .. unit .. " at boot?",
						"This will " .. action .. " the service starting on boot."
					)
					if ok then
						local cmd = is_enabled and svc.cmd_disable(unit) or svc.cmd_enable(unit)
						core.run_pkexec(cmd, action:gsub("^%l", string.upper) .. " " .. unit)
						cache_impl:mark_all_dirty()
					end
				end,
			},
		}
	end
	return rows
end

-- ── section builders ─────────────────────────────────────────────────────────

local function failed_rows(view)
	if not view or view.failed_total == 0 then
		return { { "No failed services", "", "" } }
	end
	local rows = {}
	for _, u in ipairs(view.failed) do
		for _, r in ipairs(unit_action_rows(u)) do
			rows[#rows + 1] = r
		end
	end
	return rows
end

local function running_rows(view)
	if not view then
		return { { "Unavailable", "", "" } }
	end
	local rows = {}
	rows[#rows + 1] = {
		"Active services",
		view.running_total .. (view.running_total > #view.running and " (showing " .. #view.running .. ")" or ""),
		"",
	}
	for _, u in ipairs(view.running) do
		for _, r in ipairs(unit_action_rows(u)) do
			rows[#rows + 1] = r
		end
	end
	return rows
end

local function enabled_rows(view)
	if not view then
		return { { "Unavailable", "", "" } }
	end
	if #view.enabled_inactive == 0 then
		return { { "None", "", "" } }
	end
	local rows = {}
	rows[#rows + 1] = {
		"Enabled but not running",
		tostring(view.enabled_inactive_total),
		"",
	}
	for _, u in ipairs(view.enabled_inactive) do
		for _, r in ipairs(unit_action_rows(u)) do
			rows[#rows + 1] = r
		end
	end
	return rows
end

local function system_rows(cache)
	return {
		{ "Default target", cache.target or "—", "" },
		{ "Journal size", cache.journal_size or "—", "" },
		{ "Journal persistent", cache.journal_persist and "yes" or "no", "" },
	}
end

-- Curated maintenance one-shots for this domain. Each is a labeled button with
-- a confirmation and pkexec; nothing is free-form. Journal vacuum offers two
-- fixed targets rather than an input box, keeping it safe and predictable.
local function maintenance_rows()
	return {
		{
			"Reload systemd daemon",
			"",
			"button",
			{
				get = function()
					return "run"
				end,
				set = function()
					local ok = core.run_confirm(
						"Reload systemd daemon?",
						"Re-reads all unit files. Safe; use after editing units."
					)
					if ok then
						core.run_pkexec(svc.cmd_daemon_reload(), "Reload systemd daemon")
						cache_impl:mark_all_dirty()
					end
				end,
			},
		},
		{
			"Vacuum journal to 200M",
			"",
			"button",
			{
				get = function()
					return "run"
				end,
				set = function()
					local ok = core.run_confirm(
						"Vacuum journal to 200M?",
						"Deletes old log data, keeping the newest 200M. Frees disk space."
					)
					if ok then
						core.run_pkexec(svc.cmd_journal_vacuum_size("200M"), "Vacuum journal to 200M")
						cache_impl:mark_dirty("journal_size")
					end
				end,
			},
		},
		{
			"Vacuum journal older than 2 weeks",
			"",
			"button",
			{
				get = function()
					return "run"
				end,
				set = function()
					local ok = core.run_confirm(
						"Vacuum journal older than 2 weeks?",
						"Deletes log data older than 2 weeks. Frees disk space."
					)
					if ok then
						core.run_pkexec(svc.cmd_journal_vacuum_time("2weeks"), "Vacuum journal older than 2 weeks")
						cache_impl:mark_dirty("journal_size")
					end
				end,
			},
		},
	}
end

-- ── prefetch ────────────────────────────────────────────────────────────────

local function prefetch(cache)
	cache_impl:start()
	local view = cache_impl:get("view")
	cache.target = cache_impl:get("target")
	cache.journal_size = cache_impl:get("journal_size")
	cache.journal_persist = cache_impl:get("journal_persist")

	CAT.sections[1][2] = failed_rows(view)
	CAT.sections[2][2] = running_rows(view)
	CAT.sections[3][2] = enabled_rows(view)
	CAT.sections[4][2] = system_rows(cache)
	CAT.sections[5][2] = maintenance_rows()
end

CAT = {
	id = "services",
	label = "Services",
	icon = "⚙",
	sections = {
		{ "Failed", { { "Loading…", "", "" } } },
		{ "Running", { { "Loading…", "", "" } } },
		{ "Enabled (inactive)", { { "Loading…", "", "" } } },
		{ "System", { { "Loading…", "", "" } } },
		{ "Maintenance", { { "Loading…", "", "" } } },
	},
	prefetch = prefetch,
	poll_events = function()
		return cache_impl:poll()
	end,
}

return core.define_category(CAT, {
	on_exit = function()
		cache_impl:stop()
	end,
})
