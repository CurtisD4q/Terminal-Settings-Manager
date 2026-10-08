#!/usr/bin/env lua5.4
-- Notifications — LIVE via makoctl (mako). Live controls only; the persistent
-- config (banner position, timeout, per-app rules) lives in ~/.config/mako/
-- config and is intentionally not touched here.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local nt = require("notifications_backend")

local CAT -- forward-declare so prefetch can reference it

local function prefetch(cache)
	cache.running = nt.available() and nt.running()
	if not nt.available() then
		cache.why = "makoctl not found"
	end
	if cache.running then
		cache.dnd = select(1, nt.dnd_on())
		cache.count = nt.count()
		cache.history = nt.history()
		local hrows = {}
		if cache.history and #cache.history > 0 then
			for _, item in ipairs(cache.history) do
				local label = item.summary
				local detail = item.app or ""
				if item.body and item.body ~= "" then
					detail = detail ~= "" and (detail .. " · " .. item.body) or item.body
				end
				hrows[#hrows + 1] = { label, detail, "" }
			end
		else
			hrows[#hrows + 1] = { "No notifications", "", "" }
		end
		CAT.sections[3][2] = hrows
	else
		CAT.sections[3][2] = { { "mako not running", "", "" } }
	end
end

CAT = {
	id = "notifications",
	label = "Notifications",
	icon = "✉",
	sections = {
		{
			"Do Not Disturb",
			{
				{
					"Do Not Disturb",
					"—",
					"toggle",
					{
						get = function(c)
							if not c.running then
								return nil, c.why or "mako not running"
							end
							return c.dnd
						end,
						set = function(v, c)
							nt.set_dnd(v)
						end,
					},
				},
			},
		},
		{
			"Current Notifications",
			{
				{
					"Showing",
					"—",
					"",
					{
						get = function(c)
							if not c.running then
								return nil, "mako not running"
							end
							local n = c.count
							if n == nil then
								return "unknown"
							end
							return (n == 1) and "1 notification" or (n .. " notifications")
						end,
					},
				},
				{
					"Dismiss latest",
					"",
					"button",
					{
						get = function()
							return ""
						end,
						set = function(_, c)
							nt.dismiss()
						end,
					},
				},
				{
					"Dismiss all",
					"",
					"button",
					{
						get = function()
							return ""
						end,
						set = function(_, c)
							nt.dismiss_all()
						end,
					},
				},
				{
					"Restore last",
					"",
					"button",
					{
						get = function()
							return ""
						end,
						set = function(_, c)
							nt.restore()
						end,
					},
				},
			},
		},
		{ "History", {
			{ "Loading…", "", "" },
		} },
	},
	prefetch = prefetch,
}

return core.define_category(CAT)
