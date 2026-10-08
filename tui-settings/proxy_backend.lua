-- proxy_backend.lua — GNOME/GSettings network proxy (org.gnome.system.proxy).
-- All user-level (gsettings needs no root). GTK apps and some others honor
-- these settings. Reads and writes go through the one `gsettings` interface;
-- values are parsed from its quoted output.
local M = {}
local util = require("util")

M.available = function()
	return util.have("gsettings")
end

local SCHEMA = "org.gnome.system.proxy"

-- Read a key from a schema (or child schema). Returns the trimmed gsettings
-- value string, or nil. run_value's contract is "string or nil" — there is no
-- second slot to misread as a success flag, which is exactly the class of bug
-- this replaced.
local function get(schema, key)
	return util.run_value("gsettings", "get", schema, key)
end

-- Set a key. gsettings value syntax varies by type, so the caller passes the
-- already-formatted value string (e.g. "'manual'", "8080", "['localhost']").
-- run_ok returns a plain boolean — unambiguous.
local function set(schema, key, value)
	return util.run_ok("gsettings", "set", schema, key, value)
end

-- Strip the surrounding single quotes gsettings puts around string values.
local function unquote(s)
	if not s then
		return nil
	end
	local inner = s:match("^'(.*)'$")
	return inner ~= nil and inner or s
end

-- ── mode ─────────────────────────────────────────────────────────────────────

-- Current proxy mode: "none" | "manual" | "auto" (or nil if unreadable).
function M.mode()
	return unquote(get(SCHEMA, "mode"))
end

-- Set the proxy mode. Accepts "none" | "manual" | "auto".
function M.set_mode(mode)
	return set(SCHEMA, "mode", "'" .. mode .. "'")
end

-- The ordered list of modes, for cycling in the UI.
M.MODES = { "none", "manual", "auto" }

-- ── manual proxy (per-protocol host/port) ────────────────────────────────────

-- The protocols we expose. Each maps to a child schema of the proxy schema.
M.PROTOCOLS = { "http", "https", "ftp", "socks" }

-- Read a protocol's host and port. Returns (host, port) where host is a string
-- (possibly "") and port a number (possibly 0).
function M.get_manual(proto)
	local schema = SCHEMA .. "." .. proto
	local host = unquote(get(schema, "host")) or ""
	local port = tonumber(get(schema, "port")) or 0
	return host, port
end

-- Set a protocol's host and port. Empty host + zero port effectively clears it.
function M.set_manual(proto, host, port)
	local schema = SCHEMA .. "." .. proto
	local ok1 = set(schema, "host", "'" .. (host or "") .. "'")
	local ok2 = set(schema, "port", tostring(tonumber(port) or 0))
	return ok1 and ok2
end

-- Clear a protocol's manual proxy (blank host, port 0).
function M.clear_manual(proto)
	return M.set_manual(proto, "", 0)
end

-- ── automatic (PAC) ──────────────────────────────────────────────────────────

-- The autoconfig (PAC) URL, or "".
function M.autoconfig_url()
	return unquote(get(SCHEMA, "autoconfig-url")) or ""
end

function M.set_autoconfig_url(url)
	return set(SCHEMA, "autoconfig-url", "'" .. (url or "") .. "'")
end

function M.clear_autoconfig_url()
	return M.set_autoconfig_url("")
end

-- ── ignore hosts ─────────────────────────────────────────────────────────────

-- The ignore-hosts list (hosts that bypass the proxy). Returns a list of
-- strings parsed from the gsettings array syntax ['a', 'b', ...].
function M.ignore_hosts()
	local raw = get(SCHEMA, "ignore-hosts")
	if not raw then
		return {}
	end
	local list = {}
	for item in raw:gmatch("'([^']*)'") do
		list[#list + 1] = item
	end
	return list
end

return M
