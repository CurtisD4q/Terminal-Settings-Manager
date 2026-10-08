-- encryption_backend.lua — LUKS disk-encryption status and management.
-- Modern LUKS2 focus (no legacy hardware). Reads volume status, cipher, key
-- slots, and TPM enrollment (read-only). Actions (lock/unlock, keyslot add/
-- change/remove) are built as command strings and run by the category via
-- core.run_pkexec; passphrase-bearing commands hand off to cryptsetup's own
-- secure interactive prompts rather than passing secrets through the shell.
--
-- Hard safety rules enforced here and in the category:
--   * never remove the last remaining keyslot (permanent data loss)
--   * never lock/close the mounted system/root volume
local M = {}
local util = require("util")

local function shell(cmd)
	return (util.shell(cmd))
end

local trim = util.trim

local function have(bin)
	return util.have(bin)
end
M.have = have
M.available = function()
	return have("cryptsetup")
end

-- JSON decoding lives in util (shared, audited).

-- System mount paths that mark a volume as the protected system/root volume.
local SYSTEM_PATHS = { ["/"] = true, ["/boot"] = true, ["/boot/efi"] = true, ["[SWAP]"] = true }

-- ── detection ────────────────────────────────────────────────────────────────

-- Discover all LUKS-encrypted volumes. Walks lsblk's tree: a device with
-- FSTYPE "crypto_LUKS" is an encrypted container; if it has a child of TYPE
-- "crypt", the container is currently OPEN and the child is the mapped device.
-- Returns a list of:
--   { device      = "nvme0n1p3",         -- backing device (the container)
--     dev_path    = "/dev/nvme0n1p3",
--     open        = true/false,
--     mapping     = "luks-xxxx" or nil,  -- /dev/mapper name if open
--     mountpoint  = "/home" or nil,
--     fstype      = "btrfs" or nil,       -- fs inside, if open
--     is_system   = true/false }
function M.volumes()
	if not M.available() then
		return nil, "cryptsetup not found"
	end
	local out = shell("lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINT")
	if not out then
		return nil, "lsblk failed"
	end
	local ok, data = pcall(util.json_decode, out)
	if not ok or type(data) ~= "table" or not data.blockdevices then
		return nil, "parse error"
	end

	local vols = {}
	local function walk(node)
		if type(node) ~= "table" then
			return
		end
		if node.fstype == "crypto_LUKS" then
			local v = {
				device = node.name,
				dev_path = "/dev/" .. node.name,
				open = false,
			}
			-- an open LUKS container has a child of type "crypt"
			for _, child in ipairs(node.children or {}) do
				if child.type == "crypt" then
					v.open = true
					v.mapping = child.name
					v.mountpoint = child.mountpoint
					v.fstype = child.fstype
					-- system if this mapping (or any of its children) holds a
					-- system path
					if child.mountpoint and SYSTEM_PATHS[child.mountpoint] then
						v.is_system = true
					end
					for _, gc in ipairs(child.children or {}) do
						if gc.mountpoint and SYSTEM_PATHS[gc.mountpoint] then
							v.is_system = true
						end
					end
				end
			end
			vols[#vols + 1] = v
		end
		for _, child in ipairs(node.children or {}) do
			walk(child)
		end
	end
	for _, top in ipairs(data.blockdevices) do
		walk(top)
	end
	return vols, nil
end

-- ── per-volume detail (luksDump / status) ────────────────────────────────────

-- Parse `cryptsetup luksDump <dev>` for the sensitive-but-useful metadata.
-- luksDump needs root, so this is run through pkexec by the category and the
-- raw text passed back in; but we also try an unprivileged read first (some
-- systems permit it). Returns a table:
--   { version, cipher, keysize, hash, slots_used, slots_total, tpm }
function M.parse_luksdump(text)
	if not text then
		return nil
	end
	local info = {}
	-- LUKS version: "Version: 2" (LUKS2) or header "LUKS1"
	info.version = text:match("Version:%s*(%d)") or (text:match("LUKS1") and "1")
	-- cipher: LUKS2 "cipher: aes-xts-plain64"; LUKS1 "Cipher name: aes" + mode
	info.cipher = text:match("[Cc]ipher:%s*([%w%-]+)")
	if not info.cipher then
		local name = text:match("Cipher name:%s*(%S+)")
		local mode = text:match("Cipher mode:%s*(%S+)")
		if name then
			info.cipher = name .. (mode and ("-" .. mode) or "")
		end
	end
	-- key size (bits)
	info.keysize = text:match("Cipher key:%s*(%d+)%s*bits")
		or text:match("MK bits:%s*(%d+)")
		or text:match("Key:%s*(%d+)%s*bits") -- LUKS2 keyslot "Key: 512 bits"
	-- hash
	info.hash = text:match("Hash spec:%s*(%S+)") or text:match("Hash:%s*(%S+)")
	-- keyslots: count enabled. LUKS2 lists "  N: luks2"; LUKS1 "Key Slot N: ENABLED"
	local used = 0
	for _ in text:gmatch("Key Slot %d+: ENABLED") do
		used = used + 1
	end
	if used == 0 then
		-- LUKS2 style: under "Keyslots:" section, lines like "  0: luks2"
		for _ in text:gmatch("\n%s+%d+:%s*luks2") do
			used = used + 1
		end
	end
	info.slots_used = used > 0 and used or nil
	info.slots_total = (info.version == "2") and 32 or 8
	-- TPM: a systemd-tpm2 token means TPM auto-unlock is enrolled
	info.tpm = text:match("systemd%-tpm2") ~= nil
	return info
end

-- Build the (privileged) command that dumps a volume's LUKS header. The
-- category runs this via pkexec and feeds the output to parse_luksdump.
function M.cmd_luksdump(dev_path)
	return "cryptsetup luksDump " .. util.shquote(dev_path)
end

-- Unprivileged best-effort dump (works on some configs). Returns text or nil.
function M.try_luksdump(dev_path)
	return shell("cryptsetup luksDump " .. util.shquote(dev_path))
end

-- ── action command builders ─────────────────────────────────────────────────
-- All run via pkexec. The passphrase-bearing ones (open, addKey, changeKey,
-- removeKey) rely on cryptsetup prompting interactively on the terminal — we
-- never put a passphrase on a command line or pipe.

local function q(s)
	return util.shquote(s)
end

-- Unlock (open) a locked container. cryptsetup prompts for the passphrase.
-- mapping name defaults to luks-<device>.
function M.cmd_open(dev_path, mapping)
	return string.format("cryptsetup open %s %s", q(dev_path), q(mapping))
end

-- Lock (close) an open mapping. Only valid when unmounted and non-system.
function M.cmd_close(mapping)
	return "cryptsetup close " .. q(mapping)
end

-- Keyslot management — cryptsetup prompts for the necessary passphrases.
function M.cmd_add_key(dev_path)
	return "cryptsetup luksAddKey " .. q(dev_path)
end
function M.cmd_change_key(dev_path)
	return "cryptsetup luksChangeKey " .. q(dev_path)
end
function M.cmd_remove_key(dev_path)
	return "cryptsetup luksRemoveKey " .. q(dev_path)
end

-- Guard: is it safe to remove a keyslot? Never below 1 remaining. Given the
-- current used-count, removing is only allowed if used > 1.
function M.can_remove_key(slots_used)
	return type(slots_used) == "number" and slots_used > 1
end

return M
