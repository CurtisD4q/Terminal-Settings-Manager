-- privacy_backend.lua — the genuinely-doable parts of Privacy & Security:
--   Firewall        : live status + enable/disable (firewalld via systemctl;
--                     toggling needs root -> the UI routes it through pkexec)
--   Secure Boot     : read-only status (mokutil / bootctl)
--   Disk encryption : read-only status (lsblk shows LUKS)
--   Log purge       : an action (journalctl --vacuum), root -> pkexec in UI
-- No config-file or hidden-file editing anywhere. Rows that would require
-- editing PAM, portals, or swayidle config were removed from the category.
local M = {}
local util = require("util")
local firewall = require("firewall")

local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local function have(bin)
	return util.have(bin)
end

local trim = util.trim

-- default zone + active zones, for a read-only detail line
-- Firewall control is delegated to the swappable firewall provider, which
-- picks firewalld / ufw / nftables depending on what's installed. These
-- wrappers keep the backend's existing function names so the category is
-- unchanged, but the actual implementation is now portable across Sway systems
-- rather than firewalld-only. The provider returns (nil, reason) when no known
-- firewall is present, which the toggle row shows in place of a state.
function M.firewall_enabled()
	return firewall.enabled()
end

function M.firewall_detail()
	return firewall.detail()
end

-- ── secure boot (read-only) ─────────────────────────────────────────────────
function M.secure_boot()
	if have("mokutil") then
		local out = shell("mokutil --sb-state")
		if out then
			if out:match("enabled") then
				return "enabled"
			end
			if out:match("disabled") then
				return "disabled"
			end
		end
	end
	-- fallback: bootctl status mentions "Secure Boot: enabled/disabled"
	if have("bootctl") then
		local out = shell("bootctl status")
		if out then
			local s = out:match("Secure Boot:%s*(%a+)")
			if s then
				return s:lower()
			end
		end
	end
	-- last resort: efivars
	local out = shell("od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null")
	if out and out:match("%d") then
		local last = nil
		for n in out:gmatch("%d+") do
			last = n
		end
		if last == "1" then
			return "enabled"
		elseif last == "0" then
			return "disabled"
		end
	end
	return "unknown (no UEFI?)"
end

-- ── disk encryption (read-only) ─────────────────────────────────────────────
-- Reports whether any mounted filesystem sits on a LUKS/crypt device.
function M.disk_encryption()
	if not have("lsblk") then
		return "unknown"
	end
	-- TYPE column: "crypt" rows indicate an unlocked LUKS mapping in use
	local out = shell("lsblk -o TYPE,MOUNTPOINT -rn")
	if not out then
		return "unknown"
	end
	local crypt_mounts = {}
	for line in out:gmatch("[^\n]+") do
		local typ, mnt = line:match("^(%S+)%s*(.*)$")
		if typ == "crypt" and mnt and mnt ~= "" then
			crypt_mounts[#crypt_mounts + 1] = mnt
		end
	end
	-- also check if there are any LUKS containers at all
	local has_luks = false
	local ft = shell("lsblk -o FSTYPE -rn")
	if ft and ft:match("crypto_LUKS") then
		has_luks = true
	end

	if #crypt_mounts > 0 then
		-- is root among them?
		for _, m in ipairs(crypt_mounts) do
			if m == "/" then
				return "yes — root filesystem encrypted (LUKS)"
			end
		end
		return "partial — encrypted: " .. table.concat(crypt_mounts, ", ")
	end
	if has_luks then
		return "LUKS present, none mounted here"
	end
	return "no — no encrypted volumes detected"
end

-- ── command builders for pkexec actions (run by the UI) ─────────────────────
-- (returned as strings so the category can pass them to core.run_pkexec)
-- Enable/disable the firewall through the provider. The chosen driver runs its
-- own privileged command internally (via the injected pkexec), so no command
-- string crosses back here — we only surface (ok, err). Replaces the old
-- cmd_firewall_set, which leaked a firewalld-specific systemctl string.
function M.firewall_set(on, pkexec)
	return firewall.set(on, pkexec)
end

function M.cmd_log_vacuum(days)
	days = days or 7
	return ("journalctl --vacuum-time=%dd"):format(days)
end

M.have = have
return M
