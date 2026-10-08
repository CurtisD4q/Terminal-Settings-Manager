-- kernel_tuning_backend.lua — SAFE, curated sysctl tuning.
--
-- Deliberately exposes only a short allowlist of well-understood, bounded,
-- non-security, self-correcting sysctls. Everything whose failure mode is
-- "locked out", "won't boot", or "confusing app failures" is excluded — in
-- particular the entire net.* and kernel.* trees, and vm.overcommit_*.
--
-- Reading current values is unprivileged. Applying live (sysctl -w) and
-- persisting (writing /etc/sysctl.d) need root; those command strings are
-- built here and run by the category via core.run_pkexec. Live changes revert
-- on reboot, so a bad value always self-heals; persistence is a separate,
-- explicit action.
local M = {}
local util = require("util")

local function shell(cmd)
	return (util.shell(cmd))
end

local trim = util.trim

-- ── the curated safe allowlist ──────────────────────────────────────────────
-- Each entry:
--   key      : the sysctl name
--   label    : friendly display name
--   desc     : one-line plain-English explanation
--   default  : the kernel's typical default (for the "vs default" display)
--   kind     : "slider" (0..100 bounded) or "preset" (fixed safe choices)
--   min/max  : for sliders — the safe bounded range (always within kernel-legal)
--   presets  : for preset kind — the allowed values to cycle through
--
-- Selection rationale is in the module header: bounded, reversible, non-
-- security, worst-case is "performance I don't love", reverts on reboot.
M.PARAMS = {
	{
		key = "vm.swappiness",
		label = "Swappiness",
		desc = "How eagerly the kernel swaps to disk (0 = avoid, 100 = eager).",
		default = 60,
		kind = "slider",
		min = 0,
		max = 100,
	},
	{
		key = "vm.vfs_cache_pressure",
		label = "VFS cache pressure",
		desc = "How aggressively the kernel reclaims cached directory/inode data.",
		default = 100,
		kind = "slider",
		min = 0,
		max = 200, -- kernel allows >100; cap modestly
	},
	{
		key = "vm.dirty_ratio",
		label = "Dirty ratio",
		desc = "Max % of memory holding un-written data before writes block.",
		default = 20,
		kind = "slider",
		min = 1,
		max = 90,
	},
	{
		key = "vm.dirty_background_ratio",
		label = "Dirty background ratio",
		desc = "% of memory dirty before the kernel starts flushing in background.",
		default = 10,
		kind = "slider",
		min = 1,
		max = 90,
	},
	{
		key = "fs.inotify.max_user_watches",
		label = "inotify watches",
		desc = "Max files a user can watch (raise if editors/sync tools complain).",
		default = 65536,
		kind = "preset",
		presets = { 8192, 65536, 262144, 524288, 1048576 },
	},
}

-- Look up a param descriptor by key.
function M.param(key)
	for _, p in ipairs(M.PARAMS) do
		if p.key == key then
			return p
		end
	end
	return nil
end

-- ── reading ─────────────────────────────────────────────────────────────────

-- Current value of a sysctl (number), or nil. Unprivileged read.
function M.get(key)
	local out = shell("sysctl -n " .. key)
	if not out then
		return nil
	end
	out = trim(out)
	local n = tonumber(out)
	return n
end

-- Read all allowlisted params at once: returns { [key] = current_number }.
function M.get_all()
	local vals = {}
	for _, p in ipairs(M.PARAMS) do
		vals[p.key] = M.get(p.key)
	end
	return vals
end

-- ── validation ──────────────────────────────────────────────────────────────

-- Clamp/validate a proposed value against a param's safe bounds. Returns a
-- valid number, or nil if the value can't be made valid. This is the guard
-- that makes out-of-range values structurally impossible before we ever build
-- a command.
function M.validate(param, value)
	local n = tonumber(value)
	if not n then
		return nil
	end
	n = math.floor(n)
	if param.kind == "slider" then
		if n < param.min then
			n = param.min
		end
		if n > param.max then
			n = param.max
		end
		return n
	elseif param.kind == "preset" then
		-- must be exactly one of the presets
		for _, v in ipairs(param.presets) do
			if v == n then
				return n
			end
		end
		return nil
	end
	return nil
end

-- ── command builders (privileged; run via pkexec) ───────────────────────────

-- Apply a value live (sysctl -w). Reverts on reboot. Value must already be
-- validated by the caller. Returns the command string.
function M.cmd_apply(key, value)
	return string.format("sysctl -w %s=%d", key, value)
end

-- Reset a param to its kernel default, live. Returns the command string.
function M.cmd_reset(param)
	return string.format("sysctl -w %s=%d", param.key, param.default)
end

-- Persist ALL current allowlisted values to /etc/sysctl.d so they apply on
-- boot. This is the deliberate, separate "make permanent" action. We write a
-- single managed file, only containing our allowlisted keys at their current
-- live values (each already within safe bounds). Returns the command string.
-- Implemented as a here-doc through sh -c so it's one pkexec call.
function M.cmd_persist(values)
	local lines = { "# Managed by settings_menu — safe kernel tuning", "" }
	for _, p in ipairs(M.PARAMS) do
		local v = values[p.key]
		if type(v) == "number" then
			lines[#lines + 1] = string.format("%s = %d", p.key, v)
		end
	end
	local body = table.concat(lines, "\n") .. "\n"
	-- escape single quotes for the sh -c wrapper
	local esc = body:gsub("'", "'\\''")
	return 'sh -c \'cat > /etc/sysctl.d/99-tui.conf <<"EOF"\n' .. esc .. "EOF\n'"
end

-- Remove the persisted file (revert to distro defaults on next boot).
function M.cmd_unpersist()
	return "rm -f /etc/sysctl.d/99-tui.conf"
end

-- Whether our persisted file currently exists.
function M.is_persisted()
	local out = shell("[ -f /etc/sysctl.d/99-tui.conf ] && echo yes")
	return out ~= nil and out:match("yes") ~= nil
end

return M
