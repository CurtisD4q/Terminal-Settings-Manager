-- env.lua — environment detection: distro, package manager, init system,
-- session/compositor, and audio server. This is the foundation for graceful
-- degradation (a category can ask "is this a systemd system?" before showing
-- systemd controls) and for eventual cross-distro support (the package-manager
-- abstraction builds on env.package_manager()).
--
-- Design contract:
--   * Depends on nothing in the project — bottom of the dependency graph.
--   * Every value is detected from the most authoritative source available,
--     then cached (the environment doesn't change during a session).
--   * Fields never return nil — unknown values are the string "unknown", so
--     callers can display or compare without nil-guards.
--   * Detection prefers verifiable facts (files in /proc, /etc/os-release,
--     running processes) over guesses.
local M = {}

-- ── tiny self-contained primitives (env depends on nothing) ──────────────────

local function shell(cmd)
	local f = io.popen(cmd .. " 2>/dev/null")
	if not f then
		return nil
	end
	local out = f:read("*a")
	f:close()
	return out
end

local function trim(s)
	return s and (s:gsub("^%s+", ""):gsub("%s+$", "")) or s
end

local function have(bin)
	local out = shell("command -v " .. ("%q"):format(bin))
	return out ~= nil and out:match("%S") ~= nil
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

local function path_exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	-- directories: io.open may fail; fall back to a shell test
	local out = shell("[ -e " .. ("%q"):format(path) .. " ] && echo yes")
	return out ~= nil and out:match("yes") ~= nil
end

-- session-scoped cache; every detector fills its slot once
local C = {}

-- ── /etc/os-release parsing ──────────────────────────────────────────────────

-- Parse os-release into a table of its KEY=value pairs (values unquoted).
-- The freedesktop standard file, present on essentially every modern distro.
local function os_release()
	if C.os_release then
		return C.os_release
	end
	local t = {}
	local body = read_file("/etc/os-release") or read_file("/usr/lib/os-release") or ""
	for line in body:gmatch("[^\n]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then
			-- strip surrounding quotes if present
			v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
			t[k] = v
		end
	end
	C.os_release = t
	return t
end

-- ── distro ───────────────────────────────────────────────────────────────────

-- Distro ID (e.g. "fedora", "debian", "arch"). Lowercased. "unknown" if absent.
function M.distro()
	if C.distro then
		return C.distro
	end
	local id = os_release().ID
	C.distro = (id and id:lower()) or "unknown"
	return C.distro
end

-- ID_LIKE tokens (e.g. {"rhel","fedora"} for a derivative). Used to map an
-- unfamiliar distro onto a known family. Returns a list (possibly empty).
function M.distro_like()
	if C.distro_like then
		return C.distro_like
	end
	local like = os_release().ID_LIKE or ""
	local list = {}
	for tok in like:gmatch("%S+") do
		list[#list + 1] = tok:lower()
	end
	C.distro_like = list
	return list
end

-- Human-friendly distro name + version, e.g. "Fedora Linux 43". "unknown" if
-- unreadable.
function M.distro_pretty()
	if C.distro_pretty then
		return C.distro_pretty
	end
	local o = os_release()
	C.distro_pretty = o.PRETTY_NAME or (o.NAME and (o.NAME .. " " .. (o.VERSION_ID or ""))) or "unknown"
	return C.distro_pretty
end

-- ── package manager ──────────────────────────────────────────────────────────

-- The distro-family -> package-manager mapping. Each entry lists the manager
-- name and the command(s) that would confirm it; detection verifies the binary
-- actually exists rather than trusting the distro ID alone.
local PM_BY_FAMILY = {
	fedora = { "dnf" },
	rhel = { "dnf" },
	centos = { "dnf" },
	debian = { "apt" },
	ubuntu = { "apt" },
	arch = { "pacman" },
	opensuse = { "zypper" },
	suse = { "zypper" },
	alpine = { "apk" },
	gentoo = { "emerge" },
}

-- Detect the system package manager. Strategy: try the distro's expected
-- manager first (verified present), then its ID_LIKE family, then a broad
-- presence scan as a last resort. Returns a name like "dnf"/"apt"/"pacman", or
-- "unknown" if none is found.
function M.package_manager()
	if C.package_manager then
		return C.package_manager
	end

	local function try_family(fam)
		local cands = PM_BY_FAMILY[fam]
		if not cands then
			return nil
		end
		for _, pm in ipairs(cands) do
			if have(pm) then
				return pm
			end
		end
		return nil
	end

	-- 1. exact distro
	local pm = try_family(M.distro())
	-- 2. ID_LIKE families
	if not pm then
		for _, fam in ipairs(M.distro_like()) do
			pm = try_family(fam)
			if pm then
				break
			end
		end
	end
	-- 3. broad scan (covers unknown distros)
	if not pm then
		for _, cand in ipairs({ "dnf", "apt", "pacman", "zypper", "apk", "emerge" }) do
			if have(cand) then
				pm = cand
				break
			end
		end
	end

	C.package_manager = pm or "unknown"
	return C.package_manager
end

-- ── init system ──────────────────────────────────────────────────────────────

-- The init system / PID 1 (e.g. "systemd", "openrc", "runit"). Detected from
-- what PID 1 actually is, not assumed. "unknown" if undetectable.
function M.init_system()
	if C.init_system then
		return C.init_system
	end
	local init
	-- /proc/1/comm holds PID 1's command name on Linux
	local comm = trim(read_file("/proc/1/comm") or "")
	if comm ~= "" then
		init = comm
	else
		-- fall back to the exe symlink target
		local exe = shell("readlink /proc/1/exe")
		if exe then
			init = trim(exe):match("([^/]+)$")
		end
	end
	-- normalize common names
	if init then
		init = init:lower()
		if init:find("systemd") then
			init = "systemd"
		elseif init:find("openrc") or init:find("init") and path_exists("/run/openrc") then
			init = "openrc"
		end
	end
	C.init_system = init or "unknown"
	return C.init_system
end

-- Is this a systemd system that's actually booted with systemd? (Some systems
-- have systemctl installed but boot another init.) Checks the runtime marker.
function M.is_systemd()
	if C.is_systemd ~= nil then
		return C.is_systemd
	end
	C.is_systemd = path_exists("/run/systemd/system")
	return C.is_systemd
end

-- ── session / compositor ─────────────────────────────────────────────────────

-- Session type: "wayland" | "x11" | "tty" | "unknown". Prefers the login
-- manager's XDG_SESSION_TYPE, then falls back to display-socket presence.
function M.session_type()
	if C.session_type then
		return C.session_type
	end
	local t = os.getenv("XDG_SESSION_TYPE")
	if t and t ~= "" then
		C.session_type = t:lower()
	elseif os.getenv("WAYLAND_DISPLAY") then
		C.session_type = "wayland"
	elseif os.getenv("DISPLAY") then
		C.session_type = "x11"
	else
		C.session_type = "tty"
	end
	return C.session_type
end

function M.is_wayland()
	return M.session_type() == "wayland"
end

-- The specific compositor / desktop (e.g. "sway", "hyprland", "gnome",
-- "kde"). Detected from compositor-specific env markers first (most reliable),
-- then XDG_CURRENT_DESKTOP. "unknown" if it can't be determined.
function M.compositor()
	if C.compositor then
		return C.compositor
	end
	local comp
	if os.getenv("SWAYSOCK") then
		comp = "sway"
	elseif os.getenv("HYPRLAND_INSTANCE_SIGNATURE") then
		comp = "hyprland"
	else
		local xdg = os.getenv("XDG_CURRENT_DESKTOP") or os.getenv("DESKTOP_SESSION") or ""
		xdg = xdg:lower()
		if xdg ~= "" then
			-- take the first token of e.g. "sway", "GNOME", "KDE:plasma"
			comp = xdg:match("^([%w_]+)")
		end
	end
	C.compositor = comp or "unknown"
	return C.compositor
end

function M.is_sway()
	return M.compositor() == "sway"
end

-- ── audio server ─────────────────────────────────────────────────────────────

-- The active audio server: "pipewire" | "pulseaudio" | "alsa" | "unknown".
-- PipeWire is detected by its running process / socket; PulseAudio only if
-- PipeWire is absent (pipewire-pulse impersonates pulse, so pactl alone can't
-- distinguish them).
function M.audio_server()
	if C.audio_server then
		return C.audio_server
	end
	local runtime = os.getenv("XDG_RUNTIME_DIR")
	local pipewire = false
	if runtime and path_exists(runtime .. "/pipewire-0") then
		pipewire = true
	else
		local pg = shell("pgrep -x pipewire")
		pipewire = pg ~= nil and pg:match("%d") ~= nil
	end
	if pipewire then
		C.audio_server = "pipewire"
	else
		local pa = shell("pgrep -x pulseaudio")
		if pa and pa:match("%d") then
			C.audio_server = "pulseaudio"
		elseif path_exists("/proc/asound") then
			C.audio_server = "alsa"
		else
			C.audio_server = "unknown"
		end
	end
	return C.audio_server
end

function M.has_pipewire()
	return M.audio_server() == "pipewire"
end

-- ── summary ──────────────────────────────────────────────────────────────────

-- A snapshot table of everything detected, for display or debugging.
function M.summary()
	return {
		distro = M.distro_pretty(),
		distro_id = M.distro(),
		package_manager = M.package_manager(),
		init = M.init_system(),
		systemd = M.is_systemd(),
		session = M.session_type(),
		compositor = M.compositor(),
		audio = M.audio_server(),
	}
end

return M
