#!/usr/bin/env lua5.4
-- Disk Encryption (App 2) — LUKS volume status and management.
-- Read-only status is extensive; actions are guarded. Passphrase-bearing
-- operations hand off to cryptsetup's own secure prompts (the screen briefly
-- leaves the TUI). Hard rules: never lock/close the system volume, never
-- remove the last keyslot. Destructive actions require typing the device name.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local enc = require("encryption_backend")

local CAT -- forward-declared

-- cache of volumes + their parsed dumps; refreshed on entry and after actions
local vols = {}
local dumps = {} -- [dev_path] = parsed luksdump info

local function refresh()
	vols = enc.volumes() or {}
	dumps = {}
	for _, v in ipairs(vols) do
		-- best-effort unprivileged dump; if it fails, detail stays sparse
		local text = enc.try_luksdump(v.dev_path)
		if text then
			dumps[v.dev_path] = enc.parse_luksdump(text)
		end
	end
end

-- Run a privileged action then refresh state. Passphrase-bearing commands need
-- cryptsetup's interactive terminal prompt, so we leave the alternate screen,
-- run directly (not through the silent pkexec wrapper), then re-enter.
local function run_interactive(cmd)
	core.screen_leave()
	io.write("\n")
	os.execute("pkexec " .. cmd)
	io.write("\nPress Enter to return…")
	io.read("*l")
	core.screen_enter()
	refresh()
end

-- ── row builders ─────────────────────────────────────────────────────────────

local function volume_detail_rows(v, rows)
	local info = dumps[v.dev_path] or {}
	local state = v.open and "unlocked" or "locked"
	local sys = v.is_system and "  [system]" or ""
	-- header
	rows[#rows + 1] = { v.device .. sys, state, "" }
	-- LUKS metadata
	if info.version then
		rows[#rows + 1] = { "  LUKS version", info.version, "" }
	end
	if info.cipher then
		rows[#rows + 1] =
			{ "  Cipher", info.cipher .. (info.keysize and ("  ·  " .. info.keysize .. "-bit") or ""), "" }
	end
	if info.hash then
		rows[#rows + 1] = { "  Hash", info.hash, "" }
	end
	if info.slots_used then
		rows[#rows + 1] = { "  Key slots", info.slots_used .. " of " .. info.slots_total .. " used", "" }
	end
	rows[#rows + 1] = { "  TPM auto-unlock", info.tpm and "enrolled" or "not enrolled", "" }
	if v.open then
		rows[#rows + 1] = { "  Mounted at", v.mountpoint or "(not mounted)", "" }
		if v.fstype then
			rows[#rows + 1] = { "  Filesystem", v.fstype, "" }
		end
	end
end

-- Action rows for one volume, honoring the safety guards.
local function volume_action_rows(v, rows)
	local info = dumps[v.dev_path] or {}
	local dev = v.dev_path

	-- Lock / Unlock
	if v.open then
		-- lock: only if NOT system and not mounted (mounted mapping can't close)
		if v.is_system then
			rows[#rows + 1] = { "    Lock", "protected (system)", "" }
		elseif v.mountpoint and v.mountpoint ~= "" then
			rows[#rows + 1] = { "    Lock", "unmount first", "" }
		else
			rows[#rows + 1] = {
				"    Lock volume",
				"",
				"button",
				{
					get = function()
						return "lock"
					end,
					set = function()
						local ok = core.run_confirm(
							"Lock " .. v.device .. "?",
							"Closes the encrypted mapping. It must be unlocked again\n(with a passphrase) before use."
						)
						if ok then
							run_interactive(enc.cmd_close(v.mapping))
						end
					end,
				},
			}
		end
	else
		-- unlock: prompts for passphrase via cryptsetup
		rows[#rows + 1] = {
			"    Unlock volume",
			"",
			"button",
			{
				get = function()
					return "unlock"
				end,
				set = function()
					local mapping = "luks-" .. v.device
					-- Enter-to-confirm intent, then interactive passphrase prompt
					local ok = core.run_confirm(
						"Unlock " .. v.device .. "?",
						"cryptsetup will ask for the passphrase on the next screen."
					)
					if ok then
						run_interactive(enc.cmd_open(dev, mapping))
					end
				end,
			},
		}
	end

	-- Keyslot management (add / change / remove) — only for LUKS volumes we
	-- could dump. Each requires Enter-to-confirm; remove additionally requires
	-- typing the device name and is blocked on the last slot.
	rows[#rows + 1] = {
		"    Add passphrase",
		"",
		"button",
		{
			get = function()
				return "add"
			end,
			set = function()
				local ok = core.run_confirm(
					"Add a passphrase to " .. v.device .. "?",
					"Adds a new key in a free slot. cryptsetup will ask for an\nexisting passphrase, then the new one, on the next screen."
				)
				if ok then
					run_interactive(enc.cmd_add_key(dev))
				end
			end,
		},
	}
	rows[#rows + 1] = {
		"    Change passphrase",
		"",
		"button",
		{
			get = function()
				return "change"
			end,
			set = function()
				local ok = core.run_confirm(
					"Change a passphrase on " .. v.device .. "?",
					"Replaces one passphrase with a new one. cryptsetup will ask\nfor the old and new passphrases on the next screen."
				)
				if ok then
					run_interactive(enc.cmd_change_key(dev))
				end
			end,
		},
	}
	-- remove: guarded
	if enc.can_remove_key(info.slots_used) then
		rows[#rows + 1] = {
			"    Remove passphrase",
			"",
			"button",
			{
				get = function()
					return "remove"
				end,
				set = function()
					local ok = core.run_text_confirm(
						"Remove a passphrase from " .. v.device .. "?",
						"Permanently deletes one keyslot. This cannot be undone.\nOther passphrases still work. cryptsetup will ask which\npassphrase to remove on the next screen.",
						v.device
					)
					if ok then
						run_interactive(enc.cmd_remove_key(dev))
					end
				end,
			},
		}
	else
		rows[#rows + 1] = { "    Remove passphrase", "last slot — protected", "" }
	end
end

local function volumes_section()
	if not enc.available() then
		return { { "Unavailable", "cryptsetup not found", "" } }
	end
	if #vols == 0 then
		return { { "No encrypted volumes found", "", "" } }
	end
	local rows = {}
	for _, v in ipairs(vols) do
		volume_detail_rows(v, rows)
		volume_action_rows(v, rows)
	end
	return rows
end

-- ── prefetch ─────────────────────────────────────────────────────────────────

local function prefetch()
	if #vols == 0 then
		refresh()
	end
	CAT.sections[1][2] = volumes_section()
end

CAT = {
	id = "encryption",
	label = "Disk Encryption",
	icon = "▥",
	sections = {
		{ "LUKS Volumes", { { "Loading…", "", "" } } },
	},
	prefetch = prefetch,
}

return core.define_category(CAT)
