-- bluetooth_backend.lua — Bluetooth control via bluetoothctl (BlueZ).
--   Adapter: power on/off, discoverable, pairable (from `bluetoothctl show`).
--   Devices: list known/paired devices (`bluetoothctl devices`), per-device
--     connect/disconnect and status (`bluetoothctl info <mac>`).
-- Read operations are cheap; connect/disconnect are fire-and-forget (BlueZ
-- does them asynchronously, so the UI reflects the new state on next refresh).
local M = {}
local util = require("util")

local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local BT_OK = nil
local function have_bluetoothctl()
	if BT_OK == nil then
		local out = shell("command -v bluetoothctl")
		BT_OK = (out ~= nil and out:match("%S") ~= nil)
	end
	return BT_OK
end
M.available = have_bluetoothctl

-- adapter status from `bluetoothctl show`
-- returns { present=true, powered=bool, discoverable=bool, pairable=bool, name=str }
function M.adapter()
	if not have_bluetoothctl() then
		return { present = false, err = "bluetoothctl not found" }
	end
	local out, ok = shell("bluetoothctl show")
	if not ok or not out or out:match("No default controller") then
		return { present = false, err = "no adapter" }
	end
	local function yn(key)
		local v = out:match(key .. "%s*:%s*(%a+)")
		return v == "yes"
	end
	return {
		present = true,
		powered = yn("Powered"),
		discoverable = yn("Discoverable"),
		pairable = yn("Pairable"),
		name = out:match("Name:%s*([^\n]+)"),
	}
end

function M.set_power(on)
	if not have_bluetoothctl() then
		return false, "bluetoothctl not found"
	end
	local _, ok = shell(("bluetoothctl power %s"):format(on and "on" or "off"))
	if ok then
		return true, nil
	end
	return false, "power failed"
end

function M.set_discoverable(on)
	if not have_bluetoothctl() then
		return false, "bluetoothctl not found"
	end
	local _, ok = shell(("bluetoothctl discoverable %s"):format(on and "on" or "off"))
	if ok then
		return true, nil
	end
	return false, "failed"
end

-- list known devices: returns { {mac=, name=, connected=bool}, ... }
-- `bluetoothctl devices` gives "Device <MAC> <Name>"; connection state needs a
-- per-device `info`, which we only fetch for the paired list (bounded, small).
function M.devices()
	if not have_bluetoothctl() then
		return nil, "bluetoothctl not found"
	end
	-- prefer paired devices (the useful set); fall back to all known
	local out = shell("bluetoothctl devices Paired")
	if not out or not out:match("Device") then
		out = shell("bluetoothctl devices") -- older bluez without the filter
	end
	if not out then
		return nil, "no devices"
	end
	local devices = {}
	for mac, name in out:gmatch("Device%s+([%x:]+)%s+([^\n]+)") do
		devices[#devices + 1] = { mac = mac, name = name, connected = false }
	end
	-- annotate connection status (one info call each; paired list is short)
	for _, d in ipairs(devices) do
		local info = shell(("bluetoothctl info %s"):format(d.mac))
		if info then
			d.connected = info:match("Connected:%s*yes") ~= nil
			local batt = info:match("Battery Percentage:%s*[^%(]*%((%d+)%)")
			d.battery = batt and tonumber(batt) or nil
		end
	end
	return devices, nil
end

function M.connect(mac)
	if not have_bluetoothctl() then
		return false, "bluetoothctl not found"
	end
	local _, ok = shell(("bluetoothctl connect %s"):format(mac))
	if ok then
		return true, nil
	end
	return false, "connect failed"
end

function M.disconnect(mac)
	if not have_bluetoothctl() then
		return false, "bluetoothctl not found"
	end
	local _, ok = shell(("bluetoothctl disconnect %s"):format(mac))
	if ok then
		return true, nil
	end
	return false, "disconnect failed"
end

return M
