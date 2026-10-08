-- storage_backend.lua — read-only disk/partition inventory plus safe
-- mount/unmount/eject actions. Deliberately scoped: no formatting, no
-- partitioning, no fstab editing, no RAID/LVM management.
--   Disks/partitions : lsblk -J (JSON)
--   Usage            : df
--   Mount actions    : udisksctl (userspace, polkit-mediated)
local M = {}
local util = require("util")

-- Local shims onto util, preserving this module's (out, ok) call convention.
-- All actual execution/quoting now goes through the audited util primitives;
-- these just adapt the return shape the existing call sites expect.
local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end
local have = util.have

-- ── tiny JSON decoder (same one used by display_backend) ────────────────────
-- JSON decoding lives in util (shared, audited).

local function have_lsblk()
	return have("lsblk")
end
local function have_udisks()
	return have("udisksctl")
end

-- ── raw device tree ─────────────────────────────────────────────────────────
-- Returns the decoded `lsblk -J` blockdevices array, or nil, err.
-- Cached per call-site; callers that need fresh data call this again.
local function lsblk_tree()
	if not have_lsblk() then
		return nil, "lsblk not found"
	end
	local out, ok = shell("lsblk -J -b -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL,RM,ROTA,TRAN,LABEL")
	if not ok or not out or not out:match("%S") then
		return nil, "lsblk failed"
	end
	local okd, data = pcall(util.json_decode, out)
	if not okd or type(data) ~= "table" or type(data.blockdevices) ~= "table" then
		return nil, "parse error"
	end
	return data.blockdevices, nil
end

-- Human-readable size from a byte count. Uses decimal (SI) units — MB, GB —
-- to match what lsblk, df, and disk manufacturers report, rather than binary
-- MiB/GiB. A 629145600-byte partition reads as "629.1 MB", not "600 MB".
local function human(bytes)
	local n = tonumber(bytes)
	if not n or n <= 0 then
		return "—"
	end
	local units = { "B", "KB", "MB", "GB", "TB", "PB" }
	local i = 1
	while n >= 1000 and i < #units do
		n = n / 1000
		i = i + 1
	end
	if i == 1 then
		return string.format("%d %s", math.floor(n + 0.5), units[i])
	end
	return string.format("%.1f %s", n, units[i])
end
M.human = human

-- Describe the medium: NVMe / SSD / HDD / USB / removable.
local function medium_of(dev)
	local tran = dev.tran
	if tran == "usb" then
		return "USB"
	end
	if tran == "nvme" then
		return "NVMe"
	end
	-- rota=false means non-rotational, i.e. solid state
	if dev.rota == false then
		return "SSD"
	end
	if dev.rota == true then
		return "HDD"
	end
	return "disk"
end

-- ── Section 1: physical disks (read-only) ───────────────────────────────────
-- Returns list of { name, model, size, medium, removable }
function M.disks()
	local tree, err = lsblk_tree()
	if not tree then
		return nil, err
	end
	local out = {}
	for _, d in ipairs(tree) do
		if d.type == "disk" then
			local model = d.model
			if type(model) == "string" then
				model = model:gsub("^%s+", ""):gsub("%s+$", "")
				if model == "" then
					model = nil
				end
			else
				model = nil
			end
			out[#out + 1] = {
				name = d.name,
				model = model,
				size = human(d.size),
				medium = medium_of(d),
				removable = (d.rm == true),
			}
		end
	end
	return out, nil
end

