-- network.lua — encapsulated, swappable Wi-Fi control.
--
-- Sway systems split between two Wi-Fi backends: NetworkManager (nmcli), the
-- mainstream default, and iwd (iwctl), popular on minimal/tiling setups. This
-- module hides that behind one interface so the Network category works on
-- either without knowing which is installed.
--
-- Public interface (the only surface the category touches):
--   net.available()              is any known Wi-Fi backend present
--   net.wifi_enabled()           (true|false, err)  radio state
--   net.set_wifi(on)             (ok, err)          turn radio on/off
--   net.status()                 short string       connection status
--   net.wifi_list()              (list, err)        { {ssid,signal,security,active}, ... }
--   net.is_saved(ssid)           boolean            known/saved network?
--   net.connect(ssid)            (ok, err)          connect to open/known net
--   net.connect_pw(ssid, pw)     (ok, err)          connect with a password
--   net.rescan()                 (ok, err)          trigger a scan
--   net.primary_ip()             string|nil         current IP (tool-agnostic)
--   net.link_speed()             string|nil         link rate (tool-agnostic)
--   net.name()                   "NetworkManager"|"iwd"  for DISPLAY only
--
-- Encapsulation: both drivers are `local`, own their tool and command syntax,
-- and expose only the contract. primary_ip/link_speed are genuinely the same
-- on both backends (they read `ip`/`iw`), so they are SHARED helpers rather
-- than per-driver methods — abstraction only where the tools truly diverge.
local M = {}
local util = require("util")
local provider = require("provider")

local function have(bin)
	return util.have(bin)
end

-- full multi-line command output (or nil). shell_value truncates to one line,
-- so list-producing commands use this instead.
local function shell_text(cmd)
	local out, err = util.shell(cmd)
	if err ~= nil then
		return nil
	end
	return out
end

-- ── shared, tool-agnostic helpers ────────────────────────────────────────────
-- IP address and link speed come from `ip`/`iw`, which are present regardless
-- of whether NetworkManager or iwd is managing the connection. Keeping these
-- out of the driver contract avoids duplicating identical code in each driver.

local function shared_primary_ip()
	-- default-route interface, then its first global IPv4
	local route = util.shell_value("ip route show default")
	if not route then
		return nil
	end
	local dev = route:match("dev%s+(%S+)")
	if not dev then
		return nil
	end
	local addr = util.shell_value("ip -4 -o addr show " .. util.shquote(dev))
	if not addr then
		return nil
	end
	return addr:match("inet%s+([%d%.]+)")
end

local function shared_link_speed()
	-- best-effort: use `iw` for the associated station bitrate if available
	if not have("iw") then
		return nil
	end
	local route = util.shell_value("ip route show default")
	local dev = route and route:match("dev%s+(%S+)")
	if not dev then
		return nil
	end
	local info = util.shell_value("iw dev " .. util.shquote(dev) .. " link")
	if not info then
		return nil
	end
	return info:match("tx bitrate:%s*([%d%.]+%s*%a+/s)")
end

-- ── driver: NetworkManager (nmcli) ───────────────────────────────────────────
-- Preserves the exact behaviour of the previous nmcli-based backend, including
-- the injection-safe util.run for anything taking an SSID.

local nm = {}
function nm:available()
	return have("nmcli")
end
function nm:name()
	return "NetworkManager"
end

function nm:wifi_enabled()
	local out = util.shell_value("nmcli radio wifi")
	if out == nil then
		return nil, "unavailable"
	end
	return out == "enabled", nil
end

function nm:set_wifi(on)
	local _, err = util.run("nmcli", "radio", "wifi", on and "on" or "off")
	return err == nil, err
end

