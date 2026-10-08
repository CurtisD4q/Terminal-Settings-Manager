#!/usr/bin/env lua5.4
-- Network — LIVE via nmcli (NetworkManager).
--   Wi-Fi radio: on/off toggle.
--   Scan for networks: button that triggers a rescan and refreshes the list.
--   Status: active connection + IP (read-only).
--   Wi-Fi networks: one row per in-range SSID. Selecting one:
--     - open or already-saved  -> connects directly
--     - secured & not saved    -> opens the password screen (a1_networkpass)
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local net = require("network_backend")
local netpass = require("a1_networkpass")
local proxy = require("proxy_backend")

local function sig_bar(pct)
	local blocks = math.max(0, math.min(4, math.floor(pct / 25 + 0.5)))
	return string.rep("▮", blocks) .. string.rep("▯", 4 - blocks)
end

-- Handle selecting a network row: decide direct-connect vs password screen.
local function join_network(w)
	local secured = (w.security and w.security ~= "" and w.security ~= "open")
	if not secured or net.is_saved(w.ssid) then
		net.connect_ssid(w.ssid) -- open or saved: connect directly
		return
	end
	-- secured & not saved: switch to the password screen, then reconnect flow.
	-- The prompt reuses the same alt-screen; on return we're back in the
	-- category loop which will redraw itself.
	netpass.prompt_and_connect(w.ssid)
end

local function build_wifi_rows(cache)
	if cache.wifi_err then
		return { { cache.wifi_err, "", "" } }
	end
	if not cache.wifi_on then
		return { { "Wi-Fi is off", "", "" } }
	end
	local nets = cache.networks
	if not nets or #nets == 0 then
		return { { "No networks — press Scan", "", "" } }
	end
	local rows = {}
	for _, w in ipairs(nets) do
		local ww = w
		local label = w.ssid
		if w.active then
			label = "● " .. label
		end
		local meta = sig_bar(w.signal) .. "  " .. w.security
		rows[#rows + 1] = {
			label,
			meta,
			"button",
			{
				get = function()
					return meta
				end,
				set = function(_, c)
					join_network(ww)
				end,
			},
		}
	end
	return rows
end

local wifi_section = { "Wi-Fi Networks", { { "Press Scan to search", "", "" } } }
local proxy_section = { "Proxy (GTK apps)", { { "Loading…", "", "" } } }

