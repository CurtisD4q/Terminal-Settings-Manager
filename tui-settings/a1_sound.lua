#!/usr/bin/env lua5.4
-- Sound settings — LIVE category (not data-generated like the others).
-- Wired to the real system:
--   Output/Input Volume, Mute   — wpctl get/set-volume, get/set-mute
--   Output/Input Device         — PORT switching via pactl (e.g. speakers vs
--                                 headphones on one codec — the common case),
--                                 falling back to switching between distinct
--                                 SINKS via wpctl if the default device has
--                                 no ports of its own (e.g. a USB DAC that
--                                 shows up as a separate sink).
--   Overamplification           — Toggle switch to allow the Output Volume to reach 150%.
-- Profile, Per-App Volume, and Alert Sounds remain static.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local audio = require("audio_backend")

-- Overamplification state persistent for this session's run
local overamp_enabled = false

-- Build the "what can Output/Input Device cycle through" picture once per
-- draw. Returns a unified list of EVERY destination — every port on every
-- sink, plus portless sinks — so speakers, headphones, HDMI, USB DACs, etc.
-- all appear in one cycle regardless of how PipeWire groups them.
local function build_device_state(kind, cache)
	local list_dests = (kind == "out") and audio.output_destinations or audio.input_destinations
	if type(list_dests) ~= "function" then
		return { mode = "none", label = "Default" }
	end
	local dests, err = list_dests()
	if not dests then
		-- not necessarily fatal: on an input with no port info we just show a label
		return { mode = "none", label = "Default", err = err }
	end
	return { mode = "list", dests = dests }
end

local function device_get(devstate)
	if not devstate or type(devstate) ~= "table" then
		return "unknown", nil
	end
	if devstate.mode == "error" then
		return nil, devstate.err
	end
	if devstate.mode == "list" then
		local dests = devstate.dests or {}
		-- show the active destination's label
		for _, d in ipairs(dests) do
			if d.is_active then
				return d.label, nil
			end
		end
		-- nothing marked active (default sink has no matching port) — show first
		if dests[1] then
			return dests[1].label, nil
		end
		return "unknown", nil
	else
		return devstate.label or "unknown", nil
	end
end

local function device_set(devstate, step, kind)
	if not devstate or type(devstate) ~= "table" then
		return
	end
	if step == 0 then
		step = 1
	end -- Enter re-advances (non-root: apply immediately)
	if devstate.mode ~= "list" then
		return -- nothing to switch to
	end
	local dests = devstate.dests or {}
	local n = #dests
	if n == 0 then
		return
	end
	-- find current active index
	local cur = 1
	for i, d in ipairs(dests) do
		if d.is_active then
			cur = i
			break
		end
	end
	local nextidx = ((cur - 1 + step) % n + n) % n + 1
	local dest = dests[nextidx]
	if kind == "out" then
		audio.set_output_destination(dest)
	else
		audio.set_input_destination(dest)
	end
end

-- Rebuild the Per-App Volume section's row list fresh every prefetch
local HIDDEN_APPS = {
	["speech-dispatcher-dummy"] = true,
	["speech-dispatcher"] = true,
}

local function rebuild_app_rows(cache)
	local apps, err = audio.list_app_volumes()
	if err then
		return { { err, "", "" } }
	end
	local rows = {}
	for _, app in ipairs(apps or {}) do
		local app_name = app.name or "Unknown App"
		local hidden = HIDDEN_APPS[app_name] or (app.binary and HIDDEN_APPS[app.binary])
		if not hidden then
			local id = app.id -- captured per-row; stable for this draw's rows
			local vol = tonumber(app.vol) or 1.0
			rows[#rows + 1] = {
				app_name,
				"—",
				"slider",
				{
					get = function(c)
						return vol
					end,
					set = function(v, c)
						audio.set_app_volume(id, tonumber(v) or 1.0)
					end,
				},
			}
		end
	end
	if #rows == 0 then
		rows[1] = { "No apps playing audio", "", "" }
	end
	return rows
end

local app_mixer_section = { "Per-App Volume", { { "Loading…", "", "" } } }

