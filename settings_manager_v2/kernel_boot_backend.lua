-- kernel_boot_backend.lua — read-only kernel & boot introspection.
-- Everything here is unprivileged: uname, /proc, rpm, bootctl/grubby, lsmod,
-- and the BLS entry files under /boot/loader/entries. No root, no writes.
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

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local v = f:read("*a")
	f:close()
	return v
end

-- ── running kernel ──────────────────────────────────────────────────────────

function M.running_kernel()
	local out = shell("uname -r")
	return out and trim(out) or nil
end

-- The full uname -v build string (date + config), trimmed.
function M.kernel_build()
	local out = shell("uname -v")
	return out and trim(out) or nil
end

-- Architecture (x86_64, aarch64, ...).
function M.arch()
	local out = shell("uname -m")
	return out and trim(out) or nil
end

-- ── boot command line ───────────────────────────────────────────────────────

-- The raw kernel command line the running system booted with.
function M.cmdline()
	local out = read_file("/proc/cmdline")
	return out and trim(out) or nil
end

-- Parse cmdline into a list of parameters for display, hiding nothing but
-- splitting on spaces so long lines wrap sensibly.
function M.cmdline_params()
	local cl = M.cmdline()
	if not cl then
		return nil
	end
	local params = {}
	for p in cl:gmatch("%S+") do
		params[#params + 1] = p
	end
	return params
end

-- ── installed kernels ───────────────────────────────────────────────────────

-- All installed kernel versions. Prefers rpm (Fedora), falls back to listing
-- /lib/modules. Returns a sorted list of version strings, newest first.
function M.installed_kernels()
	local list = {}
	if have("rpm") then
		local out = shell("rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\\n'")
		if not out or out:match("is not installed") or out == "" then
			out = shell("rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\\n'")
		end
		if out then
			for line in out:gmatch("[^\n]+") do
				line = trim(line)
				if line ~= "" and not line:match("not installed") then
					list[#list + 1] = line
				end
			end
		end
	end
	if #list == 0 then
		-- fallback: /lib/modules directory names
		local out = shell("ls -1 /lib/modules")
		if out then
			for line in out:gmatch("[^\n]+") do
				line = trim(line)
				if line ~= "" then
					list[#list + 1] = line
				end
			end
		end
	end
	-- sort newest-first (string sort is close enough for kernel versions;
	-- reverse so higher versions come first)
	table.sort(list, function(a, b)
		return a > b
	end)
	return #list > 0 and list or nil
end

-- ── bootloader ──────────────────────────────────────────────────────────────

-- Detect which bootloader is in use: "systemd-boot", "grub", or nil.
function M.bootloader()
	-- systemd-boot: bootctl status reports a version line only when it's the
	-- installed loader. Match a positive signal, not merely the word appearing
	-- (the "not installed in ESP" message also contains "systemd-boot").
	if have("bootctl") then
		local out = shell("bootctl status")
		if out then
			-- positive markers: "Product: systemd-boot X" or "systemd-boot X (sd-boot)"
			if out:match("systemd%-boot%s+%d") or out:match("Current Boot Loader") then
				if not out:match("not installed") then
					return "systemd-boot"
				end
			end
		end
	end
	-- GRUB: presence of grub config
	if read_file("/etc/default/grub") or read_file("/boot/grub2/grub.cfg") then
		return "grub"
	end
	-- BLS entries without sd-boot still often means grub+BLS on Fedora
	local ents = shell("ls -1 /boot/loader/entries 2>/dev/null")
	if ents and ents:match("%.conf") then
		return "grub" -- Fedora default: grub reading BLS entries
	end
	return nil
end

-- Default boot entry / kernel. Uses grubby if present (works for both grub and
-- BLS on Fedora), else bootctl for systemd-boot.
function M.default_entry()
	if have("grubby") then
		local out = shell("grubby --default-title")
		if out and trim(out) ~= "" then
			return trim(out)
		end
		out = shell("grubby --default-kernel")
		if out and trim(out) ~= "" then
			return trim(out)
		end
	end
	if have("bootctl") then
		local out = shell("bootctl status")
		if out then
			local def = out:match("default:%s*([^\n]+)")
			if def then
				return trim(def)
			end
		end
	end
	return nil
end

-- Boot menu timeout in seconds, if discoverable. GRUB: /etc/default/grub
-- GRUB_TIMEOUT; systemd-boot: bootctl status "timeout".
function M.boot_timeout()
	local grub = read_file("/etc/default/grub")
	if grub then
		local t = grub:match("GRUB_TIMEOUT=(%d+)")
		if t then
			return tonumber(t)
		end
	end
	if have("bootctl") then
		local out = shell("bootctl status")
		if out then
			local t = out:match("timeout:%s*(%d+)")
			if t then
				return tonumber(t)
			end
		end
	end
	return nil
end

-- List boot entries. Prefers the BLS entry files (Fedora), then grubby, then
-- bootctl. Returns a list of { title, version } tables.
function M.boot_entries()
	local entries = {}
	-- BLS: one .conf per entry under /boot/loader/entries
	local names = shell("ls -1 /boot/loader/entries 2>/dev/null")
	if names and names:match("%.conf") then
		for fname in names:gmatch("[^\n]+") do
			if fname:match("%.conf$") then
				local body = read_file("/boot/loader/entries/" .. fname)
				if body then
					local title = body:match("title%s+([^\n]+)")
					local version = body:match("version%s+([^\n]+)")
					entries[#entries + 1] = {
						title = title and trim(title) or fname,
						version = version and trim(version) or nil,
					}
				end
			end
		end
	end
	-- fallback: grubby info
	if #entries == 0 and have("grubby") then
		local out = shell("grubby --info=ALL")
		if out then
			for title in out:gmatch('title="([^"]+)"') do
				entries[#entries + 1] = { title = trim(title) }
			end
		end
	end
	if #entries > 0 then
		-- newest first by version string
		table.sort(entries, function(a, b)
			return (a.version or a.title) > (b.version or b.title)
		end)
		return entries
	end
	return nil
end

-- ── kernel modules ──────────────────────────────────────────────────────────

-- Count of currently loaded modules (lsmod minus the header line).
function M.loaded_module_count()
	local out = shell("lsmod")
	if not out then
		return nil
	end
	local n = 0
	local first = true
	for _ in out:gmatch("[^\n]+") do
		if first then
			first = false
		else
			n = n + 1
		end
	end
	return n > 0 and n or nil
end

-- Blacklisted modules from /etc/modprobe.d/*.conf and /usr/lib/modprobe.d.
-- Returns a sorted list of module names, or nil.
function M.blacklisted_modules()
	local out = shell("cat /etc/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf 2>/dev/null")
	if not out then
		return nil
	end
	local seen, list = {}, {}
	for name in out:gmatch("blacklist%s+([%w%-_]+)") do
		if not seen[name] then
			seen[name] = true
			list[#list + 1] = name
		end
	end
	table.sort(list)
	return #list > 0 and list or nil
end

-- ── kernel security state ───────────────────────────────────────────────────

-- Kernel lockdown mode: none / integrity / confidentiality. The active mode is
-- shown in brackets in the sysfs file, e.g. "none [integrity] confidentiality".
function M.lockdown()
	local v = read_file("/sys/kernel/security/lockdown")
	if not v then
		return nil
	end
	local active = v:match("%[(%a+)%]")
	return active or trim(v)
end

-- Total boot time from systemd-analyze, if available (e.g. "18.2s").
function M.boot_time()
	if not have("systemd-analyze") then
		return nil
	end
	local out = shell("systemd-analyze")
	if out then
		-- "Startup finished in ... = 18.243s"
		local t = out:match("=%s*([%d%.]+s)%s*$") or out:match("=%s*([%d%.]+s)")
		if t then
			return t
		end
	end
	return nil
end

-- ── maintenance actions (privileged; run via pkexec from the category) ───────

-- Rebuild the initramfs for the currently running kernel. `dracut -f` forces
-- overwrite of the existing image. Needs root. Use after changing dracut
-- config, adding drivers, or if boot is failing to find root.
function M.cmd_rebuild_initramfs()
	return "dracut -f"
end

-- Rebuild initramfs for ALL installed kernels. Slower; use when a change should
-- apply to every kernel you might boot.
function M.cmd_rebuild_initramfs_all()
	return "dracut -f --regenerate-all"
end

return M
