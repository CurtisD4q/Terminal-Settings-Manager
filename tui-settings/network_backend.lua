-- network_backend.lua — network status & control.
--
-- This is now a thin delegation layer over the swappable network provider
-- (network.lua), which picks NetworkManager (nmcli) or iwd depending on what's
-- installed. The public function names and return shapes are unchanged, so the
-- Network category and its password helper are untouched; only the underlying
-- implementation became portable across Sway systems.
local M = {}
local net = require("network")

function M.available()
	return net.available()
end

function M.wifi_enabled()
	return net.wifi_enabled()
end
function M.set_wifi(on)
	return net.set_wifi(on)
end

function M.status()
	return net.status()
end
function M.primary_ip()
	return net.primary_ip()
end
function M.link_speed()
	return net.link_speed()
end

-- Returns (list, err) where each entry is { ssid, signal, security, active }.
function M.wifi_list()
	return net.wifi_list()
end
function M.rescan()
	return net.rescan()
end

function M.is_saved(ssid)
	return net.is_saved(ssid)
end

-- Connect to an open or already-known network (no password needed).
function M.connect_ssid(ssid)
	return net.connect(ssid)
end

-- Connect to a secured network with an explicit password. Both the SSID
-- (untrusted, broadcast) and the password are passed as separate arguments by
-- the driver via util.run, so neither can be shell-injected.
-- NOTE (unchanged): with NetworkManager the password is briefly visible in the
-- process table while nmcli runs; with iwd it goes to iwctl's --passphrase.
function M.connect_with_password(ssid, password)
	return net.connect_pw(ssid, password)
end

-- The active backend's name, for display ("NetworkManager" or "iwd").
function M.backend_name()
	return net.name()
end

return M
