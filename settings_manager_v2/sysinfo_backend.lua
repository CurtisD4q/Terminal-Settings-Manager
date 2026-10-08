-- sysinfo_backend.lua — read-only system information.
-- All sources are unprivileged: /etc/os-release, /proc, and standard tools.
-- Nothing here modifies anything, so there's no root concern.
local M = {}
local util = require("util")

local function shell(cmd)
	return (util.shell(cmd))
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local s = f:read("*a")
	f:close()
	return s
end

-- os-release key lookup (Fedora etc.)
local function os_release(key)
	local s = read_file("/etc/os-release") or ""
	local v = s:match(key .. '="([^"]*)"') or s:match(key .. "=([^\n]*)")
	return v
end

function M.os_name()
	return os_release("PRETTY_NAME") or os_release("NAME") or "Unknown"
end

function M.kernel()
	local u = shell("uname -r")
	return u and u:gsub("%s+$", "") or "?"
end

function M.hostname()
	local h = shell("hostname") or read_file("/etc/hostname")
	return h and h:gsub("%s+$", "") or "?"
end

function M.cpu_model()
	local s = read_file("/proc/cpuinfo") or ""
	local model = s:match("model name%s*:%s*([^\n]+)")
	return model or "?"
end

function M.cpu_topology()
	-- cores/threads: count "processor" entries (threads) and physical id/cores
	local s = read_file("/proc/cpuinfo") or ""
	local threads = 0
	for _ in s:gmatch("processor%s*:") do
		threads = threads + 1
	end
	local cores = s:match("cpu cores%s*:%s*(%d+)")
	cores = cores and tonumber(cores) or nil
	if cores and threads then
		return string.format("%d cores / %d threads", cores, threads)
	elseif threads > 0 then
		return string.format("%d threads", threads)
	end
	return "?"
end

function M.mem_total()
	local s = read_file("/proc/meminfo") or ""
	local kb = s:match("MemTotal:%s*(%d+)")
	if not kb then
		return "?"
	end
	local gb = tonumber(kb) / 1024 / 1024
	return string.format("%.1f GB", gb)
end

function M.mem_used()
	local s = read_file("/proc/meminfo") or ""
	local total = tonumber(s:match("MemTotal:%s*(%d+)"))
	local avail = tonumber(s:match("MemAvailable:%s*(%d+)"))
	if not total or not avail then
		return "?"
	end
	local used_gb = (total - avail) / 1024 / 1024
	local total_gb = total / 1024 / 1024
	return string.format("%.1f / %.1f GB", used_gb, total_gb)
end

function M.uptime()
	local s = read_file("/proc/uptime") or ""
	local secs = tonumber(s:match("^(%d+)"))
	if not secs then
		return "?"
	end
	local d = math.floor(secs / 86400)
	local h = math.floor((secs % 86400) / 3600)
	local m = math.floor((secs % 3600) / 60)
	if d > 0 then
		return string.format("%dd %dh %dm", d, h, m)
	end
	if h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", m)
end

-- GPU: best-effort. lspci is common but may need the pciutils package.
function M.gpu()
	local out = shell("lspci")
	if out then
		-- look for VGA / 3D / Display controller lines
		local gpu = out:match("VGA compatible controller:%s*([^\n]+)")
			or out:match("3D controller:%s*([^\n]+)")
			or out:match("Display controller:%s*([^\n]+)")
		if gpu then
			return (gpu:gsub("%s*%(rev.-%)$", ""))
		end
	end
	return "unknown (install pciutils)"
end

-- Desktop/compositor from the environment
function M.desktop()
	local xdg = os.getenv("XDG_CURRENT_DESKTOP")
	local session = os.getenv("XDG_SESSION_DESKTOP")
	local wayland = os.getenv("WAYLAND_DISPLAY")
	local d = xdg or session
	if d then
		return d .. (wayland and " (Wayland)" or "")
	end
	if wayland then
		return "Wayland session"
	end
	return "?"
end

