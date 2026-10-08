-- notifications_backend.lua — live notification control via makoctl (mako).
-- Live-only: Do Not Disturb toggle, dismiss / dismiss-all, and a count of
-- current notifications. No config-file editing (banner position, timeout,
-- per-app rules live in ~/.config/mako/config and are left alone by design).
local M = {}
local util = require("util")

local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local MAKO_OK = nil
local function have_makoctl()
	if MAKO_OK == nil then
		local out = shell("command -v makoctl")
		MAKO_OK = (out ~= nil and out:match("%S") ~= nil)
	end
	return MAKO_OK
end
M.available = have_makoctl

-- Is mako actually running? makoctl works only when the daemon is up.
function M.running()
	local out = shell("pgrep -x mako")
	return out ~= nil and out:match("%d") ~= nil
end

local DND = "do-not-disturb"

-- DND is on if the "do-not-disturb" mode is among the active modes.
function M.dnd_on()
	if not have_makoctl() then
		return nil, "makoctl not found"
	end
	local out, ok = shell("makoctl mode")
	if not ok or not out then
		return nil, "mako not running"
	end
	for line in out:gmatch("[^\n]+") do
		if line:gsub("%s+", "") == DND then
			return true, nil
		end
	end
	return false, nil
end

-- Enable/disable DND. mako changed its mode CLI across versions:
--   newer: makoctl mode -a <mode> / -r <mode>   (add / remove)
--   older: makoctl set-mode / mode -s <mode>
-- We try the modern add/remove first; if that errors, fall back to -s with
-- the full desired mode set.
function M.set_dnd(on)
	if not have_makoctl() then
		return false, "makoctl not found"
	end
	local cmd = on and ("makoctl mode -a %s"):format(DND) or ("makoctl mode -r %s"):format(DND)
	local _, ok = shell(cmd)
	if ok then
		return true, nil
	end
	-- fallback for older mako: set the whole mode list explicitly
	local alt = on and ("makoctl mode -s %s"):format(DND) or "makoctl mode -s default"
	local _, ok2 = shell(alt)
	if ok2 then
		return true, nil
	end
	return false, "mode change failed"
end

-- number of currently-shown notifications (best-effort: count JSON entries)
function M.count()
	if not have_makoctl() then
		return nil
	end
	local out = shell("makoctl list")
	if not out then
		return nil
	end
	-- makoctl list returns {"data":[[ {...}, {...} ]], ...}; count "id" keys as
	-- a robust-enough proxy without a full JSON parse.
	local n = 0
	for _ in out:gmatch('"id"') do
		n = n + 1
	end
	return n
end

function M.dismiss()
	if not have_makoctl() then
		return false, "makoctl not found"
	end
	local _, ok = shell("makoctl dismiss")
	if ok then
		return true, nil
	end
	return false, "failed"
end

function M.dismiss_all()
	if not have_makoctl() then
		return false, "makoctl not found"
	end
	local _, ok = shell("makoctl dismiss -a")
	if ok then
		return true, nil
	end
	return false, "failed"
end

function M.restore()
	if not have_makoctl() then
		return false, "makoctl not found"
	end
	local _, ok = shell("makoctl restore")
	if ok then
		return true, nil
	end
	return false, "failed"
end

-- Notification history: parse `makoctl list` JSON for summary + app-name.
-- makoctl list returns: {"data":[[{...},{...}],...]}
-- Each notification object has "summary", "body", "app-name" fields.
-- We do a lightweight parse without a JSON library.
function M.history()
	if not have_makoctl() then
		return nil
	end
	local out = shell("makoctl list")
	if not out or out == "" then
		return {}
	end
	local items = {}
	-- makoctl list JSON: {"data":[[{notif1},{notif2},...]]}.
	-- Each notification has nested objects: "summary":{"data":"..."} etc.
	-- Split into per-notification chunks by tracking brace depth.
	local inner = out:match("%[%[(.-)%]%]")
	if not inner then
		return {}
	end
	local chunks, depth, start = {}, 0, nil
	for i = 1, #inner do
		local ch = inner:sub(i, i)
		if ch == "{" then
			if depth == 0 then
				start = i
			end
			depth = depth + 1
		elseif ch == "}" then
			depth = depth - 1
			if depth == 0 and start then
				chunks[#chunks + 1] = inner:sub(start, i)
				start = nil
			end
		end
	end
	for _, chunk in ipairs(chunks) do
		local summary = chunk:match('"summary"%s*:%s*{[^}]-"data"%s*:%s*"([^"]*)"')
		local appname = chunk:match('"app%-name"%s*:%s*{[^}]-"data"%s*:%s*"([^"]*)"')
		local body = chunk:match('"body"%s*:%s*{[^}]-"data"%s*:%s*"([^"]*)"')
		if summary and summary ~= "" then
			items[#items + 1] = {
				summary = summary,
				app = (appname and appname ~= "") and appname or nil,
				body = (body and body ~= "") and body or nil,
			}
		end
	end
	return items
end

return M
