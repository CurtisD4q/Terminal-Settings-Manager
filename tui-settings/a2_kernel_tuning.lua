#!/usr/bin/env lua5.4
-- Kernel Tuning (App 2) — SAFE, curated sysctl tuning.
-- Only a short allowlist of bounded, reversible, non-security sysctls is
-- exposed (see kernel_tuning_backend.lua for the selection rationale). Sliders
-- make out-of-range values impossible; changes apply live (revert on reboot);
-- persistence is a separate, explicit action. No net.* or kernel.* knobs.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local kt = require("kernel_tuning_backend")

local CAT -- forward-declared

-- live cache of current values; refreshed after any apply/reset
local cur = {}
local function refresh()
	cur = kt.get_all()
end

-- ── row builders ─────────────────────────────────────────────────────────────

-- Build a row for one allowlisted parameter. Sliders for bounded numeric
-- params; a choice-cycle for preset params. Value applies live on change,
-- after validation. Shows current value and the kernel default alongside.
local function param_rows()
	local rows = {}
	for _, p in ipairs(kt.PARAMS) do
		-- header row: label + description + current/default readout
		local curval = cur[p.key]
		local readout = (curval ~= nil and tostring(curval) or "—") .. "  (default " .. tostring(p.default) .. ")"
		rows[#rows + 1] = { p.label, readout, "" }
		rows[#rows + 1] = { "  " .. p.desc, "", "" }

		if p.kind == "slider" then
			-- slider maps 0..100 of the widget onto min..max of the param
			local key = p.key
			rows[#rows + 1] = {
				"  Adjust",
				"—",
				"slider",
				{
					get = function()
						local v = cur[key]
						if v == nil then
							return 50
						end
						-- map param value -> 0..100 slider position
						local frac = (v - p.min) / (p.max - p.min)
						return math.floor(frac * 100 + 0.5)
					end,
					set = function(sliderval)
						-- map 0..100 slider -> param min..max, validate, apply live
						local frac = (tonumber(sliderval) or 0) / 100
						local target = p.min + frac * (p.max - p.min)
						local valid = kt.validate(p, target)
						if valid ~= nil then
							core.run_pkexec(kt.cmd_apply(key, valid), "Set " .. key .. " = " .. valid)
							cur[key] = valid
						end
					end,
				},
			}
		elseif p.kind == "preset" then
			local key = p.key
			rows[#rows + 1] = {
				"  Value",
				"—",
				"choice",
				{
					get = function()
						local v = cur[key]
						return v ~= nil and tostring(v) or "—"
					end,
					set = function(step)
						local presets = p.presets
						local n = #presets
						-- find current index
						local idx = 1
						for i, val in ipairs(presets) do
							if val == cur[key] then
								idx = i
								break
							end
						end
						if step == 0 then
							step = 1
						end
						local nextidx = ((idx - 1 + step) % n + n) % n + 1
						local target = presets[nextidx]
						local valid = kt.validate(p, target)
						if valid ~= nil then
							core.run_pkexec(kt.cmd_apply(key, valid), "Set " .. key .. " = " .. valid)
							cur[key] = valid
						end
					end,
				},
			}
		end

		-- per-param reset to kernel default
		local key = p.key
		rows[#rows + 1] = {
			"  Reset to default",
			"",
			"button",
			{
				get = function()
					return "reset"
				end,
				set = function()
					core.run_pkexec(kt.cmd_reset(p), "Reset " .. key .. " to default")
					cur[key] = p.default
				end,
			},
		}
	end
	return rows
end

-- Persistence controls: make current live values permanent, or remove the
-- managed file. Deliberately separate from the live sliders above.
local function persist_rows()
	local persisted = kt.is_persisted()
	local rows = {}
	rows[#rows + 1] = {
		"Status",
		persisted and "persisted across reboots" or "live only (reverts on reboot)",
		"",
	}
	rows[#rows + 1] = {
		"Make current values permanent",
		"",
		"button",
		{
			get = function()
				return "save"
			end,
			set = function()
				local ok = core.run_confirm(
					"Persist current tuning across reboots?",
					"Writes the current values to /etc/sysctl.d/99-tui.conf so\nthey apply on every boot. All values are within safe ranges."
				)
				if ok then
					core.run_pkexec(kt.cmd_persist(cur), "Persist kernel tuning")
				end
			end,
		},
	}
	if persisted then
		rows[#rows + 1] = {
			"Remove persistence",
			"",
			"button",
			{
				get = function()
					return "remove"
				end,
				set = function()
					local ok = core.run_confirm(
						"Remove persisted tuning?",
						"Deletes /etc/sysctl.d/99-tui.conf. Live values stay until\nreboot, then revert to distribution defaults."
					)
					if ok then
						core.run_pkexec(kt.cmd_unpersist(), "Remove persisted kernel tuning")
					end
				end,
			},
		}
	end
	return rows
end

-- ── prefetch ─────────────────────────────────────────────────────────────────

local function prefetch()
	if next(cur) == nil then
		refresh()
	end
	CAT.sections[1][2] = param_rows()
	CAT.sections[2][2] = persist_rows()
end

CAT = {
	id = "kernel_tuning",
	label = "Kernel Tuning",
	icon = "▦",
	sections = {
		{ "Safe Parameters (live)", { { "Loading…", "", "" } } },
		{ "Persistence", { { "Loading…", "", "" } } },
	},
	prefetch = prefetch,
}

return core.define_category(CAT)
