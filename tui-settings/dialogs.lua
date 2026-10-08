-- dialogs.lua — modal dialog screens for Settings Menu.
--
-- Extracted from core.lua to keep that file focused on the render/loop engine.
-- These are the reusable full-screen modals: confirmations, pickers, text
-- entry, the password prompt, the pkexec privilege flow, and the loading
-- animation. They are attached onto the core module (M) so every existing
-- caller (core.run_confirm, core.run_picker, ...) keeps working unchanged.
--
-- Usage (from core.lua, after M is built):  require("dialogs")(M)
--
-- The dialogs use only the public core primitives — M.C, M.ESC, M.RESET,
-- M.move, M.out, M.termsize, M.readkey — so no private state crosses over.
return function(M)
	local C = M.C
	local ESC = M.ESC
	local RESET = M.RESET
	local move = M.move
	local out = M.out

	function M.run_password_prompt(title, subtitle)
		local pw = {}
		local reveal = false
		local function draw()
			local h, w = M.termsize()
			local buf = {}
			local function put(r, c, s)
				buf[#buf + 1] = move(r, c) .. s
			end
			buf[#buf + 1] = ESC .. "2J"
			put(1, 2, C.accent .. C.bold .. (title or "Password") .. RESET)
			if subtitle then
				put(2, 2, C.muted .. subtitle .. RESET)
			end
			local boxrow = 5
			put(boxrow, 2, C.text .. "Password:" .. RESET)
			local shown
			if reveal then
				shown = table.concat(pw)
			else
				shown = string.rep("*", #pw)
			end
			local field = shown
			if #field == 0 then
				field = C.dim .. "(type password)" .. RESET
			end
			put(boxrow, 12, C.bright .. field .. RESET)
			put(boxrow, 12 + (reveal and #table.concat(pw) or #pw), C.accent .. "_" .. RESET)
			put(
				h - 2,
				2,
				C.muted
					.. "Enter connect   Esc cancel   Tab "
					.. (reveal and "hide" or "reveal")
					.. " password"
					.. RESET
			)
			out(table.concat(buf))
			io.flush()
		end
		draw()
		while true do
			local k = M.readkey()
			if k == "esc" then
				return nil
			elseif type(k) == "string" and (k == "\r" or k == "\n") then
				return table.concat(pw)
			elseif type(k) == "string" and (k == "\127" or k == "\8") then
				if #pw > 0 then
					pw[#pw] = nil
					draw()
				end
			elseif type(k) == "string" and k == "\t" then
				reveal = not reveal
				draw()
			elseif type(k) == "string" and #k == 1 and k:byte() >= 32 then
				pw[#pw + 1] = k
				draw()
			end
		end
	end

	function M.run_loading(cat, h, w)
		if not h or not w then
			h, w = M.termsize()
		end
		local BAR = 24 -- total bar width inside brackets
		local BLOCK = 3 -- width of the bouncing solid block
		local FRAMES = 18 -- total frames to animate (~1.4s at 80ms each)
		local DELAY = 0.08 -- seconds per frame

		local label = (cat.icon or "") .. " " .. (cat.label or "")
		-- e.g.  "♪ Sound  [░░░███░░░░░░░░░░░░░░░░]"
		local function bar_frame(pos)
			-- pos = 0..(BAR-BLOCK), left edge of the block
			local s = {}
			for i = 0, BAR - 1 do
				if i >= pos and i < pos + BLOCK then
					s[#s + 1] = "█"
				else
					s[#s + 1] = "░"
				end
			end
			return "[" .. table.concat(s) .. "]"
		end

		-- bounce: 0 → BAR-BLOCK → 0 → ...
		local max_pos = BAR - BLOCK
		local function bounce_pos(frame)
			local cycle = max_pos * 2
			local t = frame % cycle
			if t <= max_pos then
				return t
			else
				return cycle - t
			end
		end

		local t0 = os.clock()
		for frame = 0, FRAMES - 1 do
			local bar = bar_frame(bounce_pos(frame))
			local line = label .. "  " .. bar
			-- center the line on the bottom row
			local pad = math.max(0, math.floor((w - #line) / 2))
			local row = h
			-- clear the bottom row and draw centered
			out(move(row, 1) .. C.dim .. string.rep(" ", w) .. RESET)
			out(move(row, pad + 1) .. C.accent .. label .. C.dim .. "  " .. bar .. RESET)
			io.flush()
			-- busy-wait for DELAY (Lua has no non-blocking sleep in standard lib)
			local t1 = os.clock() + DELAY
			while os.clock() < t1 do
			end
		end
		-- restore the bottom row to blank so the category screen draws cleanly
		out(move(h, 1) .. string.rep(" ", w))
		io.flush()
	end

	function M.run_pkexec(cmd, desc)
		local h, w = M.termsize()
		local buf = {}
		local function put(r, c, s)
			buf[#buf + 1] = move(r, c) .. s
		end
		buf[#buf + 1] = ESC .. "2J"
		put(2, 2, C.accent .. C.bold .. "Administrator access required" .. RESET)
		if desc then
			put(4, 2, C.text .. desc .. RESET)
		end
		put(6, 2, C.muted .. "A password prompt should appear. Authenticate to proceed." .. RESET)
		put(8, 2, C.dim .. "(working…)" .. RESET)
		out(table.concat(buf))
		io.flush()

		-- pkexec returns 126 if the user dismisses/fails auth, 127 if pkexec itself
		-- is missing, else the wrapped command's exit code.
		local full = "pkexec " .. cmd .. " >/dev/null 2>&1; echo $?"
		local f = io.popen(full)
		local code = f and tonumber((f:read("*a") or ""):match("%d+")) or nil
		if f then
			f:close()
		end

		if code == nil then
			return false, "could not run pkexec"
		end
		if code == 127 then
			return false, "pkexec not found"
		end
		if code == 126 then
			return false, "authentication cancelled or failed"
		end
		if code ~= 0 then
			return false, "command failed (exit " .. code .. ")"
		end
		return true, nil
	end

	function M.run_confirm(title, warning)
		local sel = 2 -- 1=Yes, 2=No; default No
		local function draw()
			local h, w = M.termsize()
			local buf = {}
			local function put(r, c, s)
				buf[#buf + 1] = move(r, c) .. s
			end
			buf[#buf + 1] = ESC .. "2J"
			put(2, 2, C.amber .. C.bold .. (title or "Are you sure?") .. RESET)
			local row = 4
			if warning then
				for line in (warning .. "\n"):gmatch("(.-)\n") do
					if line ~= "" then
						put(row, 2, C.text .. line .. RESET)
						row = row + 1
					end
				end
			end
			row = row + 1
			-- Yes / No buttons
			local yes = (sel == 1) and (C.selbg .. C.bright .. " Yes " .. RESET) or (C.muted .. " Yes " .. RESET)
			local no = (sel == 2) and (C.selbg .. C.bright .. " No " .. RESET) or (C.muted .. " No " .. RESET)
			put(row, 2, yes .. "   " .. no)
			put(row + 2, 2, C.dim .. "←/→ choose   Enter confirm   Esc cancel   (y/n)" .. RESET)
			out(table.concat(buf))
			io.flush()
		end
		draw()
		while true do
			local k = M.readkey()
			if k == "esc" or k == "n" or k == "N" then
				return false
			elseif k == "y" or k == "Y" then
				return true
			elseif k == "left" or k == "h" then
				sel = 1
				draw()
			elseif k == "right" or k == "l" then
				sel = 2
				draw()
			elseif k == "\r" or k == "\n" or k == " " then
				return (sel == 1)
			end
		end
	end

	function M.run_picker(title, items, subtitle)
		-- normalize items to { label=, value= }
		local all = {}
		for _, it in ipairs(items or {}) do
			if type(it) == "table" then
				all[#all + 1] = { label = it.label or tostring(it.value), value = it.value }
			else
				all[#all + 1] = { label = tostring(it), value = it }
			end
		end
		local filter = ""
		local sel = 1
		local top = 1

		local function filtered()
			if filter == "" then
				return all
			end
			local out_list = {}
			local needle = filter:lower()
			for _, it in ipairs(all) do
				if it.label:lower():find(needle, 1, true) then
					out_list[#out_list + 1] = it
				end
			end
			return out_list
		end

		local function draw()
			local h, w = M.termsize()
			local view = filtered()
			if sel > #view then
				sel = #view
			end
			if sel < 1 then
				sel = 1
			end
			-- visible window of rows
			local list_top = 4
			local list_h = h - list_top - 2
			if sel < top then
				top = sel
			end
			if sel > top + list_h - 1 then
				top = sel - list_h + 1
			end
			if top < 1 then
				top = 1
			end

			local buf = {}
			local function put(r, c, s)
				buf[#buf + 1] = move(r, c) .. s
			end
			buf[#buf + 1] = ESC .. "2J"
			put(1, 2, C.accent .. C.bold .. (title or "Select") .. RESET)
			if subtitle then
				put(2, 2, C.muted .. subtitle .. RESET)
			end
			-- filter line
			local fl = (filter ~= "") and (C.bright .. "filter: " .. filter .. RESET)
				or (C.dim .. "type to filter" .. RESET)
			put(3, 2, fl)

			if #view == 0 then
				put(list_top, 2, C.muted .. "no matches" .. RESET)
			else
				for i = 0, list_h - 1 do
					local idx = top + i
					local it = view[idx]
					if it then
						local row = list_top + i
						if idx == sel then
							put(row, 2, C.selbg .. C.bright .. " " .. it.label .. " " .. RESET)
						else
							put(row, 2, C.text .. "  " .. it.label .. RESET)
						end
					end
				end
			end
			put(h - 1, 2, C.dim .. "↑↓ move   Enter select   Esc cancel" .. RESET)
			out(table.concat(buf))
			io.flush()
		end

		draw()
		while true do
			local view = filtered()
			local k = M.readkey()
			if k == "esc" then
				return nil
			elseif k == "up" or k == "k" then
				if sel > 1 then
					sel = sel - 1
					draw()
				end
			elseif k == "down" or k == "j" then
				if sel < #view then
					sel = sel + 1
					draw()
				end
			elseif k == "\r" or k == "\n" then
				if view[sel] then
					return view[sel].value
				end
			elseif k == "\127" or k == "\8" then
				if #filter > 0 then
					filter = filter:sub(1, -2)
					sel = 1
					top = 1
					draw()
				end
			elseif type(k) == "string" and #k == 1 and k:byte() >= 32 then
				filter = filter .. k
				sel = 1
				top = 1
				draw()
			end
		end
	end

	function M.run_text_input(title, subtitle, initial)
		local chars = {}
		if type(initial) == "string" then
			for i = 1, #initial do
				chars[i] = initial:sub(i, i)
			end
		end
		local function draw()
			local h, w = M.termsize()
			local buf = {}
			local function put(r, c, s)
				buf[#buf + 1] = move(r, c) .. s
			end
			buf[#buf + 1] = ESC .. "2J"
			put(2, 2, C.accent .. C.bold .. (title or "Enter value") .. RESET)
			if subtitle then
				put(4, 2, C.muted .. subtitle .. RESET)
			end
			local field = table.concat(chars)
			local shown = (#field > 0) and (C.bright .. field .. RESET) or (C.dim .. "(type a value)" .. RESET)
			put(6, 2, shown)
			put(6, 2 + #field, C.accent .. "_" .. RESET)
			put(8, 2, C.dim .. "Enter confirm   Esc cancel" .. RESET)
			out(table.concat(buf))
			io.flush()
		end
		draw()
		while true do
			local k = M.readkey()
			if k == "esc" then
				return nil
			elseif k == "\r" or k == "\n" then
				return table.concat(chars)
			elseif k == "\127" or k == "\8" then
				if #chars > 0 then
					chars[#chars] = nil
					draw()
				end
			elseif type(k) == "string" and #k == 1 and k:byte() >= 32 then
				chars[#chars + 1] = k
				draw()
			end
		end
	end

	function M.run_text_confirm(title, warning, phrase)
		local typed = ""
		local function draw()
			local h, w = M.termsize()
			local buf = {}
			local function put(r, c, s)
				buf[#buf + 1] = move(r, c) .. s
			end
			buf[#buf + 1] = ESC .. "2J"
			put(2, 2, C.amber .. C.bold .. (title or "Confirm") .. RESET)
			local row = 4
			if warning then
				for line in (warning .. "\n"):gmatch("(.-)\n") do
					if line ~= "" then
						put(row, 2, C.text .. line .. RESET)
						row = row + 1
					end
				end
			end
			row = row + 1
			put(row, 2, C.dim .. "Type " .. RESET .. C.bright .. phrase .. RESET .. C.dim .. " to confirm:" .. RESET)
			row = row + 1
			local match = (typed == phrase)
			local box = match and (C.selbg .. C.bright .. " " .. typed .. " " .. RESET)
				or (C.muted .. " " .. typed .. "_ " .. RESET)
			put(row, 2, box)
			row = row + 2
			if match then
				put(row, 2, C.dim .. "Enter confirm   Esc cancel" .. RESET)
			else
				put(row, 2, C.dim .. "(type the name exactly)   Esc cancel" .. RESET)
			end
			out(table.concat(buf))
			io.flush()
		end
		draw()
		while true do
			local k = M.readkey()
			if k == "esc" then
				return false
			elseif k == "\r" or k == "\n" then
				if typed == phrase then
					return true
				end
			-- otherwise ignore Enter until the phrase matches exactly
			elseif k == "\127" or k == "\8" then
				typed = typed:sub(1, -2)
				draw()
			elseif type(k) == "string" and #k == 1 and k:match("[%w%-_%.]") then
				typed = typed .. k
				draw()
			end
		end
	end
end
