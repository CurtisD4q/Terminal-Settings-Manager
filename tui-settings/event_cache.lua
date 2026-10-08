-- event_cache.lua — reusable event-driven cache, generalized from the Sound
-- category's pactl-subscribe pattern. A category creates one of these, tells
-- it which "slices" of data it has and how to (re)fetch each, and optionally
-- attaches a background event stream (like `udevadm monitor`) that marks
-- slices dirty when the outside world changes.
--
-- The draw loop calls poll() on idle ticks (via the category's poll_events
-- hook); poll() drains the stream and returns true if anything changed, so
-- core redraws. On redraw, get(slice) returns the cached value, re-fetching
-- only if that slice is dirty. Categories with no real event source simply
-- call mark_all_dirty() from a manual "Refresh" button.
--
-- Nothing here is specific to any one category: the fetchers and the stream
-- command are supplied by the caller.

local EventCache = {}
EventCache.__index = EventCache

local function shell(cmd)
	local f = io.popen(cmd .. " 2>/dev/null")
	if not f then
		return nil
	end
	local out = f:read("*a")
	f:close()
	return out
end

-- Create a new cache.
--   opts.fetchers  = { slice_name = function() return value end, ... }
--   opts.stream    = optional shell command producing a line per event
--   opts.classify  = optional function(line) -> slice_name or nil
--                    (which slice a given event line dirties; nil = all)
-- All slices start dirty so the first get() fetches fresh.
function EventCache.new(opts)
	local self = setmetatable({}, EventCache)
	self.fetchers = opts.fetchers or {}
	self.values = {}
	self.dirty = {}
	for name in pairs(self.fetchers) do
		self.dirty[name] = true
	end
	self.stream_cmd = opts.stream
	self.classify = opts.classify
	self.stream = nil -- { path, pos, pid_path }
	self.started = false
	return self
end

-- Start the background event stream, if one was configured. Idempotent.
-- Redirects the stream command to a temp file the draw loop tails (a file read
-- never blocks — the pure-Lua way to poll a stream without threads).
function EventCache:start()
	if self.started then
		return true
	end
	self.started = true
	if not self.stream_cmd then
		return true -- no stream: manual-refresh mode
	end
	local base = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
	if not self._seeded then
		math.randomseed(os.time() + (tonumber(tostring({}):match("0x(%x+)"), 16) or 0))
		self._seeded = true
	end
	local stamp = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
	local path = base .. "/tui_evcache_" .. stamp .. ".log"
	local pid_path = path .. ".pid"
	-- launch detached so os.execute returns immediately; record PID to kill later
	local cmd = "{ "
		.. self.stream_cmd
		.. " > '"
		.. path
		.. "' 2>/dev/null & echo $! > '"
		.. pid_path
		.. "' ; } </dev/null >/dev/null 2>&1 &"
	pcall(os.execute, cmd)
	self.stream = { path = path, pos = 0, pid_path = pid_path }
	return true
end

-- Stop and clean up the stream. Safe to call if never started.
function EventCache:stop()
	if not self.started then
		return
	end
	self.started = false
	local s = self.stream
	if not s then
		return
	end
	local pf = s.pid_path and io.open(s.pid_path, "r")
	if pf then
		local pid = pf:read("*l")
		pf:close()
		if pid and pid:match("^%d+$") then
			os.execute("kill " .. pid .. " 2>/dev/null")
		end
	end
	if s.path then
		os.remove(s.path)
	end
	if s.pid_path then
		os.remove(s.pid_path)
	end
	self.stream = nil
end

-- Drain any new event lines and mark affected slices dirty. Non-blocking.
-- Returns true if at least one event arrived. Reopens the file each call so
-- appends by the separate stream process are always visible.
function EventCache:poll()
	local s = self.stream
	if not s then
		return false
	end
	local fh = io.open(s.path, "r")
	if not fh then
		return false
	end
	fh:seek("set", s.pos)
	local chunk = fh:read("*a")
	fh:close()
	if not chunk or chunk == "" then
		return false
	end
	s.pos = s.pos + #chunk
	local any = false
	for line in chunk:gmatch("[^\n]+") do
		any = true
		local slice = self.classify and self.classify(line) or nil
		if slice then
			self.dirty[slice] = true
		else
			-- no classifier, or classifier returned nil: dirty everything
			for name in pairs(self.fetchers) do
				self.dirty[name] = true
			end
		end
	end
	return any
end

-- Get a slice's value, re-fetching only if dirty. Cheap when clean.
function EventCache:get(slice)
	if self.dirty[slice] or self.values[slice] == nil then
		local fn = self.fetchers[slice]
		if fn then
			local ok, v = pcall(fn)
			self.values[slice] = ok and v or nil
		end
		self.dirty[slice] = false
	end
	return self.values[slice]
end

-- Force a slice (or all slices) to re-fetch on next get(). Used by manual
-- "Refresh" buttons in categories that have no real event source.
function EventCache:mark_dirty(slice)
	if slice then
		self.dirty[slice] = true
	else
		for name in pairs(self.fetchers) do
			self.dirty[name] = true
		end
	end
end

function EventCache:mark_all_dirty()
	self:mark_dirty(nil)
end

return EventCache
