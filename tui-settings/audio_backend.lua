-- audio_backend.lua — real system audio control via wpctl (PipeWire).
-- Used by a1_sound.lua. Kept as a separate module so the backend logic is
-- easy to read, test, and swap out if you're on plain PulseAudio (pactl)
-- instead of PipeWire.
local M = {}

local util = require("util")

-- Local shim onto util (audited execution + quoting), preserving this module's
-- (out, ok) convention at the existing call sites.
local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

-- wpctl presence (util.have memoizes internally, so no local cache needed)
local function have_wpctl()
	return util.have("wpctl")
end
M.available = have_wpctl

-- Parse "Volume: 0.65\n" or "Volume: 0.65 [MUTED]\n" into (percent, muted)
local function parse_volume(out)
	if not out then
		return nil, nil
	end
	local vol = out:match("Volume:%s*([%d%.]+)")
	if not vol then
		return nil, nil
	end
	local muted = out:match("%[MUTED%]") ~= nil
	return math.floor(tonumber(vol) * 100 + 0.5), muted
end

-- target: "@DEFAULT_AUDIO_SINK@" (output) or "@DEFAULT_AUDIO_SOURCE@" (input)
function M.get_volume(target)
	if not have_wpctl() then
		return nil, nil, "wpctl not found"
	end
	local out, ok = shell("wpctl get-volume " .. target)
	if not ok or not out then
		return nil, nil, "device unavailable"
	end
	local pct, muted = parse_volume(out)
	if not pct then
		return nil, nil, "unexpected wpctl output"
	end
	return pct, muted, nil
end

function M.set_volume(target, pct)
	if not have_wpctl() then
		return false, "wpctl not found"
	end
	pct = math.max(0, math.min(150, math.floor(pct + 0.5)))
	local _, ok = shell(("wpctl set-volume %s %d%%"):format(target, pct))
	if ok then
		return true, nil
	end
	return false, "set-volume failed"
end

function M.get_mute(target)
	local _, muted, err = M.get_volume(target)
	return muted, err
end

function M.set_mute(target, muted)
	if not have_wpctl() then
		return false, "wpctl not found"
	end
	local arg = muted and "1" or "0"
	local _, ok = shell(("wpctl set-mute %s %s"):format(target, arg))
	if ok then
		return true, nil
	end
	return false, "set-mute failed"
end

M.SINK = "@DEFAULT_AUDIO_SINK@"
M.SOURCE = "@DEFAULT_AUDIO_SOURCE@"

