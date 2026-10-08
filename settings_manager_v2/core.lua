-- core.lua — shared runtime for the settings apps (C1, flash-free).
local M = {}
local app_title = "Settings"
function M.set_app_title(t)
	app_title = t or "Settings"
end

local ESC = "\27["
local function sgr(...)
	return ESC .. table.concat({ ... }, ";") .. "m"
end
local RESET = ESC .. "0m"
-- The colour palette is built from the selected theme (theme.lua) rather than
-- hardcoded, so the app can be recoloured (default purple, terminal-inherited,
-- named presets, or custom RGB from config). Falls back to the built-in purple
-- if theme loading fails for any reason, so colour is never broken.
-- The built-in default palette (the original purple). This is the guaranteed
-- fallback: if theme.lua is missing, empty, broken, returns a non-table, lacks
-- palette(), errors when called, or yields an incomplete palette, the app uses
-- this and colour is never broken.
local DEFAULT_PALETTE = {
	accent = sgr(38, 5, 141),
	bright = sgr(38, 5, 183),
	text = sgr(38, 5, 253),
	muted = sgr(38, 5, 245),
	on = sgr(38, 5, 114),
	amber = sgr(38, 5, 214),
	selbg = sgr(48, 5, 237),
	bold = sgr(1),
	dim = sgr(2),
}

-- The colour roles every usable palette must contain. A palette missing any of
-- these is treated as broken and rejected in favour of the default.
local REQUIRED_ROLES = { "accent", "bright", "text", "muted", "on", "amber", "selbg", "bold", "dim" }

local function palette_is_complete(p)
	if type(p) ~= "table" then
		return false
	end
	for _, role in ipairs(REQUIRED_ROLES) do
		if type(p[role]) ~= "string" then
			return false
		end
	end
	return true
end

-- Build M.C from the selected theme, falling back to DEFAULT_PALETTE on ANY
-- failure. Each step is guarded independently:
--   * require may error (missing) or return a non-table (empty file returns
--     `true`, a syntax error is caught by pcall)
--   * theme.palette may be absent or not a function
--   * calling it may error, or return something incomplete
local function load_palette()
	local ok, mod = pcall(require, "theme")
	if not ok or type(mod) ~= "table" then
		return DEFAULT_PALETTE
	end
	if type(mod.palette) ~= "function" then
		return DEFAULT_PALETTE
	end
	local pal_ok, pal = pcall(mod.palette)
	if not pal_ok or not palette_is_complete(pal) then
		return DEFAULT_PALETTE
	end
	return pal
end

M.C = load_palette()
M.ESC, M.RESET = ESC, RESET
local C = M.C
local function move(r, c)
	return ESC .. r .. ";" .. c .. "H"
end
M.move = move
local out = io.write
M.out = out

-- ── terminal ownership: enter/leave the alt screen ONCE per process ─────────
local saved_stty
local screen_active = false
function M.screen_enter()
	if screen_active then
		return
	end
	saved_stty = io.popen("stty -g 2>/dev/null"):read("*l")
	os.execute("stty raw -echo min 0 time 1 2>/dev/null")
	out(ESC .. "?1049h")
	out(ESC .. "?25l")
	-- mouse: 1000 = button press/release, 1006 = SGR extended coords
	out(ESC .. "?1000h")
	out(ESC .. "?1006h")
	screen_active = true
end
function M.screen_leave()
	if not screen_active then
		return
	end
	out(ESC .. "?1000l")
	out(ESC .. "?1006l") -- disable mouse first
	out(ESC .. "?25h")
	out(ESC .. "?1049l")
	if saved_stty then
		os.execute("stty " .. saved_stty .. " 2>/dev/null")
	else
		os.execute("stty sane 2>/dev/null")
	end
	screen_active = false
end

function M.termsize()
	local s = io.popen("stty size 2>/dev/null"):read("*l")
	if s then
		local h, w = s:match("(%d+)%s+(%d+)")
		if h then
			return tonumber(h), tonumber(w)
		end
	end
	return 24, 80
end