local CAT = {
	id = "sound",
	label = "Sound",
	icon = "♪",
	sections = {
		{
			"Output",
			{
				{
					"Volume",
					"—",
					"slider",
					{
						get = function(cache)
							local vol, err = cache.out_vol, cache.out_err
							if not vol or type(vol) ~= "number" then
								return nil, err
							end
							if cache.overamp then
								-- vol is 0-150; slider is 0-100, so scale down
								return vol / 1.5, nil
							else
								return math.min(vol, 100), nil
							end
						end,
						set = function(v, cache)
							local target_vol = tonumber(v) or 0
							if cache.overamp then
								-- slider 0-100 maps to volume 0-150
								target_vol = target_vol * 1.5
							else
								target_vol = math.min(target_vol, 100)
							end
							audio.set_volume(audio.SINK, target_vol)
						end,
					},
				},
				{
					"Overamplification",
					"—",
					"toggle",
					{
						get = function(cache)
							return cache.overamp, nil
						end,
						set = function(v, cache)
							overamp_enabled = v and true or false
							cache.overamp = overamp_enabled
							if not overamp_enabled then
								local vol = cache.out_vol
								if type(vol) == "number" and vol > 100 then
									audio.set_volume(audio.SINK, 100)
									cache.out_vol = 100
								end
							end
						end,
					},
				},
				{
					"Mute",
					"—",
					"toggle",
					{
						get = function(cache)
							return cache.out_muted, cache.out_err
						end,
						set = function(v, cache)
							audio.set_mute(audio.SINK, v)
						end,
					},
				},
				{
					"Device",
					"—",
					"choice",
					{
						get = function(cache)
							return device_get(cache.out_dev)
						end,
						set = function(step, cache)
							device_set(cache.out_dev, step, "out")
						end,
					},
				},
				{ "Profile", "Stereo", "" },
			},
		},
		{
			"Input",
			{
				{
					"Level",
					"—",
					"slider",
					{
						get = function(cache)
							return cache.in_vol, cache.in_err
						end,
						set = function(v, cache)
							audio.set_volume(audio.SOURCE, v)
						end,
					},
				},
				{
					"Mute",
					"—",
					"toggle",
					{
						get = function(cache)
							return cache.in_muted, cache.in_err
						end,
						set = function(v, cache)
							audio.set_mute(audio.SOURCE, v)
						end,
					},
				},
				{
					"Device",
					"—",
					"choice",
					{
						get = function(cache)
							return device_get(cache.in_dev)
						end,
						set = function(step, cache)
							device_set(cache.in_dev, step, "in")
						end,
					},
				},
			},
		},
		app_mixer_section,
		{ "Alert Sounds", {
			{ "System sounds", "", "toggle" },
			{ "Volume", "80%", "slider" },
		} },
		{
			"Server",
			{
				{
					"Audio server",
					"—",
					"",
					{
						get = function(c)
							return c.server_ver or "—", nil
						end,
					},
				},
				{
					"Sample rate",
					"—",
					"",
					{
						get = function(c)
							return c.sample_rate or "—", nil
						end,
					},
				},
			},
		},
		{
			"Maintenance",
			{
				{
					"Restart PipeWire",
					"",
					"button",
					{
						get = function()
							return "run"
						end,
						set = function()
							-- user-level services; no root needed. Briefly drops audio,
							-- so confirm first. Useful when audio gets wedged.
							local ok = core.run_confirm(
								"Restart PipeWire?",
								"Restarts pipewire, pipewire-pulse, and wireplumber.\nAudio will cut out for a moment. Fixes most stuck-audio issues."
							)
							if ok then
								audio.restart_pipewire()
							end
						end,
					},
				},
			},
		},
	},
	prefetch = function(cache)
		-- Start the event stream once, on first prefetch. From then on we
		-- only re-fetch a slice when pactl subscribe says it changed.
		audio.monitor_start()

		local use_monitor = audio.monitor_available()

		-- Persistent cache table survives across frames (stored on the CAT's
		-- own cache — the frontend passes the same table each draw).
		cache._sc = cache._sc or {}
		local sc = cache._sc

		-- volume + mute (cheap; re-read when dirty)
		if not use_monitor or audio.monitor_dirty("volume") or not sc.vol_loaded then
			local ov, om, oerr = audio.get_volume(audio.SINK)
			sc.out_vol, sc.out_muted, sc.out_err = ov, om, oerr
			sc.vol_loaded = true
			audio.monitor_clear("volume")
		end
		if not use_monitor or audio.monitor_dirty("mute") then
			-- mute is read alongside volume; refresh it from the same source
			local _, om = audio.get_volume(audio.SINK)
			if om ~= nil then
				sc.out_muted = om
			end
			audio.monitor_clear("mute")
		end
		cache.out_vol, cache.out_muted, cache.out_err = sc.out_vol, sc.out_muted, sc.out_err

		-- input level + mute
		if not use_monitor or audio.monitor_dirty("volume") or not sc.in_loaded then
			local iv, im, ierr = audio.get_volume(audio.SOURCE)
			sc.in_vol, sc.in_muted, sc.in_err = iv, im, ierr
			sc.in_loaded = true
		end
		cache.in_vol, cache.in_muted, cache.in_err = sc.in_vol, sc.in_muted, sc.in_err

		-- device inventory (expensive; only re-read when devices dirty).
		-- Guard on a "loaded" flag rather than sc.sinks==nil, so a transient
		-- empty result doesn't force a re-read on every frame.
		if not use_monitor or audio.monitor_dirty("devices") or not sc.devices_loaded then
			local sinks, sources = audio.list_devices()
			sc.sinks, sc.sources = sinks, sources
			sc.out_dev = build_device_state("out", { sinks = sinks, sources = sources })
			sc.in_dev = build_device_state("in", { sinks = sinks, sources = sources })
			sc.devices_loaded = true
			audio.monitor_clear("devices")
		end
		cache.sinks, cache.sources = sc.sinks, sc.sources
		cache.out_dev, cache.in_dev = sc.out_dev, sc.in_dev

		-- overamplification state
		if type(sc.out_vol) == "number" and sc.out_vol > 100 then
			overamp_enabled = true
		end
		cache.overamp = overamp_enabled

		-- per-app volumes (re-read when a sink-input event fired)
		if not use_monitor or audio.monitor_dirty("apps") or not sc.apps_loaded then
			sc.app_rows = rebuild_app_rows(cache)
			sc.apps_loaded = true
			audio.monitor_clear("apps")
		end
		app_mixer_section[2] = sc.app_rows

		-- server version + sample rate: static, fetch once and cache
		if sc.server_ver == nil then
			sc.server_ver = audio.server_version() or false
			sc.sample_rate = audio.sample_rate() or false
		end
		cache.server_ver = sc.server_ver or nil
		cache.sample_rate = sc.sample_rate or nil
	end,
	-- Called on idle ticks by core: drain the subscribe stream. Returns true
	-- if any event arrived (so core redraws, re-running prefetch).
	poll_events = function()
		return audio.monitor_poll()
	end,
}

return core.define_category(CAT, {
	on_exit = function()
		audio.monitor_stop()
	end,
})