-- Parse `wpctl status`'s Sinks:/Sources: sections into
-- { {id="50", name="Built-in Audio Analog Stereo", default=true}, ... }
-- Tolerant of the box-drawing prefixes (│ ├ └) and variable spacing wpctl uses.
function M.list_devices()
	if not have_wpctl() then
		return nil, nil, "wpctl not found"
	end
	local out, ok = shell("wpctl status")
	if not ok or not out then
		return nil, nil, "wpctl status failed"
	end
	local sinks, sources = {}, {}
	local section = nil
	for line in (out .. "\n"):gmatch("(.-)\n") do
		if line:match("Sinks:%s*$") then
			section = "sinks"
		elseif line:match("Sources:%s*$") then
			section = "sources"
		elseif line:match(":%s*$") then
			section = nil -- any other header ends the list
		elseif line:match("^%s*$") then
			section = nil
		elseif section then
			local star, id, name = line:match("(%*?)%s*(%d+)%.%s+(.-)%s+%[vol:")
			if id then
				local list = (section == "sinks") and sinks or sources
				list[#list + 1] = { id = id, name = name, default = (star == "*") }
			end
		end
	end
	if #sinks == 0 and #sources == 0 then
		return nil, nil, "no devices found"
	end
	return sinks, sources, nil
end

function M.set_default(id)
	if not have_wpctl() then
		return false, "wpctl not found"
	end
	local _, ok = shell(("wpctl set-default %s"):format(id))
	if ok then
		return true, nil
	end
	return false, "set-default failed"
end

-- ── port switching (pactl) ───────────────────────────────────────────────
-- wpctl has no concept of ports — on most machines "headphones vs speakers"
-- is two PORTS on one sink (the audio codec), not two separate sinks. That
-- needs pactl. wpctl set-default (above) still matters separately, for
-- machines where output devices really are distinct sinks (e.g. a USB DAC).
local function have_pactl()
	return util.have("pactl")
end
M.pactl_available = have_pactl

function M.get_default_sink_name()
	if not have_pactl() then
		return nil, "pactl not found"
	end
	local out, ok = shell("pactl get-default-sink")
	if not ok or not out then
		return nil, "get-default-sink failed"
	end
	local name = out:match("%S+")
	if not name then
		return nil, "unexpected output"
	end
	return name, nil
end

function M.get_default_source_name()
	if not have_pactl() then
		return nil, "pactl not found"
	end
	local out, ok = shell("pactl get-default-source")
	if not ok or not out then
		return nil, "get-default-source failed"
	end
	local name = out:match("%S+")
	if not name then
		return nil, "unexpected output"
	end
	return name, nil
end

-- Parses `pactl list sinks` or `pactl list sources` (identical shape) into
-- { {name=.., description=.., ports={ {name=,desc=}, ... }, active_port=..}, .. }
local function parse_pactl_list(out, header_pattern)
	local items = {}
	local cur, in_ports = nil, false
	for line in (out .. "\n"):gmatch("(.-)\n") do
		if line:match(header_pattern) then
			cur = { ports = {} }
			items[#items + 1] = cur
			in_ports = false
		elseif cur then
			local name = line:match("^%s*Name:%s*(.+)")
			if name then
				cur.name = name
			end
			local desc = line:match("^%s*Description:%s*(.+)")
			if desc then
				cur.description = desc
			end
			if line:match("^%s*Ports:%s*$") then
				in_ports = true
			else
				local ap = line:match("^%s*Active Port:%s*(.+)")
				if ap then
					cur.active_port = ap
					in_ports = false
				elseif in_ports then
					local pname, pdesc = line:match("^%s*([%w%.%-_]+):%s*(.-)%s*%(")
					if pname then
						cur.ports[#cur.ports + 1] = { name = pname, desc = pdesc }
					end
				end
			end
		end
	end
	return items
end

function M.list_sinks_full()
	if not have_pactl() then
		return nil, "pactl not found"
	end
	local out, ok = shell("pactl list sinks")
	if not ok or not out then
		return nil, "pactl list sinks failed"
	end
	local sinks = parse_pactl_list(out, "^Sink #%d+")
	if #sinks == 0 then
		return nil, "no sinks found"
	end
	return sinks, nil
end

function M.list_sources_full()
	if not have_pactl() then
		return nil, "pactl not found"
	end
	local out, ok = shell("pactl list sources")
	if not ok or not out then
		return nil, "pactl list sources failed"
	end
	local sources = parse_pactl_list(out, "^Source #%d+")
	if #sources == 0 then
		return nil, "no sources found"
	end
	return sources, nil
end

function M.set_sink_port(sink_name, port_name)
	if not have_pactl() then
		return false, "pactl not found"
	end
	local _, ok = shell(("pactl set-sink-port %s %s"):format(sink_name, port_name))
	if ok then
		return true, nil
	end
	return false, "set-sink-port failed"
end

function M.set_source_port(source_name, port_name)
	if not have_pactl() then
		return false, "pactl not found"
	end
	local _, ok = shell(("pactl set-source-port %s %s"):format(source_name, port_name))
	if ok then
		return true, nil
	end
	return false, "set-source-port failed"
end

-- ── unified destination list ────────────────────────────────────────────────
-- The real world is mixed: one sink (the analog codec) may carry several
-- PORTS (Speakers, Headphones), while other outputs are entirely SEPARATE
-- sinks (HDMI, a USB DAC). Neither "ports only" nor "sinks only" shows the
-- whole picture. This flattens everything into ONE list where each entry is a
-- single selectable destination:
--   { key, label, sink_name, port, is_active }
-- - a sink with ports contributes one entry per port
-- - a sink with no ports contributes one entry (port = nil)
-- key is a stable identifier ("sink_name|port" or just "sink_name").
-- Selecting an entry means: make its sink the default AND (if it has a port)
-- switch that sink to the port.
local function build_destinations(list_full_fn, default_name)
	local full, err = list_full_fn()
	if type(full) ~= "table" then
		return nil, err or "no devices"
	end
	local dests = {}
	for _, s in ipairs(full) do
		if type(s) == "table" and s.name then
			local sink_is_default = (s.name == default_name)
			if type(s.ports) == "table" and #s.ports > 0 then
				for _, p in ipairs(s.ports) do
					local label = p.desc or p.name
					-- if there are multiple sinks, prefix with the device
					-- description so "Headphones" vs "HDMI" is unambiguous
					dests[#dests + 1] = {
						key = s.name .. "|" .. p.name,
						label = label,
						device = s.description or s.name,
						sink_name = s.name,
						port = p.name,
						is_active = sink_is_default and (s.active_port == p.name),
					}
				end
			else
				dests[#dests + 1] = {
					key = s.name,
					label = s.description or s.name,
					device = s.description or s.name,
					sink_name = s.name,
					port = nil,
					is_active = sink_is_default,
				}
			end
		end
	end
	if #dests == 0 then
		return nil, "no destinations"
	end
	return dests, nil
end

function M.output_destinations()
	local defname = M.get_default_sink_name()
	return build_destinations(M.list_sinks_full, defname)
end

function M.input_destinations()
	local defname = M.get_default_source_name()
	return build_destinations(M.list_sources_full, defname)
end

-- Select a destination: set its sink/source as default, then switch its port.
function M.set_output_destination(dest)
	if type(dest) ~= "table" or not dest.sink_name then
		return false, "invalid destination"
	end
	-- make this sink the default (matters when there are multiple sinks)
	if have_pactl() then
		shell(("pactl set-default-sink %s"):format(dest.sink_name))
	end
	-- switch to the chosen port on that sink
	if dest.port then
		return M.set_sink_port(dest.sink_name, dest.port)
	end
	return true, nil
end

function M.set_input_destination(dest)
	if type(dest) ~= "table" or not dest.sink_name then
		return false, "invalid destination"
	end
	if have_pactl() then
		shell(("pactl set-default-source %s"):format(dest.sink_name))
	end
	if dest.port then
		return M.set_source_port(dest.sink_name, dest.port)
	end
	return true, nil
end

-- ── friendly app names via .desktop files (fuzzel-style resolution) ────────
-- pactl only knows what an app chose to report about itself, and not every
-- app sets application.name usefully (or at all). App launchers like fuzzel
-- solve the same problem by reading .desktop files instead of trusting the
-- app — this does the same lookup: given a binary name (e.g. "vlc"), find
-- its .desktop entry and use the proper Name= field from that.
local shq = util.shquote

local desktop_files_cache = nil
local function desktop_files()
	if desktop_files_cache then
		return desktop_files_cache
	end
	desktop_files_cache = {}
	local home = os.getenv("HOME") or ""
	-- The full set of XDG application directories, including Flatpak exports.
	-- Flatpak apps are a common audio source, and omitting these dirs meant a
	-- Flatpak app's stream showed its raw binary name instead of a friendly one.
	-- Keep this list in sync with applications_backend's app_dirs().
	local dirs = {
		home ~= "" and (home .. "/.local/share/applications") or nil,
		"/usr/local/share/applications",
		"/usr/share/applications",
		home ~= "" and (home .. "/.local/share/flatpak/exports/share/applications") or nil,
		"/var/lib/flatpak/exports/share/applications",
	}
	for _, dir in ipairs(dirs) do
		for _, name in ipairs(util.shell_lines("ls -1 " .. shq(dir))) do
			if name:match("%.desktop$") then
				desktop_files_cache[#desktop_files_cache + 1] = dir .. "/" .. name
			end
		end
	end
	return desktop_files_cache
end

local desktop_name_cache = {}
local function desktop_name_for(binary)
	if not binary or binary == "" then
		return nil
	end
	if desktop_name_cache[binary] ~= nil then
		local v = desktop_name_cache[binary]
		if v == false then
			return nil
		end
		return v
	end
	local found = nil
	for _, path in ipairs(desktop_files()) do
		local f = io.open(path, "r")
		if f then
			local exec, name = nil, nil
			for line in f:lines() do
				if not exec then
					exec = line:match("^Exec=(.+)")
				end
				if not name then
					name = line:match("^Name=(.+)")
				end
				if exec and name then
					break
				end
			end
			f:close()
			if exec then
				local prog = exec:match("^%S+")
				local prog_base = prog and prog:match("([^/]+)$")
				if prog_base == binary then
					found = name
					break
				end
			end
		end
	end
	desktop_name_cache[binary] = found or false
	return found
end

-- ── per-app volume (pactl sink-inputs) ──────────────────────────────────────
-- One entry per currently-playing audio stream (roughly: one per app that's
-- actively making sound right now — an app with nothing playing won't have
-- a sink-input and won't show up, same as most GUI per-app mixers).
function M.list_app_volumes()
	if not have_pactl() then
		return nil, "pactl not found"
	end
	local out, ok = shell("pactl list sink-inputs")
	if not ok or not out then
		return nil, "pactl list sink-inputs failed"
	end
	local apps = {}
	local cur, in_props = nil, false
	local function finalize(item)
		if not item then
			return
		end
		-- name preference: what the app self-reports, then a proper .desktop
		-- Name= looked up by its binary (fuzzel-style), then the raw binary,
		-- then the stream's media title, and only then a plain "Unknown app".
		local nice = item.app_name
		if not nice or nice == "" then
			nice = desktop_name_for(item.binary)
		end
		if not nice or nice == "" then
			nice = item.binary
		end
		if not nice or nice == "" then
			nice = item.media_name
		end
		item.name = nice or "Unknown app"
		apps[#apps + 1] = item
	end
	for line in (out .. "\n"):gmatch("(.-)\n") do
		local id = line:match("^Sink Input #(%d+)")
		if id then
			finalize(cur)
			cur = { id = id, vol = 100, muted = false }
			in_props = false
		elseif cur then
			local muted = line:match("^%s*Mute:%s*(%a+)")
			if muted then
				cur.muted = (muted == "yes")
			end
			local vol = line:match("/%s*(%d+)%%")
			if vol and not cur._vol_set then
				cur.vol = tonumber(vol)
				cur._vol_set = true
			end
			if line:match("^%s*Properties:%s*$") then
				in_props = true
			elseif in_props then
				local appname = line:match('application%.name = "(.-)"')
				if appname then
					cur.app_name = appname
				end
				local binary = line:match('application%.process%.binary = "(.-)"')
				if binary then
					cur.binary = binary
				end
				local mediaName = line:match('media%.name = "(.-)"')
				if mediaName then
					cur.media_name = mediaName
				end
			end
		end
	end
	finalize(cur)
	return apps, nil
end

function M.set_app_volume(id, pct)
	if not have_pactl() then
		return false, "pactl not found"
	end
	pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
	local _, ok = shell(("pactl set-sink-input-volume %s %d%%"):format(id, pct))
	if ok then
		return true, nil
	end
	return false, "set-sink-input-volume failed"
end

function M.set_app_mute(id, muted)
	if not have_pactl() then
		return false, "pactl not found"
	end
	local arg = muted and "1" or "0"
	local _, ok = shell(("pactl set-sink-input-mute %s %s"):format(id, arg))
	if ok then
		return true, nil
	end
	return false, "set-sink-input-mute failed"
end

-- ── server info (read-only) ─────────────────────────────────────────────────

-- PipeWire (or PulseAudio) server version. Tries wpctl --version first, then
-- pactl info. Returns a string like "PipeWire 1.4.11" or nil.
function M.server_version()
	if have_wpctl() then
		local out = shell("wpctl --version")
		if out then
			-- output looks like "wpctl version 1.4.11\nCompiled ... PipeWire 1.4.11"
			local pw = out:match("PipeWire%s+([%d%.]+)")
			if pw then
				return "PipeWire " .. pw
			end
			local v = out:match("version%s+([%d%.]+)")
			if v then
				return "PipeWire " .. v
			end
		end
	end
	if have_pactl() then
		local out = shell("pactl info")
		if out then
			-- "Server Name: PulseAudio (on PipeWire 1.4.11)" or ".../ PipeWire ..."
			local pw = out:match("PipeWire%s+([%d%.]+)")
			if pw then
				return "PipeWire " .. pw
			end
			local sv = out:match("Server Version:%s*([^\n]+)")
			if sv then
				return sv:gsub("%s+$", "")
			end
		end
	end
	return nil
end

-- Current default sample rate, in Hz. Reads pactl info's "Default Sample
-- Specification" (e.g. "s32le 2ch 48000Hz") and extracts the rate. Returns a
-- string like "48000 Hz" or nil.
function M.sample_rate()
	if have_pactl() then
		local out = shell("pactl info")
		if out then
			local rate = out:match("Default Sample Specification:.-(%d+)Hz")
			if rate then
				return rate .. " Hz"
			end
		end
	end
	-- fallback: pw-metadata default clock rate
	local pw = shell("pw-metadata -n settings 0 2>/dev/null")
	if pw then
		local rate = pw:match("clock%.rate.-value:'?(%d+)")
		if rate then
			return rate .. " Hz"
		end
	end
	return nil
end

-- ── event-driven monitor (pactl subscribe) ──────────────────────────────────
-- Instead of re-running every query on every UI frame, we hold ONE long-lived
-- `pactl subscribe` open in the background. It emits a line whenever anything
-- audio-related changes. We can't do a non-blocking read on a popen pipe in
-- pure Lua, so the stream is redirected to a temp file and the UI tails that
-- file each frame (reading a file never blocks — it returns EOF when idle).
--
-- Each event line is classified and sets a "dirty" flag for just the slice it
-- affects. The frontend re-fetches only dirty slices, then clears them; clean
-- slices are served from the last cached value. This reproduces Cinnamon's
-- read-cached-state / event-driven backend using tools already in the stack.

local monitor = {
	started = false,
	path = nil,
	fh = nil,
	pos = 0,
	pid_path = nil,
	dirty = { volume = true, mute = true, devices = true, apps = true },
}

-- Start the background subscribe stream. Safe to call repeatedly (no-op once
-- running). Everything starts dirty so the first frame does a full read.
function M.monitor_start()
	if monitor.started then
		return true
	end
	if not have_pactl() then
		return false, "pactl not found"
	end
	-- seed once so repeated opens get distinct temp paths
	if not M._seeded then
		math.randomseed(os.time() + (tonumber(tostring({}):match("0x(%x+)"), 16) or 0))
		M._seeded = true
	end
	-- unique temp path for this session
	local base = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
	local stamp = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
	monitor.path = base .. "/tui_sound_sub_" .. stamp .. ".log"
	monitor.pid_path = monitor.path .. ".pid"
	-- launch pactl subscribe in the background, recording its PID so we can
	-- kill it on stop. Fully detach stdin/stdout/stderr and background so
	-- os.execute returns immediately and never blocks the UI on launch.
	-- Paths are plain (timestamp + digits, no spaces/special chars).
	local log = monitor.path
	local pidf = monitor.pid_path
	local cmd = "{ pactl subscribe > '"
		.. log
		.. "' 2>/dev/null & echo $! > '"
		.. pidf
		.. "' ; } </dev/null >/dev/null 2>&1 &"
	local ok = pcall(os.execute, cmd)
	if not ok then
		-- spawning failed for any reason: fall back to polling mode cleanly
		monitor.started = false
		return false, "monitor spawn failed"
	end
	monitor.pos = 0
	monitor.started = true
	-- first frame: read everything once
	monitor.dirty = { volume = true, mute = true, devices = true, apps = true }
	return true
end

-- Stop the stream and clean up the temp files. Called on category exit.
function M.monitor_stop()
	if not monitor.started then
		return
	end
	-- kill the background pactl subscribe
	local pf = monitor.pid_path and io.open(monitor.pid_path, "r")
	if pf then
		local pid = pf:read("*l")
		pf:close()
		if pid and pid:match("^%d+$") then
			os.execute("kill " .. pid .. " 2>/dev/null")
		end
	end
	if monitor.path then
		os.remove(monitor.path)
	end
	if monitor.pid_path then
		os.remove(monitor.pid_path)
	end
	monitor.started = false
	monitor.path, monitor.pid_path, monitor.pos = nil, nil, 0
end

-- Classify one subscribe line into which cache slice it dirties.
-- Lines look like: "Event 'change' on sink #59"
--                  "Event 'new' on sink-input #123"
--                  "Event 'change' on server"
local function classify(line)
	local obj = line:match("on%s+([%w%-]+)")
	if not obj then
		return
	end
	if obj == "sink-input" then
		monitor.dirty.apps = true
	elseif obj == "sink" then
		-- a sink event can mean volume, mute, or port/inventory changed;
		-- mark all sink-derived slices dirty to be safe (cheap re-reads)
		monitor.dirty.volume = true
		monitor.dirty.mute = true
		monitor.dirty.devices = true
	elseif obj == "source" then
		monitor.dirty.volume = true
		monitor.dirty.mute = true
		monitor.dirty.devices = true
	elseif obj == "server" then
		-- default device changed
		monitor.dirty.devices = true
		monitor.dirty.volume = true
		monitor.dirty.mute = true
	elseif obj == "card" then
		monitor.dirty.devices = true
	end
end

-- Drain any new event lines from the stream file and update dirty flags.
-- Returns true if anything at all changed since last poll. Non-blocking.
-- Reopens the file each poll: a read handle cached from monitor_start won't
-- reliably see bytes appended by the separate `pactl subscribe` process, so
-- we open fresh, seek to our last position, and read the tail.
function M.monitor_poll()
	if not monitor.started or not monitor.path then
		return false
	end
	local fh = io.open(monitor.path, "r")
	if not fh then
		return false
	end
	fh:seek("set", monitor.pos)
	local chunk = fh:read("*a")
	fh:close()
	if not chunk or chunk == "" then
		return false
	end
	monitor.pos = monitor.pos + #chunk
	local any = false
	for line in chunk:gmatch("[^\n]+") do
		classify(line)
		any = true
	end
	return any
end

-- Query helpers used by the frontend cache. Each returns the slice's data and
-- whether it was actually re-fetched (dirty) this frame.
function M.monitor_dirty(slice)
	if not monitor.started then
		return true -- no monitor: always treat as dirty (fall back to polling)
	end
	return monitor.dirty[slice] == true
end

function M.monitor_clear(slice)
	monitor.dirty[slice] = false
end

M.monitor_available = function()
	return monitor.started
end

-- ── maintenance ─────────────────────────────────────────────────────────────

-- Restart the user's PipeWire stack (pipewire, pipewire-pulse, wireplumber).
-- These are user services, so no root is needed — runs via `systemctl --user`.
-- Briefly interrupts audio. Returns ok, err.
function M.restart_pipewire()
	-- restart all three together; --user means the caller's session bus.
	local _, ok = shell("systemctl --user restart pipewire pipewire-pulse wireplumber")
	if ok then
		return true, nil
	end
	return false, "restart failed"
end

return M