function M.readkey()
	local c = io.read(1)
	if not c or c == "" then
		return nil
	end
	if c == "\27" then
		local a = io.read(1)
		if a == "[" then
			local b = io.read(1)
			if b == "A" then
				return "up"
			elseif b == "B" then
				return "down"
			elseif b == "C" then
				return "right"
			elseif b == "D" then
				return "left"
			elseif b == "<" then
				-- SGR mouse: \27[<btn;col;rowM  (M=press, m=release)
				local s = ""
				while true do
					local ch = io.read(1)
					if not ch or ch == "" then
						break
					end
					if ch == "M" or ch == "m" then
						local btn, col, row = s:match("^(%d+);(%d+);(%d+)$")
						if btn then
							local n = tonumber(btn)
							-- Only report PRESS events (M). Ignore releases (m) so actions
							-- fire once. Expose the button so callers can tell a left-click
							-- (0) from wheel-up (64) / wheel-down (65).
							if ch == "M" then
								return {
									mouse = true,
									btn = n,
									col = tonumber(col),
									row = tonumber(row),
									wheel_up = (n == 64),
									wheel_down = (n == 65),
									click = (n == 0),
								}
							end
							return nil
						end
						return nil
					end
					s = s .. ch
				end
				return nil
			end
			return "esc"
		elseif a == "O" then
			local b = io.read(1)
			if b == "A" then
				return "up"
			elseif b == "B" then
				return "down"
			elseif b == "C" then
				return "right"
			elseif b == "D" then
				return "left"
			end
			return "esc"
		end
		return "esc"
	end
	return c
end

local function vlen(s)
	local _, n = s:gsub("[^\128-\191]", "")
	return n
end
M.vlen = vlen

-- ── category screen ────────────────────────────────────────────────────────
-- Runs one category's settings screen. Returns:
--   "home" when the user pressed b/Esc
--   "quit" when the user pressed q
-- Does NOT enter/leave the alt screen — the caller owns that.
local function flatten(cat)
	local items = {}
	for _, sec in ipairs(cat.sections) do
		items[#items + 1] = { kind = "section", name = sec[1] }
		for _, r in ipairs(sec[2]) do
			items[#items + 1] = { kind = "row", label = r[1], value = r[2], wtype = r[3], backend = r[4] }
		end
	end
	return items
end
local function selectable(items)
	local idx = {}
	for i, it in ipairs(items) do
		if it.kind == "row" then
			idx[#idx + 1] = i
		end
	end
	return idx
end

-- ── password prompt screen ──────────────────────────────────────────────────
-- A masked text-entry screen. Returns the entered string on Enter, or nil if
-- the user cancels with Esc. Caller owns the alt-screen (already entered).

-- ── loading animation ────────────────────────────────────────────────────────
-- Shows a bouncing-block progress bar centered on the bottom row of the
-- current screen while a category is loading. Animates for a fixed number
-- of frames then returns — the category opens immediately after.
-- cat = { icon=, label= }

-- ── privilege escalation via pkexec ──────────────────────────────────────────
-- Runs a command with administrator rights through pkexec. pkexec triggers the
-- system polkit authentication agent (e.g. lxpolkit), which renders its OWN
-- password dialog outside this TUI — so we never handle the password ourselves
-- (more secure). We just show a brief notice, run the command, and report the
-- result. Returns true on success, or false plus a message.
--   cmd  : the command string to run as root (already fully constructed)
--   desc : human-readable description of what it does (shown to the user)

-- ── confirmation screen ──────────────────────────────────────────────────────
-- A reusable "are you sure?" screen for destructive actions. Returns true only
-- if the user explicitly confirms. Default focus is on "No" for safety. To
-- confirm, the user must move to Yes and press Enter, or press 'y'.
--   title   : short heading (e.g. "Delete user 'bob'?")
--   warning : one or more lines describing the consequence

-- Scrollable single-select list dialog. `items` is a list of { label, value }
-- (or plain strings). Returns the chosen item's value (or the string), or nil on
-- cancel. Supports arrow/j-k navigation, type-to-filter, Enter to pick, Esc to
-- cancel. Used for choosing a default application from many installed apps.

function M.run_category(cat)
	local state = { row = 1, scroll = 0, toggles = {}, sliders = {}, last_good = {} }
	-- capability check: if this category can't function on this system, we show
	-- a banner explaining why (drawn from env detection) rather than letting the
	-- rows silently read as empty/unavailable. Computed once; cheap and cached.
	local cap_reason = nil
	do
		local ok, cap = pcall(require, "capability")
		if ok and cat.id then
			local supported, reason = cap.check(cat.id)
			if not supported then
				cap_reason = reason
			end
		end
	end
	for _, sec in ipairs(cat.sections) do
		for _, r in ipairs(sec[2]) do
			if r[3] == "toggle" then
				state.toggles[r[1]] = true
			elseif r[3] == "slider" then
				state.sliders[r[1]] = math.min(100, tonumber(r[2]:match("%d+")) or 50)
			end
		end
	end

	-- backend cache: refreshed once per draw (not once per row) so a category
	-- with several live rows sharing one device only queries it once per frame.
	local cache = {}
	local function refresh_cache()
		if cat.prefetch then
			local ok, err = pcall(cat.prefetch, cache)
			if not ok then
				cache._error = tostring(err)
			end
		end
	end

	local function widget(it)
		local k = it.label
		if it.backend then
			local ok, val, err = pcall(it.backend.get, cache)
			if not ok then
				val, err = nil, tostring(val)
			end
			if val == nil and state.last_good[k] ~= nil then
				-- transient hiccup (e.g. hardware briefly reinitializing after a
				-- device/port switch) — keep showing the last real value instead of
				-- flashing an error for something that self-corrects a moment later
				val = state.last_good[k]
			elseif val ~= nil then
				state.last_good[k] = val
			end
			if val == nil then
				return C.amber .. "  " .. (err and err:sub(1, 14) or "unavailable") .. RESET
			end
			if it.wtype == "toggle" then
				if val then
					return C.on .. "● ON " .. RESET
				else
					return C.muted .. "  OFF" .. RESET
				end
			elseif it.wtype == "slider" then
				local v = math.max(0, math.min(100, val))
				local w = 12
				local fill = math.floor(v / 100 * w)
				return C.accent
					.. string.rep("━", fill)
					.. "●"
					.. C.dim
					.. string.rep("─", w - fill)
					.. RESET
					.. C.muted
					.. (" %d%%"):format(math.floor(v))
					.. RESET
			elseif it.wtype == "choice" then
				return C.text .. "‹ " .. tostring(val) .. " ›" .. RESET
			else
				return C.muted .. tostring(val) .. RESET
			end
		end
		if it.wtype == "toggle" then
			if state.toggles[k] then
				return C.on .. "● ON " .. RESET
			else
				return C.muted .. "  OFF" .. RESET
			end
		elseif it.wtype == "slider" then
			local v = state.sliders[k] or 0
			local w = 12
			local fill = math.floor(v / 100 * w)
			return C.accent
				.. string.rep("━", fill)
				.. "●"
				.. C.dim
				.. string.rep("─", w - fill)
				.. RESET
				.. C.muted
				.. (" %d%%"):format(math.floor(v))
				.. RESET
		elseif it.wtype == "button" then
			return C.accent .. "[ Open ]" .. RESET
		else
			return C.muted .. it.value .. RESET
		end
	end

	local function draw(h, w)
		refresh_cache()
		state.hit = {} -- screen-row -> {idx=item, sx0=slidertrackstart, sw=trackwidth}
		local buf = {}
		local function put(r, c, s)
			buf[#buf + 1] = move(r, c) .. s
		end
		buf[#buf + 1] = ESC .. "2J"
		if w < 50 or h < 8 then
			put(1, 1, C.amber .. "Terminal too small" .. RESET)
			put(2, 1, C.muted .. ("need 50x8, have %dx%d"):format(w, h) .. RESET)
			out(table.concat(buf))
			io.flush()
			return
		end
		-- title: normal-size text, bold + accent (purple), at the top
		put(1, 2, C.accent .. C.bold .. cat.icon .. " " .. cat.label .. RESET)
		put(1, w - #app_title - 2, C.muted .. app_title .. RESET)
		-- capability banner: if this category isn't supported on this system,
		-- say so plainly at the top with the detected reason, so the rows below
		-- (which will read as empty/unavailable) are explained rather than
		-- looking broken.
		if cap_reason then
			local msg = "⚠ Not available: " .. cap_reason
			put(2, 2, C.amber .. msg:sub(1, math.max(0, w - 4)) .. RESET)
		end
		local items = flatten(cat)
		local sel = selectable(items)
		local sel_item = sel[state.row] or sel[1]
		local cx = 3
		local top = 3
		local avail = h - top - 1
		if sel_item then
			if sel_item - state.scroll > avail - 1 then
				state.scroll = sel_item - avail + 1
			end
			if sel_item - state.scroll < 1 then
				state.scroll = sel_item - 1
			end
		end
		if state.scroll < 0 then
			state.scroll = 0
		end
		for i, it in ipairs(items) do
			local r = i - state.scroll + top - 1
			if r >= top and r <= top + avail - 1 then
				if it.kind == "section" then
					put(r, cx, C.accent .. C.bold .. "┄ " .. it.name .. RESET)
				else
					local selected = (i == sel_item)
					local wt = widget(it)
					local wv = vlen((wt:gsub("\27%[[%d;]*m", "")))
					local wx = w - wv - 1
					if wx < cx + 24 then
						wx = cx + 24
					end
					-- record this screen row for click hit-testing
					local entry = { idx = i }
					if it.wtype == "slider" then
						-- track is the 12-cell bar starting at wx (before the " NN%" suffix)
						entry.sx0 = wx
						entry.sw = 12
					end
					state.hit[r] = entry
					if selected then
						put(r, cx - 1, C.selbg .. string.rep(" ", w - cx) .. RESET)
						put(r, cx, C.selbg .. C.accent .. C.bold .. "▸ " .. C.bright .. it.label .. RESET)
						put(r, wx, C.selbg .. wt .. RESET)
					else
						put(r, cx + 2, C.text .. it.label .. RESET)
						put(r, wx, wt)
					end
				end
			end
		end
		-- scrollbar (right edge): shown only when content exceeds the viewport.
		-- track = dim, thumb = accent, sized/positioned from scroll state.
		local total = #items
		state.sb = nil
		if total > avail then
			local sbx = w -- rightmost column
			local thumb = math.max(1, math.floor(avail * avail / total + 0.5))
			local maxoff = total - avail
			local maxtop = avail - thumb
			local tpos = maxoff > 0 and math.floor(state.scroll / maxoff * maxtop + 0.5) or 0
			-- remember geometry so a click on the bar can jump the scroll
			state.sb = { col = sbx, top = top, rows = avail, maxoff = maxoff }
			for k = 0, avail - 1 do
				local glyph, col = "│", C.dim
				if k >= tpos and k < tpos + thumb then
					glyph, col = "█", C.accent
				end
				put(top + k, sbx, col .. glyph .. RESET)
			end
		end
		local keys = " ↑↓ move   ←→/Space change   b home   q quit "
		put(h, 1, C.dim .. string.rep(" ", w) .. RESET)
		put(h, w - vlen(keys), C.muted .. keys .. RESET)
		out(table.concat(buf))
		io.flush()
	end

	local function items_now()
		return flatten(cat)
	end
	local function clamp()
		local n = #selectable(items_now())
		if state.row < 1 then
			state.row = 1
		end
		if state.row > n then
			state.row = n
		end
	end
	local function change(dir)
		local it = items_now()[selectable(items_now())[state.row]]
		if not it then
			return
		end
		if it.backend then
			if it.wtype == "toggle" then
				local ok, cur = pcall(it.backend.get, cache)
				local newval
				if dir == 0 then
					newval = not (ok and cur)
				else
					newval = (dir > 0)
				end
				pcall(it.backend.set, newval, cache)
			elseif it.wtype == "slider" then
				local ok, cur = pcall(it.backend.get, cache)
				cur = (ok and cur) or 0
				local newval = math.max(0, math.min(100, cur + dir * 5))
				pcall(it.backend.set, newval, cache)
			elseif it.wtype == "choice" then
				-- Pass the raw direction: -1/+1 for left/right (preview/cycle), 0 for
				-- Space/Enter (apply/commit). Backends that separate previewing from
				-- applying (e.g. root actions behind pkexec) rely on this distinction.
				pcall(it.backend.set, dir, cache)
			elseif it.wtype == "button" then
				-- action button: Space/Enter fires it (ignore left/right)
				if dir == 0 then
					pcall(it.backend.set, 0, cache)
				end
			end
			return
		end
		local k = it.label
		if it.wtype == "toggle" then
			state.toggles[k] = (dir == 0) and not state.toggles[k] or (dir > 0)
		elseif it.wtype == "slider" then
			state.sliders[k] = math.max(0, math.min(100, (state.sliders[k] or 0) + dir * 5))
		end
	end

	local h, w = M.termsize()
	draw(h, w)
	local sc = 0
	local function sel_index_of(item_idx)
		local items = items_now()
		local n = 0
		for i = 1, item_idx do
			if items[i] and items[i].kind == "row" then
				n = n + 1
			end
		end
		return n
	end
	while true do
		local k = M.readkey()
		local dirty = false
		if k == nil then
			sc = sc + 1
			if sc >= 2 then
				sc = 0
				local nh, nw = M.termsize()
				if nh ~= h or nw ~= w then
					h, w = nh, nw
					dirty = true
				end
			end
			if cat.poll_events then
				local ok, changed = pcall(cat.poll_events)
				if ok and changed then
					dirty = true
				end
			end
		elseif type(k) == "table" and k.mouse and (k.wheel_up or k.wheel_down) then
			-- wheel scrolls the selection like up/down arrows
			local items = items_now()
			local sel = selectable(items)
			if k.wheel_up and state.row > 1 then
				state.row = state.row - 1
				dirty = true
			end
			if k.wheel_down and state.row < #sel then
				state.row = state.row + 1
				dirty = true
			end
		elseif type(k) == "table" and k.mouse and k.click then
			-- 1) click on the scrollbar column -> jump scroll to that position
			local sb = state.sb
			if sb and k.col == sb.col and k.row >= sb.top and k.row <= sb.top + sb.rows - 1 then
				local frac = (k.row - sb.top) / math.max(1, sb.rows - 1)
				state.scroll = math.floor(frac * sb.maxoff + 0.5)
				if state.scroll < 0 then
					state.scroll = 0
				end
				if state.scroll > sb.maxoff then
					state.scroll = sb.maxoff
				end
				-- keep the selected row within the new viewport
				local items = items_now()
				local sel = selectable(items)
				local first_vis, last_vis = state.scroll + 1, state.scroll + sb.rows
				local cur = sel[state.row]
				if cur then
					if cur < first_vis or cur > last_vis then
						-- move selection to the first selectable row now visible
						for si, ii in ipairs(sel) do
							if ii >= first_vis and ii <= last_vis then
								state.row = si
								break
							end
						end
					end
				end
				dirty = true
			else
				-- 2) click on a content row (focus + slider-set as before)
				local entry = state.hit and state.hit[k.row]
				if entry then
					local si = sel_index_of(entry.idx)
					if si >= 1 then
						state.row = si
						dirty = true
					end
					if entry.sx0 then
						local rel = k.col - entry.sx0
						if rel < 0 then
							rel = 0
						end
						if rel > entry.sw - 1 then
							rel = entry.sw - 1
						end
						local v = math.floor(rel / (entry.sw - 1) * 100 + 0.5)
						local it = items_now()[entry.idx]
						if it then
							if it.backend then
								pcall(it.backend.set, v, cache)
							else
								state.sliders[it.label] = v
							end
						end
						dirty = true
					end
				end
			end
		elseif k == "up" or k == "k" then
			state.row = state.row - 1
			clamp()
			dirty = true
		elseif k == "down" or k == "j" then
			state.row = state.row + 1
			clamp()
			dirty = true
		elseif k == "right" or k == "l" then
			change(1)
			dirty = true
		elseif k == "left" or k == "h" then
			change(-1)
			dirty = true
		elseif k == " " or k == "\r" or k == "\n" then
			change(0)
			dirty = true
		elseif k == "b" or k == "esc" then
			return "home"
		elseif k == "q" then
			return "quit"
		end
		if dirty then
			draw(h, w)
		end
	end
end

-- ── home grid screen ───────────────────────────────────────────────────────
-- Returns the selected category index to open, or nil to quit. Like the
-- category screen, it does not own the alt screen.
function M.run_home(categories, start_sel, title)
	title = title or "◈ Settings"
	local sel = start_sel or 1
	local scroll = 0 -- item scroll offset (in categories)
	local state_home_sb = nil
	local state_home_hit = nil
	local last_click_idx, last_click_time = nil, 0
	local BLOCK = 3 -- lines per category: name + 2 description lines

	-- wrap a string to two lines within width w2; returns {line1, line2}
	local function wrap2(s, w2)
		if not s or s == "" then
			return { "", "" }
		end
		if vlen(s) <= w2 then
			return { s, "" }
		end
		-- break at the last space within w2
		local cut = w2
		local head = s:sub(1, w2)
		local sp = head:match(".*()%s") -- position of last space
		if sp and sp > 1 then
			cut = sp - 1
		end
		local l1 = s:sub(1, cut):gsub("%s+$", "")
		local rest = s:sub(cut + 1):gsub("^%s+", "")
		if vlen(rest) > w2 then
			rest = rest:sub(1, w2 - 1) .. "…"
		end
		return { l1, rest }
	end

	local function draw(h, w)
		local buf = {}
		local function put(r, c, s)
			buf[#buf + 1] = move(r, c) .. s
		end
		buf[#buf + 1] = ESC .. "2J"
		if w < 40 or h < 10 then
			put(1, 1, C.amber .. "Terminal too small" .. RESET)
			put(2, 1, C.muted .. ("need 40x10, have %dx%d"):format(w, h) .. RESET)
			out(table.concat(buf))
			io.flush()
			return
		end
		put(1, 2, C.accent .. C.bold .. title .. RESET)
		put(1, w - 8, C.muted .. "Home" .. RESET)
		local top = 3
		local avail = h - top -- rows available for the list (leave last row for hints)
		local vis = math.max(1, math.floor(avail / BLOCK)) -- how many categories fit
		local n = #categories

		-- keep the selected category in view
		if sel < scroll + 1 then
			scroll = sel - 1
		end
		if sel > scroll + vis then
			scroll = sel - vis
		end
		if scroll < 0 then
			scroll = 0
		end
		local maxscroll = math.max(0, n - vis)
		if scroll > maxscroll then
			scroll = maxscroll
		end

		local textw = w - 6 -- text width for wrapping (indent + scrollbar margin)
		state_home_hit = {}
		for idx = scroll + 1, math.min(scroll + vis, n) do
			local cat = categories[idx]
			local row = idx - scroll - 1
			local y = top + row * BLOCK
			local selected = (idx == sel)
			local label = cat.icon .. " " .. cat.label
			if selected then
				put(y, 2, C.selbg .. string.rep(" ", w - 3) .. RESET) -- highlight the NAME line only
				put(y, 3, C.selbg .. C.accent .. C.bold .. "▸ " .. C.bright .. label .. RESET)
			else
				put(y, 3, C.text .. "  " .. label .. RESET)
			end
			-- description wrapped across the two lines below (always dim)
			local lines = wrap2(cat.desc or "", textw)
			if lines[1] ~= "" then
				put(y + 1, 5, C.dim .. lines[1] .. RESET)
			end
			if lines[2] ~= "" then
				put(y + 2, 5, C.dim .. lines[2] .. RESET)
			end
			-- clickable rows for this category: the name line and the two
			-- description lines (NOT the blank spacer at y+? — BLOCK includes a gap)
			state_home_hit[y] = idx
			state_home_hit[y + 1] = idx
			state_home_hit[y + 2] = idx
		end

		-- scrollbar (right edge) when the list overflows
		state_home_sb = nil
		if n > vis then
			local sbx = w
			local barrows = vis * BLOCK
			local thumb = math.max(1, math.floor(barrows * vis / n + 0.5))
			local maxtop = barrows - thumb
			local tpos = maxscroll > 0 and math.floor(scroll / maxscroll * maxtop + 0.5) or 0
			state_home_sb = { col = sbx, top = top, rows = barrows, maxoff = maxscroll, vis = vis }
			for k = 0, barrows - 1 do
				local glyph, col = "│", C.dim
				if k >= tpos and k < tpos + thumb then
					glyph, col = "█", C.accent
				end
				put(top + k, sbx, col .. glyph .. RESET)
			end
		end

		local keys = " ↑↓ move   ⏎ open   q quit "
		put(h, 1, C.dim .. string.rep(" ", w) .. RESET)
		put(h, w - vlen(keys), C.muted .. keys .. RESET)
		out(table.concat(buf))
		io.flush()
	end
	local h, w = M.termsize()
	draw(h, w)
	local sc = 0
	while true do
		local k = M.readkey()
		local dirty = false
		if k == nil then
			sc = sc + 1
			if sc >= 2 then
				sc = 0
				local nh, nw = M.termsize()
				if nh ~= h or nw ~= w then
					h, w = nh, nw
					dirty = true
				end
			end
		elseif type(k) == "table" and k.mouse and (k.wheel_up or k.wheel_down) then
			-- scroll wheel moves the selection like the arrow keys
			if k.wheel_up and sel > 1 then
				sel = sel - 1
				dirty = true
			end
			if k.wheel_down and sel < #categories then
				sel = sel + 1
				dirty = true
			end
		elseif type(k) == "table" and k.mouse and k.click then
			local sb = state_home_sb
			if sb and k.col == sb.col and k.row >= sb.top and k.row <= sb.top + sb.rows - 1 then
				-- click on scrollbar -> jump scroll to that position
				local frac = (k.row - sb.top) / math.max(1, sb.rows - 1)
				local target = math.floor(frac * sb.maxoff + 0.5)
				if target < 0 then
					target = 0
				end
				if target > sb.maxoff then
					target = sb.maxoff
				end
				scroll = target
				if sel < scroll + 1 then
					sel = scroll + 1
				end
				if sel > scroll + sb.vis then
					sel = scroll + sb.vis
				end
				dirty = true
			else
				-- click on a category row -> select; double-click same row -> open
				local idx = state_home_hit and state_home_hit[k.row]
				if idx then
					local now = os.clock()
					if idx == sel and last_click_idx == idx and (now - last_click_time) <= 0.45 then
						return sel -- double-click: open
					end
					sel = idx
					dirty = true
					last_click_idx = idx
					last_click_time = now
				end
			end
		elseif k == "up" or k == "k" then
			if sel > 1 then
				sel = sel - 1
				dirty = true
			end
		elseif k == "down" or k == "j" then
			if sel < #categories then
				sel = sel + 1
				dirty = true
			end
		elseif k == " " or k == "\r" or k == "\n" then
			return sel
		elseif k == "q" then
			return nil
		end
		if dirty then
			draw(h, w)
		end
	end
end

-- locate sibling files relative to a script path
function M.scriptdir(arg0)
	return arg0:match("^(.*)/[^/]*$") or "."
end

-- ── general text input ───────────────────────────────────────────────────────
-- Single-line text entry, shown as typed (unlike run_password_prompt, which
-- masks). For hostnames, URLs, and similar. Returns the entered string (may be
-- empty) on Enter, or nil on Esc. `initial` pre-fills the field for editing.

-- ── type-to-confirm ──────────────────────────────────────────────────────────
-- Higher-friction confirmation for irreversible actions: the user must type an
-- exact phrase (typically the device/resource name) before Enter will proceed.
-- Returns true only on an exact match plus Enter; false on Esc.

-- ── category definition helper ───────────────────────────────────────────────
-- Every category file ends with the same boilerplate: a module table, a run()
-- wrapper, and the standalone-vs-required bootstrap keyed on a package.loaded
-- sentinel. This helper collapses that into one call and defines the sentinel
-- in exactly ONE place, so a typo in a category file can't silently change the
-- app's exit behaviour.
--
-- Usage:
--   return core.define_category(CAT)
--   return core.define_category(CAT, { on_exit = function() cache:stop() end })
--
-- on_exit always runs after the category loop, even if it errored, so teardown
-- (event streams, background monitors) can never be skipped.
local SETTINGS_HOME_SENTINEL = "__settings_home__"

function M.define_category(cat, opts)
	opts = opts or {}
	local on_exit = opts.on_exit
	local Mod = { category = cat }

	function Mod.run()
		local ok, res = pcall(M.run_category, cat)
		if on_exit then
			pcall(on_exit)
		end
		if not ok then
			error(res)
		end
		return res
	end

	-- Required by a launcher: hand back the module.
	if package.loaded[SETTINGS_HOME_SENTINEL] then
		return Mod
	end

	-- Run directly: full standalone lifecycle.
	M.screen_enter()
	local ok, err = pcall(Mod.run)
	M.screen_leave()
	if not ok then
		io.stderr:write("error: " .. tostring(err) .. "\n")
		os.exit(1)
	end
	os.exit(0)
end

-- Attach the modal dialog screens (run_confirm, run_picker, run_text_input,
-- run_text_confirm, run_password_prompt, run_pkexec, run_loading). They live in
-- a separate file to keep this one focused on the render/loop engine, but are
-- attached onto M here so every caller (core.run_confirm, ...) is unchanged.
require("dialogs")(M)

return M
