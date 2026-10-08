-- services_backend.lua — systemd service inventory and control.
-- Reads are unprivileged (systemctl list-units / list-unit-files / get-default).
-- Writes (start/stop/enable/disable) are privileged and are NOT run here — the
-- category routes them through core.run_pkexec with a confirmation, so this
-- module only *builds* the command strings for those.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local util = require("util")
local M = {}

-- primitives now come from the shared util module (one definition each)
local shell = util.shell
local trim = util.trim
local have = util.have

M.have = have
M.available = function()
	return have("systemctl")
end

-- ── reading state ────────────────────────────────────────────────────────────

-- Default target (graphical.target, multi-user.target, ...).
function M.default_target()
	local out = shell("systemctl get-default")
	return out and trim(out) or nil
end

-- All service units with their runtime state. Returns a list of:
--   { unit, load, active, sub, description }
-- from `systemctl list-units --type=service --all`. active is the key field:
-- "active" / "inactive" / "failed".
function M.list_units()
	if not M.available() then
		return nil, "systemctl not found"
	end
	-- run_lines always returns a table (empty on failure), so no nil/empty
	-- dance and no ambiguous tuple to unpack.
	local lines = util.run_lines("systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain")
	if #lines == 0 then
		return nil, "no units"
	end
	local units = {}
	for _, line in ipairs(lines) do
		-- columns: UNIT LOAD ACTIVE SUB DESCRIPTION (whitespace-separated,
		-- description may contain spaces so capture the rest)
		local unit, load, active, sub, desc = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.*)$")
		if unit and unit:match("%.service$") then
			units[#units + 1] = {
				unit = unit,
				load = load,
				active = active,
				sub = sub,
				description = trim(desc),
			}
		end
	end
	return units, nil
end

-- Enable-state per unit file. Returns a map { [unit] = state } where state is
-- enabled / disabled / static / masked / generated / etc.
function M.unit_file_states()
	if not M.available() then
		return {}
	end
	local out = shell("systemctl list-unit-files --type=service --no-legend")
	if not out then
		return {}
	end
	local map = {}
	for line in out:gmatch("[^\n]+") do
		local unit, state = line:match("^(%S+)%s+(%S+)")
		if unit and state then
			map[unit] = state
		end
	end
	return map
end

-- A single unit's active state, freshly queried.
function M.is_active(unit)
	local out = shell("systemctl is-active " .. util.shquote(unit))
	return out and trim(out) or "unknown"
end

-- A single unit's enable state, freshly queried.
function M.is_enabled(unit)
	local out = shell("systemctl is-enabled " .. util.shquote(unit))
	return out and trim(out) or "unknown"
end

-- ── curated views ────────────────────────────────────────────────────────────
-- Hundreds of units can't all be rows. Split into the buckets that matter:
-- failed (always surface), running, and enabled-but-inactive. Each entry is
-- augmented with its enable-state so the UI can show/act on it.

function M.categorized(limit)
	limit = limit or 40
	local units, err = M.list_units()
	if not units then
		return nil, err
	end
	local states = M.unit_file_states()

	local failed, running, enabled_inactive = {}, {}, {}
	for _, u in ipairs(units) do
		u.enabled = states[u.unit] or "—"
		if u.active == "failed" then
			failed[#failed + 1] = u
		elseif u.active == "active" then
			running[#running + 1] = u
		elseif u.enabled == "enabled" then
			enabled_inactive[#enabled_inactive + 1] = u
		end
	end

	local function by_name(a, b)
		return a.unit < b.unit
	end
	table.sort(failed, by_name)
	table.sort(running, by_name)
	table.sort(enabled_inactive, by_name)

	local function cap(list)
		local total = #list
		if total > limit then
			local capped = {}
			for i = 1, limit do
				capped[i] = list[i]
			end
			return capped, total
		end
		return list, total
	end

	local r, r_total = cap(running)
	local e, e_total = cap(enabled_inactive)
	return {
		failed = failed,
		failed_total = #failed,
		running = r,
		running_total = r_total,
		enabled_inactive = e,
		enabled_inactive_total = e_total,
	},
		nil
end

-- ── privileged action command builders ──────────────────────────────────────
-- These return the command string only; the category runs them via
-- core.run_pkexec after a confirmation prompt.

local function q(unit)
	return util.shquote(unit)
end

function M.cmd_start(unit)
	return "systemctl start " .. q(unit)
end
function M.cmd_stop(unit)
	return "systemctl stop " .. q(unit)
end
function M.cmd_restart(unit)
	return "systemctl restart " .. q(unit)
end
function M.cmd_enable(unit)
	return "systemctl enable " .. q(unit)
end
function M.cmd_disable(unit)
	return "systemctl disable " .. q(unit)
end

-- ── maintenance actions (privileged; run via pkexec from the category) ───────

-- Reload the systemd manager configuration (re-reads unit files after edits).
-- Non-destructive but privileged.
function M.cmd_daemon_reload()
	return "systemctl daemon-reload"
end

-- Vacuum the journal down to a target size (e.g. "200M") or age (e.g. "2weeks").
-- Frees disk by removing old log data. The caller passes a validated target.
function M.cmd_journal_vacuum_size(size)
	return "journalctl --vacuum-size=" .. tostring(size)
end
function M.cmd_journal_vacuum_time(time)
	return "journalctl --vacuum-time=" .. tostring(time)
end

-- ── journal info (read-only this pass) ───────────────────────────────────────

-- Current on-disk journal size, e.g. "412.0M". From journalctl --disk-usage.
function M.journal_disk_usage()
	local out = shell("journalctl --disk-usage")
	if not out then
		return nil
	end
	-- "Archived and active journals take up 412.0M in the file system."
	local size = out:match("take up%s+(%S+)%s+in") or out:match("(%S+B)%s*%.?%s*$")
	return size and trim(size) or nil
end

-- Whether the journal is stored persistently (Storage=persistent, or the
-- default 'auto' with /var/log/journal present) vs volatile (tmpfs).
function M.journal_persistent()
	-- explicit setting wins
	local conf = shell("cat /etc/systemd/journald.conf 2>/dev/null")
	if conf then
		local storage = conf:match("\n%s*Storage%s*=%s*(%S+)") or conf:match("^%s*Storage%s*=%s*(%S+)")
		if storage == "persistent" then
			return true
		end
		if storage == "volatile" then
			return false
		end
	end
	-- auto/default: persistent iff /var/log/journal exists
	local out = shell("[ -d /var/log/journal ] && echo yes")
	return out and out:match("yes") ~= nil
end

return M
