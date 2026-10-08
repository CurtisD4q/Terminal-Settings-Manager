#!/usr/bin/env lua5.4
-- Bluetooth & Devices — LIVE via bluetoothctl (BlueZ).
--   Adapter: power, discoverable toggles.
--   Devices: one row per paired device; toggle connects/disconnects it,
--     shows connection state and battery % where the device reports it.
-- Device list is rebuilt each refresh, so devices appear/update live.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local bt = require("bluetooth_backend")

-- Build the per-device rows fresh each prefetch from the live paired list.
local function build_device_rows(cache)
	local devs = cache.devices
	if cache.dev_err then
		return { { cache.dev_err, "", "" } }
	end
	if not devs or #devs == 0 then
		return { { "No paired devices", "", "" } }
	end
	local rows = {}
	for _, d in ipairs(devs) do
		local mac = d.mac
		-- a connect/disconnect toggle per device; label carries battery if present
		local label = d.name
		if d.battery then
			label = label .. "  (" .. d.battery .. "%)"
		end
		rows[#rows + 1] = {
			label,
			"—",
			"toggle",
			{
				get = function(c)
					-- re-find this device in the (possibly refreshed) cache
					for _, dd in ipairs(c.devices or {}) do
						if dd.mac == mac then
							return dd.connected
						end
					end
					return false
				end,
				set = function(v, c)
					if v then
						bt.connect(mac)
					else
						bt.disconnect(mac)
					end
				end,
			},
		}
	end
	return rows
end

local device_section = { "Paired Devices", { { "Loading…", "", "" } } }

local CAT = {
	id = "bluetooth",
	label = "Bluetooth & Devices",
	icon = "❖",
	sections = {
		{
			"Adapter",
			{
				{
					"Bluetooth",
					"—",
					"toggle",
					{
						get = function(c)
							if not c.adapter or not c.adapter.present then
								return nil, (c.adapter and c.adapter.err) or "no adapter"
							end
							return c.adapter.powered
						end,
						set = function(v, c)
							bt.set_power(v)
						end,
					},
				},
				{
					"Discoverable",
					"—",
					"toggle",
					{
						get = function(c)
							if not c.adapter or not c.adapter.present then
								return nil, "no adapter"
							end
							return c.adapter.discoverable
						end,
						set = function(v, c)
							bt.set_discoverable(v)
						end,
					},
				},
			},
		},
		device_section,
	},
	prefetch = function(cache)
		cache.adapter = bt.adapter()
		-- only enumerate devices if the adapter is present & powered (avoids slow
		-- info calls when BT is off)
		if cache.adapter.present and cache.adapter.powered then
			local devs, derr = bt.devices()
			cache.devices, cache.dev_err = devs, derr
		else
			cache.devices, cache.dev_err = {}, nil
		end
		device_section[2] = build_device_rows(cache)
	end,
}

return core.define_category(CAT)
