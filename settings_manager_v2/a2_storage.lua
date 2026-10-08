#!/usr/bin/env lua5.4
-- Storage & Filesystems (App 2) — disk/partition inventory plus safe
-- mount/unmount/eject. Read-only except for the mount actions, which go
-- through udisksctl (userspace + polkit). Deliberately does NOT format,
-- partition, resize, edit fstab, or manage RAID/LVM.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local st = require("storage_backend")

local CAT -- forward-declared so prefetch can rebuild its sections
local cache_impl -- forward-declared so row-builder setters can mark it dirty

-- ── row builders ────────────────────────────────────────────────────────────

local function disk_rows(cache)
	local rows = {}
	if cache.disks_err then
		rows[#rows + 1] = { "Unavailable", cache.disks_err, "" }
		return rows
	end
	if not cache.disks or #cache.disks == 0 then
		rows[#rows + 1] = { "No disks found", "", "" }
		return rows
	end
	for _, d in ipairs(cache.disks) do
		local detail = d.size .. "  " .. d.medium
		if d.model then
			detail = d.model .. "  ·  " .. detail
		end
		rows[#rows + 1] = { d.name, detail, "" }
	end
	return rows
end

local function partition_rows(cache)
	local rows = {}
	if cache.parts_err then
		rows[#rows + 1] = { "Unavailable", cache.parts_err, "" }
		return rows
	end
	if not cache.parts or #cache.parts == 0 then
		rows[#rows + 1] = { "No partitions found", "", "" }
		return rows
	end
	for _, p in ipairs(cache.parts) do
		local bits = {}
		bits[#bits + 1] = p.size
		if p.fstype then
			bits[#bits + 1] = p.fstype
		end
		if p.mountpoint then
			bits[#bits + 1] = p.mountpoint
			if p.pct then
				bits[#bits + 1] = string.format("%.1f%% used", p.pct)
			end
		else
			bits[#bits + 1] = "not mounted"
		end
		local label = p.name
		if p.label then
			label = label .. "  (" .. p.label .. ")"
		end
		-- System mounts are read-only: never offer to unmount something the
		-- running system depends on. On btrfs, Fedora mounts subvolumes, so
		-- lsblk may report a subvolume path (or several) rather than plain "/".
		-- Treat any partition carrying a system path as protected.
		local protected = p.is_system
		if protected then
			rows[#rows + 1] = { label, table.concat(bits, "  ·  ") .. "  ·  [system]", "" }
		elseif not st.available() then
			rows[#rows + 1] = { label, table.concat(bits, "  ·  "), "" }
		else
			local pname = p.name
			local mounted = p.mountpoint ~= nil
			rows[#rows + 1] = {
				label,
				table.concat(bits, "  ·  "),
				"button",
				{
					get = function()
						return mounted and "unmount" or "mount"
					end,
					set = function()
						if mounted then
							st.unmount(pname)
						else
							st.mount(pname)
						end
						cache_impl:mark_all_dirty()
					end,
				},
			}
		end
	end
	return rows
end

local function removable_rows(cache)
	local rows = {}
	if cache.rm_err then
		rows[#rows + 1] = { "Unavailable", cache.rm_err, "" }
		return rows
	end
	if not cache.removable or #cache.removable == 0 then
		rows[#rows + 1] = { "No removable media", "", "" }
		return rows
	end
	for _, d in ipairs(cache.removable) do
		local detail = d.size .. "  " .. d.medium
		if d.model then
			detail = d.model .. "  ·  " .. detail
		end
		rows[#rows + 1] = { d.name, detail, "" }
		for _, p in ipairs(d.parts) do
			local bits = { p.size }
			if p.fstype then
				bits[#bits + 1] = p.fstype
			end
			if p.mountpoint then
				bits[#bits + 1] = p.mountpoint
				if p.pct then
					bits[#bits + 1] = string.format("%.1f%% used", p.pct)
				end
			else
				bits[#bits + 1] = "not mounted"
			end
			local plabel = "  " .. p.name
			if p.label then
				plabel = plabel .. "  (" .. p.label .. ")"
			end
			rows[#rows + 1] = { plabel, table.concat(bits, "  ·  "), "" }
		end
		if st.available() then
			local dname = d.name
			rows[#rows + 1] = {
				"  Safely eject " .. dname,
				"",
				"button",
				{
					get = function()
						return "eject"
					end,
					set = function()
						st.eject(dname)
					end,
				},
			}
		end
	end
	return rows
end

-- ── event-driven cache ──────────────────────────────────────────────────────
-- Disk/partition/removable data changes only when hardware is plugged, mounted,
-- or unmounted. `udevadm monitor` emits a line on every such kernel/udev event,
-- so we hold one open and re-fetch only the affected data when it fires —
-- instead of running lsblk + df on every single frame.

local EC = require("event_cache")

cache_impl = EC.new({
	fetchers = {
		disks = function()
			local d, e = st.disks()
			return { data = d, err = e }
		end,
		parts = function()
			local p, e = st.partitions()
			return { data = p, err = e }
		end,
		removable = function()
			local r, e = st.removable()
			return { data = r, err = e }
		end,
	},
	-- udevadm monitor: --subsystem-match=block limits to disk events; -u is
	-- userspace (udev) events, which fire after the device is actually ready.
	stream = "stdbuf -oL udevadm monitor -u -s block",
	-- any block event potentially changes all three views (a new disk brings
	-- new partitions and may be removable), so dirty everything on any line.
	classify = function(_line)
		return nil
	end,
})

-- Curated maintenance one-shots for storage. fstrim needs root (pkexec + a
-- confirmation); sync is unprivileged and runs directly. Nothing free-form.
local function maintenance_rows()
	return {
		{
			"TRIM all filesystems",
			"",
			"button",
			{
				get = function()
					return "run"
				end,
				set = function()
					local ok = core.run_confirm(
						"TRIM all mounted filesystems?",
						"Runs fstrim -av. Tells SSDs which blocks are free, keeping\nwrite performance healthy. Safe to run periodically."
					)
					if ok then
						core.run_pkexec(st.cmd_fstrim_all(), "TRIM all mounted filesystems")
						cache_impl:mark_all_dirty()
					end
				end,
			},
		},
		{
			"Sync disks",
			"",
			"button",
			{
				get = function()
					return "run"
				end,
				set = function()
					-- unprivileged; flushes buffered writes to disk immediately
					st.sync_disks()
				end,
			},
		},
	}
end

local function prefetch(cache)
	cache_impl:start()
	local d = cache_impl:get("disks") or {}
	local p = cache_impl:get("parts") or {}
	local r = cache_impl:get("removable") or {}
	cache.disks, cache.disks_err = d.data, d.err
	cache.parts, cache.parts_err = p.data, p.err
	cache.removable, cache.rm_err = r.data, r.err
	CAT.sections[1][2] = disk_rows(cache)
	CAT.sections[2][2] = partition_rows(cache)
	CAT.sections[3][2] = removable_rows(cache)
	CAT.sections[4][2] = maintenance_rows()
end

CAT = {
	id = "storage",
	label = "Storage & Filesystems",
	icon = "▤",
	sections = {
		{ "Disks", { { "Loading…", "", "" } } },
		{ "Partitions", { { "Loading…", "", "" } } },
		{ "Removable Media", { { "Loading…", "", "" } } },
		{ "Maintenance", { { "Loading…", "", "" } } },
	},
	prefetch = prefetch,
	-- idle-tick hook: drain the udev stream; redraw if a hotplug/mount event
	-- arrived (the affected slices were marked dirty, so prefetch refetches).
	poll_events = function()
		return cache_impl:poll()
	end,
}

return core.define_category(CAT, {
	on_exit = function()
		cache_impl:stop()
	end,
})
