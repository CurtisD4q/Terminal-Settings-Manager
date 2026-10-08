-- firewall.lua — encapsulated, swappable firewall control.
--
-- Different Sway systems ship different firewalls: Fedora defaults to firewalld,
-- Debian/Ubuntu commonly use ufw, and many minimal Arch setups use nftables
-- directly. This module hides that difference behind one interface so the
-- Privacy category can show and toggle "the firewall" without knowing which is
-- installed.
--
-- Public interface (the ONLY surface categories touch):
--   fw.available()      -> is any known firewall present
--   fw.enabled()        -> (true|false, nil) running state, or (nil, reason)
--   fw.detail()         -> a short human string (zone/policy), or nil
--   fw.set(on, pkexec)  -> enable/disable; returns (ok, err). `pkexec` is the
--                          core.run_pkexec function, injected so the DRIVER runs
--                          its own privileged command internally and only a
--                          result crosses back — no command string leaks out.
--   fw.name()           -> implementation name, for DISPLAY only (not branching)
--
-- Encapsulation: every driver below is `local`, fully owns its tool name and
-- command syntax, and exposes only the contract methods. Nothing outside this
-- file can see a driver, its commands, or which one was selected.
local M = {}
local util = require("util")
local provider = require("provider")

-- ── shared helpers (private) ─────────────────────────────────────────────────

local function have(bin)
	return util.have(bin)
end

-- ── driver: firewalld (firewall-cmd) ─────────────────────────────────────────
local firewalld = {}
function firewalld:available()
	return have("firewall-cmd")
end
function firewalld:name()
	return "firewalld"
end
function firewalld:enabled()
	local out = util.shell_value("firewall-cmd --state")
	if out == "running" then
		return true, nil
	end
	if out == "not running" then
		return false, nil
	end
	return nil, "state unknown"
end
function firewalld:detail()
	local zone = util.shell_value("firewall-cmd --get-default-zone")
	return zone and ("zone: " .. zone) or nil
end
function firewalld:set(on, pkexec)
	-- firewalld is a systemd service; enable/disable the unit.
	local cmd = ("systemctl %s --now firewalld"):format(on and "enable" or "disable")
	return pkexec(cmd, (on and "Enable" or "Disable") .. " the firewall (firewalld)")
end

-- ── driver: ufw ──────────────────────────────────────────────────────────────
local ufw = {}
function ufw:available()
	return have("ufw")
end
function ufw:name()
	return "ufw"
end
function ufw:enabled()
	-- `ufw status` prints "Status: active" or "Status: inactive".
	local out = util.shell_value("ufw status")
	if not out then
		return nil, "state unknown"
	end
	if out:find("Status: active", 1, true) then
		return true, nil
	end
	if out:find("Status: inactive", 1, true) then
		return false, nil
	end
	return nil, "state unknown"
end
function ufw:detail()
	local out = util.shell_value("ufw status verbose")
	if not out then
		return nil
	end
	-- surface the default policy line if present, e.g.
	--   Default: deny (incoming), allow (outgoing), disabled (routed)
	for line in out:gmatch("[^\n]+") do
		local pol = line:match("^Default:%s*(.+)$")
		if pol then
			return "default: " .. util.trim(pol)
		end
	end
	return nil
end
function ufw:set(on, pkexec)
	-- ufw uses its own verb; --force avoids the interactive y/n on enable.
	local cmd = on and "ufw --force enable" or "ufw disable"
	return pkexec(cmd, (on and "Enable" or "Disable") .. " the firewall (ufw)")
end

-- ── driver: nftables ─────────────────────────────────────────────────────────
-- nftables has no daemon-level "enabled" the way firewalld/ufw do; the closest
-- portable signal is whether the nftables systemd service is active and/or any
-- ruleset is loaded. Toggling maps to the nftables service where present.
local nftables = {}
function nftables:available()
	-- only claim nftables if nft exists AND neither higher-level manager does,
	-- so firewalld/ufw (which sit ON nftables) take precedence when installed.
	return have("nft") and not have("firewall-cmd") and not have("ufw")
end
function nftables:name()
	return "nftables"
end
function nftables:enabled()
	-- consider it "on" if a non-empty ruleset is loaded
	local out = util.shell_value("nft list ruleset")
	if out == nil or out == "" then
		return false, nil
	end
	-- a ruleset with at least one rule line
	if out:find("chain") then
		return true, nil
	end
	return false, nil
end
function nftables:detail()
	local out = util.shell_value("nft list tables")
	if not out then
		return nil
	end
	local n = 0
	for _ in out:gmatch("[^\n]+") do
		n = n + 1
	end
	return n > 0 and (n .. " table(s)") or nil
end
function nftables:set(on, pkexec)
	-- Map to the nftables service, the standard way distros persist rules.
	local cmd = ("systemctl %s --now nftables"):format(on and "enable" or "disable")
	return pkexec(cmd, (on and "Enable" or "Disable") .. " the firewall (nftables)")
end

-- ── sealed provider ──────────────────────────────────────────────────────────
-- Priority order: prefer the higher-level manager the user actually configured
-- (firewalld, then ufw), falling back to raw nftables. The proxy exposes only
-- the interface methods; the drivers above stay private to this module.
local proxy = provider.select({ firewalld, ufw, nftables }, { "enabled", "detail", "set", "name" })

M.available = proxy.available
M.enabled = proxy.enabled
M.detail = proxy.detail
M.set = proxy.set
M.name = proxy.name

return M