-- Build the proxy rows. A mode chooser (none/manual/auto), then rows that
-- depend on the mode: manual shows per-protocol host:port with set/clear;
-- auto shows the PAC URL. All user-level via gsettings — no root. On Sway
-- (no GNOME) these are honored by GTK apps and some others, not universally.
local function build_proxy_rows(cache)
	local rows = {}
	if not proxy.available() then
		return { { "gsettings not available", "", "" } }
	end
	local mode = cache.proxy_mode or "none"

	-- mode chooser
	rows[#rows + 1] = {
		"Mode",
		mode,
		"choice",
		{
			get = function()
				return cache.proxy_mode or "none"
			end,
			set = function(dir)
				local modes = proxy.MODES
				local idx = 1
				for i, m in ipairs(modes) do
					if m == (cache.proxy_mode or "none") then
						idx = i
						break
					end
				end
				if dir == 0 then
					dir = 1
				end
				local n = #modes
				local nextidx = ((idx - 1 + dir) % n + n) % n + 1
				proxy.set_mode(modes[nextidx])
				cache.proxy_dirty = true
			end,
		},
	}

	if mode == "manual" then
		for _, proto in ipairs(proxy.PROTOCOLS) do
			local host = (cache.proxy_manual and cache.proxy_manual[proto]) or { host = "", port = 0 }
			local shown = (host.host ~= "") and (host.host .. ":" .. host.port) or "not set"
			rows[#rows + 1] = {
				"  " .. proto:upper(),
				shown,
				"button",
				{
					get = function()
						return "edit"
					end,
					set = function()
						local initial = (host.host ~= "") and (host.host .. ":" .. host.port) or ""
						local entry = core.run_text_input(
							proto:upper() .. " proxy",
							"Enter host:port (e.g. proxy.example.com:8080), blank to clear",
							initial
						)
						if entry ~= nil then
							entry = entry:gsub("%s+", "")
							if entry == "" then
								proxy.clear_manual(proto)
							else
								local h, p = entry:match("^(.-):(%d+)$")
								if not h then
									h, p = entry, "0"
								end
								proxy.set_manual(proto, h, tonumber(p) or 0)
							end
							cache.proxy_dirty = true
						end
					end,
				},
			}
		end
	elseif mode == "auto" then
		local url = cache.proxy_pac or ""
		rows[#rows + 1] = {
			"  PAC URL",
			(url ~= "" and url or "not set"),
			"button",
			{
				get = function()
					return "edit"
				end,
				set = function()
					local entry =
						core.run_text_input("Automatic proxy configuration", "Enter PAC file URL, blank to clear", url)
					if entry ~= nil then
						if entry:gsub("%s+", "") == "" then
							proxy.clear_autoconfig_url()
						else
							proxy.set_autoconfig_url(entry)
						end
						cache.proxy_dirty = true
					end
				end,
			},
		}
	end

	local ign = cache.proxy_ignore or {}
	if #ign > 0 then
		rows[#rows + 1] = { "  Bypass for", table.concat(ign, ", "), "" }
	end
	return rows
end

local CAT = {
	id = "network",
	label = "Network",
	icon = "⇄",
	sections = {
		{
			"Wi-Fi",
			{
				{
					"Wi-Fi radio",
					"—",
					"toggle",
					{
						get = function(c)
							return c.wifi_on, c.wifi_err
						end,
						set = function(v, c)
							net.set_wifi(v)
						end,
					},
				},
				{
					"Scan for networks",
					"",
					"button",
					{
						get = function()
							return ""
						end,
						set = function(_, c)
							net.rescan()
							c._force_scan = true
						end,
					},
				},
			},
		},
		{
			"Status",
			{
				{
					"Connection",
					"—",
					"",
					{
						get = function(c)
							if not c.status or #c.status == 0 then
								return "disconnected", nil
							end
							for _, cn in ipairs(c.status) do
								if cn.type and cn.type:match("wireless") then
									return cn.name, nil
								end
							end
							return c.status[1].name, nil
						end,
					},
				},
				{ "IP address", "—", "", {
					get = function(c)
						return c.ip or "—", nil
					end,
				} },
				{
					"Link speed",
					"—",
					"",
					{
						get = function(c)
							return c.speed or "—", nil
						end,
					},
				},
			},
		},
		wifi_section,
		proxy_section,
	},
	prefetch = function(cache)
		local on, werr = net.wifi_enabled()
		cache.wifi_on, cache.wifi_err = on, werr
		cache.status = net.status()
		cache.ip = net.primary_ip()
		cache.speed = net.link_speed()
		-- Wi-Fi scanning is the slowest thing this category does (the radio
		-- physically sweeps channels, ~1-3s), so we DON'T scan on open. The list
		-- stays empty ("No networks — press Scan") until the user presses the
		-- Scan button, which sets _force_scan. This keeps the category opening
		-- fast; the scan cost is paid only when the user asks for it.
		if cache.wifi_on and cache._force_scan then
			local nets, nerr = net.wifi_list()
			cache.networks, cache.net_list_err = nets, nerr
			cache._force_scan = false
		elseif cache.networks == nil then
			cache.networks = {}
		end
		wifi_section[2] = build_wifi_rows(cache)

		-- proxy: read current gsettings state (cheap; re-read when marked dirty by
		-- a set/clear action or on first load)
		if proxy.available() then
			if cache.proxy_mode == nil or cache.proxy_dirty then
				cache.proxy_mode = proxy.mode()
				cache.proxy_manual = {}
				for _, proto in ipairs(proxy.PROTOCOLS) do
					local h, p = proxy.get_manual(proto)
					cache.proxy_manual[proto] = { host = h, port = p }
				end
				cache.proxy_pac = proxy.autoconfig_url()
				cache.proxy_ignore = proxy.ignore_hosts()
				cache.proxy_dirty = false
			end
		end
		proxy_section[2] = build_proxy_rows(cache)
	end,
}

return core.define_category(CAT)
