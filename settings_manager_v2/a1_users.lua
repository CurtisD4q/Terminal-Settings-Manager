#!/usr/bin/env lua5.4
-- Users & Accounts — current-user info (read-only) plus full user MANAGEMENT
-- gated behind pkexec (password) and, for destructive actions, a confirmation
-- screen. Management actions: add user, delete user, lock/unlock, change your
-- own password.
--
-- SAFETY: delete and lock are destructive and can lock you out of your own
-- system. Every destructive action requires BOTH a confirmation screen AND
-- the polkit password. Deleting your own logged-in account is blocked.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local r = require("region_users_backend")
local util = require("util")

-- Usernames flow into root-privileged commands (useradd/userdel/passwd), so
-- they get two layers of defence:
--   1. valid_username() rejects anything outside the POSIX-portable charset,
--      so metacharacters never reach a command in the first place;
--   2. every interpolation is shell-quoted via util.shquote, so even a value
--      that somehow bypassed validation cannot break out of its argument.
-- Accepts: initial lowercase letter or underscore, then letters/digits/_/-,
-- optional trailing $, max 32 chars — the useradd/adduser convention.
local function valid_username(name)
	if type(name) ~= "string" then
		return false
	end
	if #name == 0 or #name > 32 then
		return false
	end
	return name:match("^[a-z_][a-z0-9_%-]*%$?$") ~= nil
end

-- prompt for a new username via the password-prompt screen reused as text input
-- (it returns the typed string; not masked-sensitive but fine for a username)
local function prompt_text(title, subtitle)
	return core.run_password_prompt(title, subtitle) -- returns string or nil
end

local me = r.current_user()

-- Build the per-user action rows dynamically.
local users_section = { "Manage Users", { { "Loading…", "", "" } } }

local function build_user_rows(cache)
	local rows = {}
	-- Add-user button
	rows[#rows + 1] = {
		"+ Add new user",
		"",
		"button",
		{
			get = function()
				return ""
			end,
			set = function()
				local name = prompt_text("Add new user", "Type the new username, Enter to submit")
				if not name or name == "" then
					return
				end
				name = name:gsub("%s", "")
				if name == "" then
					return
				end
				if not valid_username(name) then
					core.run_confirm(
						"Invalid username",
						"Usernames must start with a letter or underscore and\ncontain only lowercase letters, digits, '_' or '-'.\n\nNo changes were made."
					)
					return
				end
				-- create with a home dir; account is created locked until password set
				core.run_pkexec("useradd -m " .. util.shquote(name), "Create new user '" .. name .. "'")
			end,
		},
	}
	for _, u in ipairs(cache.users or {}) do
		local uname = u.name
		local tag = u.uid == cache.me_uid and "you" or ("uid " .. u.uid)
		if u.locked then
			tag = tag .. " · locked"
		end
		-- Each user is a button that opens a small action chooser via confirms.
		rows[#rows + 1] = {
			uname,
			tag,
			"button",
			{
				get = function()
					return tag
				end,
				set = function()
					-- can't destructively act on your own logged-in account
					if uname == me then
						-- only offer password change for yourself
						core.run_pkexec("passwd " .. util.shquote(me), "Change your password")
						return
					end
					-- choose lock/unlock vs delete via confirm screens
					-- first: toggle lock
					local locked = u.locked
					local verb = locked and "unlock" or "lock"
					local do_lock = core.run_confirm(
						(locked and "Unlock" or "Lock") .. " user '" .. uname .. "'?",
						(
							locked and "The account will be able to log in again."
							or "The account will be prevented from logging in."
						)
					)
					if do_lock then
						core.run_pkexec(
							"passwd " .. (locked and "-u " or "-l ") .. util.shquote(uname),
							(locked and "Unlock" or "Lock") .. " '" .. uname .. "'"
						)
						return
					end
					-- if they declined lock, offer delete (separate explicit confirm)
					local do_del = core.run_confirm(
						"Delete user '" .. uname .. "'?",
						"This permanently removes the account AND its home directory.\nThis cannot be undone."
					)
					if do_del then
						core.run_pkexec("userdel -r " .. util.shquote(uname), "Delete user '" .. uname .. "'")
					end
				end,
			},
		}
	end
	return rows
end

local CAT = {
	id = "users",
	label = "Users & Accounts",
	icon = "◎",
	sections = {
		{
			"Current User",
			{
				{ "Username", "—", "", {
					get = function()
						return r.current_user()
					end,
				} },
				{ "User ID", "—", "", {
					get = function()
						return r.uid()
					end,
				} },
				{ "Account type", "—", "", {
					get = function()
						return r.account_type()
					end,
				} },
				{ "Shell", "—", "", {
					get = function()
						return r.shell()
					end,
				} },
			},
		},
		{
			"Groups",
			{
				{ "Primary group", "—", "", {
					get = function()
						return r.primary_group()
					end,
				} },
				{ "Member of", "—", "", {
					get = function()
						return r.groups()
					end,
				} },
			},
		},
		users_section,
		{
			"Sessions",
			{
				{ "Logged in", "—", "", {
					get = function()
						return r.logged_in()
					end,
				} },
			},
		},
	},
	prefetch = function(cache)
		cache.users = r.human_users()
		cache.me_uid = tonumber(r.uid())
		users_section[2] = build_user_rows(cache)
	end,
}

return core.define_category(CAT)