local function nm_split_terse(line)
	-- nmcli -t escapes ':' inside fields as '\:'; split on unescaped colons
	local fields, buf, i = {}, {}, 1
	while i <= #line do
		local c = line:sub(i, i)
		if c == "\\" and line:sub(i + 1, i + 1) == ":" then
			buf[#buf + 1] = ":"
			i = i + 2
		elseif c == ":" then
			fields[#fields + 1] = table.concat(buf)
			buf = {}
			i = i + 1
		else
			buf[#buf + 1] = c
			i = i + 1
		end
	end
	fields[#fields + 1] = table.concat(buf)
	return fields
end

function nm:status()
	-- active connections as a list of { name, type, device, state }, matching
	-- what the category iterates to find the wireless connection's name.
	local out = shell_text("nmcli -t -f NAME,TYPE,DEVICE,STATE connection show --active")
	local conns = {}
	if out then
		for line in out:gmatch("[^\n]+") do
			local f = nm_split_terse(line)
			conns[#conns + 1] = { name = f[1], type = f[2], device = f[3], state = f[4] }
		end
	end
	return conns
end

function nm:wifi_list()
	local out = shell_text("nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list")
	if out == nil then
		return nil, "unavailable"
	end
	local nets, seen = {}, {}
	for line in out:gmatch("[^\n]+") do
		local f = nm_split_terse(line)
		local inuse, ssid, signal, sec = f[1], f[2], f[3], f[4]
		if ssid and ssid ~= "" and not seen[ssid] then
			seen[ssid] = true
			nets[#nets + 1] = {
				ssid = ssid,
				signal = tonumber(signal) or 0,
				security = (sec and sec ~= "") and sec or "open",
				active = (inuse == "*"),
			}
		end
	end
	table.sort(nets, function(a, b)
		return a.signal > b.signal
	end)
	return nets, nil
end

function nm:is_saved(ssid)
	local out = shell_text("nmcli -t -f NAME connection show")
	if not out then
		return false
	end
	for line in out:gmatch("[^\n]+") do
		if line == ssid then
			return true
		end
	end
	return false
end

function nm:connect(ssid)
	local _, err = util.run("nmcli", "device", "wifi", "connect", ssid)
	return err == nil, err
end

function nm:connect_pw(ssid, pw)
	local _, err = util.run("nmcli", "device", "wifi", "connect", ssid, "password", pw)
	return err == nil, err
end

function nm:rescan()
	-- IMPORTANT: never block the UI on a scan. `--rescan yes` forces nmcli to
	-- wait for a full radio sweep, which can take many seconds (30s+ on some
	-- adapters) and freezes the single-threaded TUI the whole time. Instead we
	-- KICK OFF a background rescan (returns immediately) and let wifi_list read
	-- whatever nmcli currently has cached. NetworkManager also rescans on its
	-- own periodically, so the cache is usually fresh; if it's the first scan,
	-- the list fills in on the next manual Scan a moment later.
	-- `nmcli device wifi rescan` starts the scan without waiting for results.
	util.run("nmcli", "device", "wifi", "rescan")
	return true, nil
end

-- ── driver: iwd (iwctl) ──────────────────────────────────────────────────────
-- iwd is device-scoped: operations run against a station (the wlan device), so
-- the driver discovers its station name first. All of that is private here; the
-- category never sees a device name.

local iwd = {}

-- discover the first wireless station device name (cached per call site)
local function iwd_station()
	-- `iwctl station list` prints a table; extract the first device name.
	local out = shell_text("iwctl station list")
	if not out then
		return nil
	end
	for line in out:gmatch("[^\n]+") do
		-- device rows look like:  "  wlan0   connected  ..." after a header
		local dev = line:match("^%s*(%w[%w%-]*)%s+")
		if dev and dev ~= "Name" and not dev:match("^%-+$") then
			return dev
		end
	end
	return nil
end

function iwd:available()
	return have("iwctl")
end
function iwd:name()
	return "iwd"
end

function iwd:wifi_enabled()
	local dev = iwd_station()
	if not dev then
		return nil, "no wireless device"
	end
	local out = util.shell_value("iwctl device " .. util.shquote(dev) .. " show")
	if not out then
		return nil, "unavailable"
	end
	-- "Powered   on/off"
	local powered = out:match("Powered%s+(%a+)")
	if powered then
		return powered == "on", nil
	end
	return nil, "unknown"
end

function iwd:set_wifi(on)
	local dev = iwd_station()
	if not dev then
		return false, "no wireless device"
	end
	local _, err = util.run("iwctl", "device", dev, "set-property", "Powered", on and "on" or "off")
	return err == nil, err
end

function iwd:status()
	-- Return the same list-of-connections shape as the nmcli driver so the
	-- category's iteration works unchanged. iwd is Wi-Fi only, so this is at
	-- most one wireless entry, present only when connected.
	local dev = iwd_station()
	if not dev then
		return {}
	end
	local out = shell_text("iwctl station " .. util.shquote(dev) .. " show")
	if not out then
		return {}
	end
	local state = out:match("State%s+(%a+)")
	if state ~= "connected" then
		return {}
	end
	local name
	for line in out:gmatch("[^\n]+") do
		local n = line:match("Connected network%s+(.-)%s*$")
		if n and n ~= "" then
			name = util.trim(n)
			break
		end
	end
	return { {
		name = name or "Wi-Fi",
		type = "wireless",
		device = dev,
		state = state,
	} }
end

function iwd:wifi_list()
	local dev = iwd_station()
	if not dev then
		return nil, "no wireless device"
	end
	local out = shell_text("iwctl station " .. util.shquote(dev) .. " get-networks")
	if not out then
		return nil, "unavailable"
	end
	local nets, seen = {}, {}
	local in_table = false
	for line in out:gmatch("[^\n]+") do
		-- strip ANSI decoration
		local stripped = line:gsub("\27%[[%d;]*m", "")
		-- iwd prints a header block ending in a dashed separator, then rows.
		-- Skip everything until after the SECOND separator line, and skip any
		-- separator/header lines themselves.
		if stripped:match("^%s*%-%-+%s*$") then
			in_table = true
		elseif stripped:match("Available networks") or stripped:match("Network name") or stripped:match("^%s*$") then
			-- header/title/blank — ignore
		elseif in_table then
			local active = stripped:match("^%s*>") ~= nil
			local body = stripped:gsub("^%s*>?%s*", "")
			-- columns: SSID  SECURITY  SIGNAL(stars). SSID may contain spaces,
			-- but security is a known keyword, so split on it.
			local ssid, sec = body:match("^(.-)%s+(psk)%f[%s]")
			if not ssid then
				ssid, sec = body:match("^(.-)%s+(open)%f[%s]")
			end
			if not ssid then
				ssid, sec = body:match("^(.-)%s+(8021x)%f[%s]")
			end
			if ssid then
				ssid = util.trim(ssid)
			end
			if ssid and ssid ~= "" and not seen[ssid] then
				seen[ssid] = true
				local stars = select(2, stripped:gsub("%*", ""))
				nets[#nets + 1] = {
					ssid = ssid,
					signal = (stars > 0) and (stars * 20) or 50,
					security = (sec == "open") and "open" or (sec or "psk"),
					active = active,
				}
			end
		end
	end
	table.sort(nets, function(a, b)
		return a.signal > b.signal
	end)
	return nets, nil
end

function iwd:is_saved(ssid)
	local out = shell_text("iwctl known-networks list")
	if not out then
		return false
	end
	-- match the SSID appearing as a known network name
	for line in out:gmatch("[^\n]+") do
		local stripped = line:gsub("\27%[[%d;]*m", "")
		if stripped:find(ssid, 1, true) then
			return true
		end
	end
	return false
end

function iwd:connect(ssid)
	local dev = iwd_station()
	if not dev then
		return false, "no wireless device"
	end
	-- open or already-known network: no passphrase needed
	local _, err = util.run("iwctl", "station", dev, "connect", ssid)
	return err == nil, err
end

function iwd:connect_pw(ssid, pw)
	local dev = iwd_station()
	if not dev then
		return false, "no wireless device"
	end
	-- newer iwctl accepts an inline passphrase; this avoids the interactive
	-- agent, which can't be driven from inside the TUI.
	local _, err = util.run("iwctl", "--passphrase", pw, "station", dev, "connect", ssid)
	return err == nil, err
end

function iwd:rescan()
	local dev = iwd_station()
	if not dev then
		return false, "no wireless device"
	end
	util.run("iwctl", "station", dev, "scan")
	return true, nil
end

-- ── sealed provider ──────────────────────────────────────────────────────────
-- Prefer NetworkManager when present (it's the mainstream default and manages
-- more than Wi-Fi), fall back to iwd. Drivers stay private; only the interface
-- methods are exposed via the proxy.
local proxy = provider.select(
	{ nm, iwd },
	{ "wifi_enabled", "set_wifi", "status", "wifi_list", "is_saved", "connect", "connect_pw", "rescan", "name" }
)

M.available = proxy.available
M.wifi_enabled = proxy.wifi_enabled
M.set_wifi = proxy.set_wifi
M.status = proxy.status
M.wifi_list = proxy.wifi_list
M.is_saved = proxy.is_saved
M.connect = proxy.connect
M.connect_pw = proxy.connect_pw
M.rescan = proxy.rescan
M.name = proxy.name

-- shared, tool-agnostic (not part of the driver contract)
M.primary_ip = shared_primary_ip
M.link_speed = shared_link_speed

return M
