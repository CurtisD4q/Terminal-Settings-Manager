-- util.lua — shared primitives for the settings apps.
--
-- Design contract (obeyed by every function here):
--   * Dependency-free: this module requires nothing from the project. It sits
--     at the bottom of the dependency graph; everything may depend on it, it
--     depends on nothing. Never add a require() for core or a backend here.
--   * Consistent returns: functions that can fail return `value, err` where
--     err is nil on success and a short string on failure. Pure functions
--     (trim) just return their value.
--   * Safe by construction: the primary command runner, M.run, takes the
--     program and each argument SEPARATELY and quotes them internally, so a
--     value containing a space, quote, or ';' can never break out into the
--     shell. M.shell (raw string, real shell) exists only for the rare cases
--     that genuinely need shell features (pipes, redirects, here-docs); it is
--     named distinctly so those call sites are visible in review and the
--     caller owns their own safety.
--   * No leaked state: internal caches (have) are private implementation
--     details; callers see pure-looking functions.
local M = {}

-- ── string primitives ───────────────────────────────────────────────────────

-- Trim leading/trailing whitespace. Pure. nil-safe (returns its input if nil).
function M.trim(s)
	if type(s) ~= "string" then
		return s
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Single-quote a string for POSIX shell inclusion. The canonical safe quoting:
-- wrap in single quotes and replace any embedded single quote with '\'' . This
-- is the ONE definition of shell escaping in the codebase — everything that
-- must build a shell string uses this rather than ad-hoc %q.
function M.shquote(s)
	s = tostring(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ── command execution ────────────────────────────────────────────────────────

-- Internal: run a fully-formed shell string, capture stdout, report success.
-- stderr is discarded (callers that need it use the diagnostic form below).
-- Returns: output (string, possibly ""), err (nil on success, else message).
local function popen_capture(command)
	local f = io.popen(command .. " 2>/dev/null")
	if not f then
		return nil, "cannot spawn"
	end
	local out = f:read("*a") or ""
	-- close returns: ok(boolean), reason("exit"/"signal"), code(number)
	local ok, _, code = f:close()
	local success = (ok == true) or (code == 0)
	if success then
		return out, nil
	end
	return out, "exit " .. tostring(code)
end

-- SAFE command runner. Pass the program and each argument as separate strings;
-- each is shell-quoted internally, so untrusted values (device names, unit
-- names, SSIDs) cannot inject. Use this for the overwhelming majority of calls.
--   local out, err = M.run("systemctl", "start", unit)
-- Returns: output, err (err nil on success).
function M.run(program, ...)
	local parts = { M.shquote(program) }
	local args = { ... }
	for i = 1, select("#", ...) do
		parts[#parts + 1] = M.shquote(args[i])
	end
	return popen_capture(table.concat(parts, " "))
end

-- RAW shell escape hatch. Runs an arbitrary shell string with all shell
-- features available (pipes, redirects, here-docs). NOT safe against injection
-- by design — the caller is responsible for quoting any interpolated values
-- (use M.shquote). Named distinctly so these call sites stand out in review.
--   local out, err = M.shell("rpm -qa | wc -l")
-- Returns: output, err (err nil on success).
function M.shell(command)
	return popen_capture(command)
end

-- Convenience: run a command and return only whether it succeeded (boolean).
-- For fire-and-forget actions where the output doesn't matter.
function M.run_ok(program, ...)
	local _, err = M.run(program, ...)
	return err == nil
end

-- ── purpose-built accessors ──────────────────────────────────────────────────
-- These exist because the general run()/shell() return the ambiguous
-- (output, err) tuple, and every call site then has to re-derive which part of
-- that it actually wanted — the exact spot where a positional mistake (reading
-- slot two as an "ok" boolean instead of an "err") slips in silently. Each
-- accessor below encodes ONE intent in its name and returns ONE unambiguous
-- type, so the datatype is obvious at the call site and can't be misread:
--   run_value  -> string or nil   (read a single value)
--   run_lines  -> list (never nil)(iterate over output lines)
--   run_ok     -> boolean         (did it work; defined above)
-- The raw run()/shell() remain for the rare case that genuinely needs the tuple
-- or shell features.

-- Run a command and return its trimmed output as a single string, or nil if
-- the command failed OR produced no output. Use for "read one value" calls
-- (a sysctl value, a gsettings key, a status word). The return is string-or-nil
-- — never a boolean — so it cannot be confused with a success flag.
function M.run_value(program, ...)
	local out, err = M.run(program, ...)
	if err ~= nil then
		return nil
	end
	local t = M.trim(out)
	if t == "" then
		return nil
	end
	return t
end

-- Run a command and return its output split into a list of non-empty lines.
-- ALWAYS returns a table — empty on failure or no output — so callers can
-- ipairs() the result without a nil check. Use for "iterate over output" calls
-- (unit lists, device lists, directory contents).
function M.run_lines(program, ...)
	local out, err = M.run(program, ...)
	local lines = {}
	if err ~= nil or out == nil then
		return lines
	end
	for line in out:gmatch("[^\n]+") do
		local t = M.trim(line)
		if t ~= "" then
			lines[#lines + 1] = t
		end
	end
	return lines
end

-- Shell-string variants of the two accessors above, for the escape-hatch cases
-- that need pipes/redirects. Same unambiguous return contracts.
function M.shell_value(command)
	local out, err = M.shell(command)
	if err ~= nil then
		return nil
	end
	local t = M.trim(out)
	if t == "" then
		return nil
	end
	return t
end

function M.shell_lines(command)
	local out, err = M.shell(command)
	local lines = {}
	if err ~= nil or out == nil then
		return lines
	end
	for line in out:gmatch("[^\n]+") do
		local t = M.trim(line)
		if t ~= "" then
			lines[#lines + 1] = t
		end
	end
	return lines
end

-- ── filesystem ───────────────────────────────────────────────────────────────

-- Read an entire file. Returns: contents, err. err is non-nil if the file
-- can't be opened (missing, unreadable). Callers that only care about presence
-- can ignore the contents.
function M.read_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil, "cannot open"
	end
	local data = f:read("*a")
	f:close()
	return data, nil
end

-- Read the first line of a file (common for /sys and /proc single-value files),
-- trimmed. Returns: line, err.
function M.read_line(path)
	local f = io.open(path, "r")
	if not f then
		return nil, "cannot open"
	end
	local line = f:read("*l")
	f:close()
	if line == nil then
		return nil, "empty"
	end
	return M.trim(line), nil
end

-- Test whether a path exists (file or directory). Returns boolean.
function M.path_exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	-- io.open fails on directories on some systems; probe with a shell test.
	local out = M.shell("[ -e " .. M.shquote(path) .. " ] && echo y")
	return out ~= nil and out:match("y") ~= nil
end

-- ── tool availability (privately cached) ─────────────────────────────────────

-- Is an executable present on PATH? The result is memoized per-session in a
-- private table — repeated `have()` calls don't re-fork. The cache is an
-- invisible implementation detail; callers see a pure-looking predicate.
-- `command -v` is a shell builtin, so this is one of the legitimate uses of
-- the raw shell form; the argument is escaped with shquote.
local have_cache = {}
function M.have(bin)
	if have_cache[bin] == nil then
		local out = M.shell("command -v " .. M.shquote(bin))
		have_cache[bin] = (out ~= nil and out:match("%S") ~= nil)
	end
	return have_cache[bin]
end

-- Clear the availability cache (rarely needed; useful in tests or if the
-- environment changes mid-session).
function M.forget_have()
	have_cache = {}
end

-- Batch-detect many tools in a SINGLE shell invocation and pre-populate the
-- have() cache. Without this, each tool's first have() check forks its own
-- `command -v`; a category open might trigger several. Calling this once at
-- startup with the full tool list collapses all those forks into one, so no
-- category-open pays detection latency — have() calls afterward are pure cache
-- hits.
--
-- Implementation: a single `sh -c` loops over the names and prints "name" for
-- each one that resolves on PATH. We read that set back and record every
-- requested tool as present (in the set) or absent (not), so absent tools are
-- cached too and never re-probed.
--   util.detect_tools({ "systemctl", "lsblk", "cryptsetup", ... })
function M.detect_tools(names)
	if type(names) ~= "table" or #names == 0 then
		return
	end
	-- Build a space-separated, individually-quoted list for the shell loop.
	local quoted = {}
	for _, n in ipairs(names) do
		quoted[#quoted + 1] = M.shquote(n)
	end
	-- One fork: for each name, if `command -v` finds it, echo the name.
	local script = "for t in " .. table.concat(quoted, " ") .. '; do command -v "$t" >/dev/null 2>&1 && echo "$t"; done'
	local out = M.shell(script) or ""
	-- Collect the set of tools that resolved.
	local present = {}
	for line in out:gmatch("[^\n]+") do
		present[M.trim(line)] = true
	end
	-- Record every requested tool: present ones true, the rest false, so no
	-- tool in this list is ever probed again.
	for _, n in ipairs(names) do
		have_cache[n] = present[n] == true
	end
end

-- The full set of external tools any category might probe. Kept here in one
-- place so a launcher can warm them all at startup with warm_tools() without
-- duplicating the list. Adding a new tool dependency? Add it here too.
M.KNOWN_TOOLS = {
	-- App 1 (general settings)
	"swaymsg",
	"brightnessctl",
	"wlsunset", -- display
	"wpctl",
	"pactl", -- sound
	"bluetoothctl", -- bluetooth
	"nmcli", -- network
	"xdg-mime",
	"xdg-settings", -- applications
	"firewall-cmd", -- privacy
	-- App 2 (system admin)
	"rpm",
	"flatpak",
	"dnf", -- packages
	"lsblk",
	"udisksctl", -- storage
	"cryptsetup", -- encryption
	"systemctl",
	"systemd-analyze",
	"journalctl", -- services / boot time
	"bootctl",
	"grubby",
	"mokutil", -- boot loader
	"sysctl", -- kernel tuning
}

-- Warm the availability cache for every known tool in a single pass. Call once
-- at startup (before any category opens) so no category-open pays detection
-- latency. Idempotent and cheap to call again.
function M.warm_tools()
	M.detect_tools(M.KNOWN_TOOLS)
end

-- ── JSON ──────────────────────────────────────────────────────────────────────
-- Minimal decoder for the well-formed JSON that tools like `lsblk -J` and
-- `swaymsg -t ... -r` emit: objects, arrays, strings, numbers, booleans, null.
-- Not a general-purpose parser — just what those tools produce. Internal raw
-- decoder pcall-wrapped by the public M.json_decode, which follows the
-- (value, err) convention and never raises on malformed input.
local function _json_decode_raw(s)
	local pos = 1
	local function skip_ws()
		local _, e = s:find("^[ \t\r\n]+", pos)
		if e then
			pos = e + 1
		end
	end
	local parse_value
	local function parse_string()
		pos = pos + 1
		local buf = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				return table.concat(buf)
			elseif c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
				buf[#buf + 1] = map[n] or n
				pos = pos + 2
			else
				buf[#buf + 1] = c
				pos = pos + 1
			end
		end
		error("unterminated string")
	end
	local function parse_number()
		local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
		pos = pos + #num
		return tonumber(num)
	end
	local function parse_object()
		pos = pos + 1
		local obj = {}
		skip_ws()
		if s:sub(pos, pos) == "}" then
			pos = pos + 1
			return obj
		end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			pos = pos + 1
			skip_ws()
			obj[key] = parse_value()
			skip_ws()
			local c = s:sub(pos, pos)
			pos = pos + 1
			if c == "}" then
				return obj
			elseif c ~= "," then
				error("expected , or }")
			end
		end
	end
	local function parse_array()
		pos = pos + 1
		local arr = {}
		skip_ws()
		if s:sub(pos, pos) == "]" then
			pos = pos + 1
			return arr
		end
		while true do
			skip_ws()
			arr[#arr + 1] = parse_value()
			skip_ws()
			local c = s:sub(pos, pos)
			pos = pos + 1
			if c == "]" then
				return arr
			elseif c ~= "," then
				error("expected , or ]")
			end
		end
	end
	parse_value = function()
		skip_ws()
		local c = s:sub(pos, pos)
		if c == '"' then
			return parse_string()
		elseif c == "{" then
			return parse_object()
		elseif c == "[" then
			return parse_array()
		elseif c == "t" then
			pos = pos + 4
			return true
		elseif c == "f" then
			pos = pos + 5
			return false
		elseif c == "n" then
			pos = pos + 4
			return nil
		else
			return parse_number()
		end
	end
	local ok, result = pcall(parse_value)
	if not ok then
		return nil
	end
	return result
end

-- Public: decode JSON text. Returns (value, nil) on success or (nil, err) on
-- empty/invalid input. Never raises.
function M.json_decode(s)
	if type(s) ~= "string" or s == "" then
		return nil, "empty input"
	end
	local ok, result = pcall(_json_decode_raw, s)
	if not ok then
		return nil, tostring(result)
	end
	if result == nil then
		return nil, "malformed json"
	end
	return result, nil
end

return M