-- ── df usage, keyed by mountpoint ───────────────────────────────────────────
-- Returns { [mountpoint] = { size, used, avail, pct } } with human strings.
local function df_map()
	local out = shell("df -B1 --output=target,size,used,avail,pcent")
	local map = {}
	if not out then
		return map
	end
	local first = true
	for line in out:gmatch("[^\n]+") do
		if first then
			first = false
		else
			-- target may contain spaces; size/used/avail/pcent are the last 4
			-- fields. df's own Use% is rounded to a whole number, so compute
			-- the percentage from the raw byte counts instead to get a decimal.
			local target, size, used, avail = line:match("^(.-)%s+(%d+)%s+(%d+)%s+(%d+)%s+%d+%%%s*$")
			if target then
				local sz, us = tonumber(size), tonumber(used)
				local pct = nil
				if sz and us and sz > 0 then
					pct = us / sz * 100
				end
				map[target] = {
					size = human(size),
					used = human(used),
					avail = human(avail),
					pct = pct,
				}
			end
		end
	end
	return map
end

-- Mountpoints actually in use, keyed by device name. lsblk's "mountpoint"
-- field reports only ONE mount per device, which is wrong for btrfs: Fedora
-- mounts several subvolumes (/, /home, /var, ...) from the same partition.
-- /proc/self/mounts has them all, so use that as the authority.
local function mounts_by_device()
	local map = {}
	local f = io.open("/proc/self/mounts", "r")
	if not f then
		return map
	end
	for line in f:lines() do
		local dev, mp = line:match("^(%S+)%s+(%S+)")
		if dev and mp and dev:match("^/dev/") then
			-- unescape octal sequences (\040 = space) used in /proc/self/mounts
			mp = mp:gsub("\\(%d%d%d)", function(o)
				return string.char(tonumber(o, 8))
			end)
			local name = dev:match("([^/]+)$")
			if name then
				map[name] = map[name] or {}
				map[name][#map[name] + 1] = mp
			end
		end
	end
	f:close()
	return map
end

-- Is this mountpoint one the running system depends on?
local function is_system_mount(mp)
	return mp == "/"
		or mp == "/boot"
		or mp == "/boot/efi"
		or mp == "/usr"
		or mp == "/var"
		or mp == "/etc"
		or mp == "/home"
end

-- ── Section 2: partitions (read-only) ───────────────────────────────────────
-- Walks each disk's children. Returns list of:
--   { name, parent, size, fstype, label, mountpoint, mountpoints, is_system,
--     pct, used, avail, removable }
-- mountpoint is the primary mount ("/" wins if present); mountpoints lists
-- every mount for that device. mountpoint is nil when not mounted.
function M.partitions()
	local tree, err = lsblk_tree()
	if not tree then
		return nil, err
	end
	local usage = df_map()
	local mounts = mounts_by_device()
	local out = {}
	local function walk(dev, parent, removable)
		local kids = dev.children
		if type(kids) == "table" then
			for _, c in ipairs(kids) do
				walk(c, parent or dev.name, removable or (dev.rm == true))
			end
		end
		-- partitions and lvm/crypt mappings are both interesting; disks are not
		if dev.type == "part" or dev.type == "lvm" or dev.type == "crypt" then
			-- gather every mountpoint for this device
			local mps = mounts[dev.name] or {}
			if #mps == 0 and type(dev.mountpoint) == "string" and dev.mountpoint ~= "" then
				mps = { dev.mountpoint }
			end
			-- primary mount: prefer "/", else the shortest path (closest to root)
			local primary = nil
			for _, mp in ipairs(mps) do
				if mp == "/" then
					primary = "/"
					break
				end
				if not primary or #mp < #primary then
					primary = mp
				end
			end
			-- system if ANY of its mounts is a system path
			local system = false
			for _, mp in ipairs(mps) do
				if is_system_mount(mp) then
					system = true
					break
				end
			end
			-- usage: try each mountpoint until df has an entry. On btrfs every
			-- subvolume reports the same pool figures, so any match is correct.
			local u = nil
			for _, mp in ipairs(mps) do
				if usage[mp] then
					u = usage[mp]
					break
				end
			end
			local label = dev.label
			if type(label) ~= "string" or label == "" then
				label = nil
			end
			out[#out + 1] = {
				name = dev.name,
				parent = parent,
				size = human(dev.size),
				fstype = dev.fstype,
				label = label,
				mountpoint = primary,
				mountpoints = mps,
				is_system = system,
				pct = u and u.pct or nil,
				used = u and u.used or nil,
				avail = u and u.avail or nil,
				removable = removable == true or dev.rm == true,
			}
		end
	end
	for _, d in ipairs(tree) do
		walk(d, nil, d.rm == true)
	end
	return out, nil
end

-- ── Section 3: removable media (read-only) ──────────────────────────────────
-- Returns list of { name, model, size, medium, parts = { partition, ... } }
function M.removable()
	local tree, err = lsblk_tree()
	if not tree then
		return nil, err
	end
	local usage = df_map()
	local out = {}
	for _, d in ipairs(tree) do
		if d.type == "disk" and (d.rm == true or d.tran == "usb") then
			local parts = {}
			for _, c in ipairs(d.children or {}) do
				local mp = c.mountpoint
				if mp == "" then
					mp = nil
				end
				local u = mp and usage[mp] or nil
				parts[#parts + 1] = {
					name = c.name,
					size = human(c.size),
					fstype = c.fstype,
					label = (type(c.label) == "string" and c.label ~= "") and c.label or nil,
					mountpoint = mp,
					pct = u and u.pct or nil,
				}
			end
			local model = d.model
			if type(model) == "string" then
				model = model:gsub("^%s+", ""):gsub("%s+$", "")
				if model == "" then
					model = nil
				end
			else
				model = nil
			end
			out[#out + 1] = {
				name = d.name,
				model = model,
				size = human(d.size),
				medium = medium_of(d),
				parts = parts,
			}
		end
	end
	return out, nil
end

-- ── Section 4: actions ──────────────────────────────────────────────────────
-- All actions go through udisksctl, which is userspace and polkit-mediated:
-- no pkexec wrapper needed, and it refuses anything the user isn't allowed
-- to do. Nothing here formats, partitions, or writes a filesystem.

M.available = have_udisks

-- Mount an unmounted partition. Returns ok, err.
function M.mount(part_name)
	if not have_udisks() then
		return false, "udisksctl not found"
	end
	local out, ok = shell(("udisksctl mount -b /dev/%s"):format(part_name))
	if ok then
		return true, nil
	end
	local msg = out and out:match("[^\n]+") or "mount failed"
	return false, msg
end

-- Unmount a mounted partition. Returns ok, err.
function M.unmount(part_name)
	if not have_udisks() then
		return false, "udisksctl not found"
	end
	local out, ok = shell(("udisksctl unmount -b /dev/%s"):format(part_name))
	if ok then
		return true, nil
	end
	local msg = out and out:match("[^\n]+") or "unmount failed"
	return false, msg
end

-- Safely eject a removable disk: unmount every mounted partition on it,
-- then power it down so it is safe to unplug. Returns ok, err.
function M.eject(disk_name)
	if not have_udisks() then
		return false, "udisksctl not found"
	end
	local tree = lsblk_tree()
	if tree then
		for _, d in ipairs(tree) do
			if d.name == disk_name then
				for _, c in ipairs(d.children or {}) do
					if c.mountpoint and c.mountpoint ~= "" then
						shell(("udisksctl unmount -b /dev/%s"):format(c.name))
					end
				end
			end
		end
	end
	local out, ok = shell(("udisksctl power-off -b /dev/%s"):format(disk_name))
	if ok then
		return true, nil
	end
	local msg = out and out:match("[^\n]+") or "eject failed"
	return false, msg
end

-- ── maintenance actions ─────────────────────────────────────────────────────

-- TRIM all mounted filesystems. `fstrim -av` needs root, so the category runs
-- this via pkexec. Returns the command string for the caller to run.
function M.cmd_fstrim_all()
	return "fstrim -av"
end

-- Flush filesystem buffers to disk. `sync` is unprivileged, so we can run it
-- directly here. Returns ok (always true once sync returns).
function M.sync_disks()
	shell("sync")
	return true, nil
end

return M