-- Hardware model of the machine (fastfetch's "Host") from DMI.
-- Combines vendor + product name + version where available, e.g.
-- "Dell Inc. XPS 15 9520" or "ASUS ROG Strix G15".
function M.host_model()
	local base = "/sys/devices/virtual/dmi/id/"
	local vendor = read_file(base .. "sys_vendor")
	local product = read_file(base .. "product_name")
	local version = read_file(base .. "product_version")
	local function clean(s)
		if not s then
			return nil
		end
		s = s:gsub("%s+$", "")
		-- filter out useless placeholder strings some firmwares report
		if
			s == ""
			or s:match("^To Be Filled")
			or s == "System Product Name"
			or s == "Default string"
			or s == "None"
		then
			return nil
		end
		return s
	end
	vendor, product, version = clean(vendor), clean(product), clean(version)
	local parts = {}
	if vendor then
		parts[#parts + 1] = vendor
	end
	if product then
		parts[#parts + 1] = product
	end
	-- version is often a useful suffix on laptops (e.g. "1.0"), but skip if it
	-- duplicates the product or looks like noise
	if version and product and not product:find(version, 1, true) and #version <= 12 then
		parts[#parts + 1] = version
	end
	if #parts == 0 then
		-- fall back to board name if DMI product is empty
		local board = clean(read_file(base .. "board_name"))
		if board then
			return board
		end
		return "unknown"
	end
	return table.concat(parts, " ")
end

-- Login shell (from $SHELL, then getent passwd).
function M.shell()
	local sh = os.getenv("SHELL")
	if sh and sh ~= "" then
		return (sh:gsub(".*/", "")) .. " (" .. sh .. ")"
	end
	local user = shell("id -un")
	if user then
		user = user:gsub("%s+$", "")
		local line = shell("getent passwd " .. user)
		if line then
			local s = line:match("[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:\n]+)")
			if s then
				s = s:gsub("%s+$", "")
				return (s:gsub(".*/", "")) .. " (" .. s .. ")"
			end
		end
	end
	return "unknown"
end

-- Terminal emulator. $TERM gives the terminfo type; for the actual emulator
-- we walk up the parent-process chain looking for a known terminal, which is
-- how tools like fastfetch/neofetch detect it. Falls back to $TERM.
function M.terminal()
	local terminals = {
		foot = 1,
		["foot-server"] = 1,
		kitty = 1,
		alacritty = 1,
		wezterm = 1,
		["wezterm-gui"] = 1,
		gnome = 1,
		["gnome-terminal"] = 1,
		["gnome-terminal-"] = 1,
		konsole = 1,
		xterm = 1,
		urxvt = 1,
		st = 1,
		tmux = 1,
		screen = 1,
		terminator = 1,
		["xfce4-terminal"] = 1,
		tilix = 1,
		["kgx"] = 1,
		ghostty = 1,
	}
	local pid = tostring(shell("echo $PPID") or ""):gsub("%s+", "")
	local guard = 0
	while pid and pid ~= "" and pid ~= "1" and guard < 12 do
		guard = guard + 1
		local stat = read_file("/proc/" .. pid .. "/stat")
		if not stat then
			break
		end
		-- comm is inside parens; may itself contain spaces/parens, so grab between
		-- first "(" and last ")"
		local comm = stat:match("%((.*)%)")
		local ppid = stat:match("%)%s+%S+%s+(%d+)")
		if comm then
			local base = comm:gsub("^gnome%-terminal%-.*", "gnome-terminal")
			if terminals[comm] or terminals[base] then
				return comm
			end
		end
		pid = ppid
	end
	local t = os.getenv("TERM")
	return t and t ~= "" and t or "unknown"
end

-- Root filesystem usage: "42 GB / 234 GB (18%)" via df.
function M.disk_used()
	-- df -P for portable columns: Filesystem Size Used Avail Use% Mounted
	local out = shell("df -P -B1 /")
	if not out then
		return "unknown"
	end
	-- second line is the data
	local _, size, used = out:match("\n%S+%s+(%d+)%s+(%d+)%s+(%d+)")
	-- pattern above is tricky; do it line-based instead
	size, used = nil, nil
	for line in out:gmatch("[^\n]+") do
		if not line:match("^Filesystem") then
			local s, u = line:match("%S+%s+(%d+)%s+(%d+)%s+%d+")
			if s then
				size, used = tonumber(s), tonumber(u)
				break
			end
		end
	end
	if not size or not used or size == 0 then
		return "unknown"
	end
	local function gb(bytes)
		return bytes / 1024 / 1024 / 1024
	end
	local pct = math.floor(used / size * 100 + 0.5)
	return string.format("%.0f / %.0f GB (%d%%)", gb(used), gb(size), pct)
end

return M
