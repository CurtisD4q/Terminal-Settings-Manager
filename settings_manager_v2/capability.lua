-- capability.lua — turns env.lua's raw detection into per-category support
-- verdicts, so a category that can't function on this system says WHY instead
-- of showing an empty or error-filled panel.
--
-- The problem this solves: env.lua already knows the distro, init system,
-- compositor, and audio server, but nothing consumed that knowledge — so when
-- a category's tool was absent (e.g. Services with no systemd), the user saw a
-- blank list indistinguishable from a bug. This module lets each category ask
-- "am I supported here, and if not, why?" and surface a clear reason.
--
-- Design:
--   * Depends only on env + util (both dependency-light). Bottom of the graph.
--   * Each category id maps to a check function returning either:
--       true                       -> supported, show normally
--       false, "human reason"      -> unsupported; show the reason
--   * A category with no entry here is assumed universally supported (true).
--   * Checks are cheap and cached by env; safe to call every prefetch.
local M = {}
local env = require("env")
local util = require("util")

local function have(bin)
	return util.have(bin)
end

-- Per-category capability checks. Keyed by the category id used in the
-- launchers (the "network"/"services"/... after the a1_/a2_ prefix). Each
-- returns (true) or (false, reason). Reasons are phrased for a person reading
-- the panel, and name the detected situation ("this system uses runit") rather
-- than a bare "tool missing", because the detected fact is the useful part.
local CHECKS = {
	-- Services is systemd-specific. Prefer the runtime marker (systemd actually
	-- booted), but also accept a working systemctl — on some setups the marker
	-- path isn't present yet systemctl functions. Only when neither holds do we
	-- declare it unsupported and name the detected init.
	services = function()
		if env.is_systemd() then
			return true
		end
		if have("systemctl") then
			-- confirm systemctl actually talks to a running systemd
			local out = util.shell_value("systemctl is-system-running")
			-- any non-empty answer (running/degraded/starting/…) means systemd
			-- is the init; only a total failure means it isn't usable
			if out ~= nil and out ~= "" and out ~= "offline" then
				return true
			end
		end
		local init = env.init_system()
		return false, "requires systemd (this system uses " .. init .. ")"
	end,

	-- Date & Time writes via timedatectl, part of systemd. Detection + tool.
	datetime = function()
		if have("timedatectl") then
			return true
		end
		return false, "requires timedatectl (systemd)"
	end,

	-- Network works with either NetworkManager (nmcli) or iwd (iwctl); the
	-- provider picks whichever is present. Only when neither exists is it
	-- unsupported.
	network = function()
		if have("nmcli") or have("iwctl") then
			return true
		end
		return false, "requires NetworkManager (nmcli) or iwd (iwctl)"
	end,

	-- Bluetooth needs BlueZ's bluetoothctl.
	bluetooth = function()
		if have("bluetoothctl") then
			return true
		end
		return false, "requires BlueZ (bluetoothctl)"
	end,

	-- Sound needs a PipeWire/Pulse control tool.
	sound = function()
		if have("wpctl") or have("pactl") then
			return true
		end
		return false, "requires PipeWire or PulseAudio (wpctl/pactl)"
	end,

	-- Display and Input are driven through Sway's IPC. On this project that is
	-- the constant, but check anyway so a non-Sway launch is honest.
	display = function()
		if env.is_sway() or have("swaymsg") then
			return true
		end
		return false, "requires Sway (swaymsg)"
	end,
	input = function()
		if env.is_sway() or have("swaymsg") then
			return true
		end
		return false, "requires Sway (swaymsg)"
	end,

	-- Package management relies on a recognised system package manager.
	packagemgmt = function()
		local pm = env.package_manager()
		if pm ~= "unknown" then
			return true
		end
		return false, "no supported package manager detected"
	end,

	-- Disk encryption needs cryptsetup.
	encryption = function()
		if have("cryptsetup") then
			return true
		end
		return false, "requires cryptsetup (LUKS)"
	end,
}

-- Is a category supported on this system? Returns (true) or (false, reason).
-- Unknown categories are treated as supported.
function M.check(category_id)
	local fn = CHECKS[category_id]
	if not fn then
		return true
	end
	local ok, supported, reason = pcall(fn)
	if not ok then
		-- a check that errors should never break the app; assume supported
		return true
	end
	if supported then
		return true
	end
	return false, reason or "unavailable on this system"
end

-- Convenience: just the reason string (or nil if supported).
function M.reason(category_id)
	local ok, reason = M.check(category_id)
	if ok then
		return nil
	end
	return reason
end

return M
