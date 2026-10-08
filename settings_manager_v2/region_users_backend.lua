-- region_users_backend.lua — Region & Language + read-only Users info.
--
-- Region/Language: `localectl` reports system locale + keymap. CHANGING these
-- needs root, so per your choice they're shown READ-ONLY here (display current
-- values; no setters wired). Falls back to environment ($LANG) if localectl
-- is unavailable.
--
-- Users: entirely read-only — current user, uid, groups, shell, who's logged
-- in. Nothing here modifies accounts (that needs root + is destructive).
local M = {}
local util = require("util")

local function shell(cmd)
	return (util.shell(cmd))
end

local trim = util.trim

function M.system_locale()
	local v = localectl_field("System Locale")
	if v and v ~= "" then
		-- often "LANG=en_GB.UTF-8" — show the value after LANG= if present
		return v:match("LANG=(%S+)") or v
	end
	-- fallback to environment
	return os.getenv("LANG") or "unset"
end

function M.keymap()
	local v = localectl_field("VC Keymap") or localectl_field("X11 Layout")
	if v and v ~= "" then
		return trim(v)
	end
	return os.getenv("XKB_DEFAULT_LAYOUT") or "unknown"
end

function M.timezone()
	-- from timedatectl for consistency with the Date&Time panel
	local out = shell("timedatectl show -p Timezone --value")
	if out and trim(out) ~= "" then
		return trim(out)
	end
	return "unknown"
end

-- Available locales (for cycling). Cached per session. Filters to UTF-8 ones
-- to keep the list manageable and modern.
local LOCALES = nil
function M.list_locales()
	if LOCALES then
		return LOCALES
	end
	local out = shell("localectl list-locales")
	LOCALES = {}
	if out then
		for l in out:gmatch("[^\n]+") do
			local v = trim(l)
			if v ~= "" then
				LOCALES[#LOCALES + 1] = v
			end
		end
	end
	if #LOCALES == 0 then
		LOCALES = nil
		return {}
	end
	return LOCALES
end

-- Available keymaps (for cycling). Cached; can be a long list.
local KEYMAPS = nil
function M.list_keymaps()
	if KEYMAPS then
		return KEYMAPS
	end
	local out = shell("localectl list-keymaps")
	KEYMAPS = {}
	if out then
		for k in out:gmatch("[^\n]+") do
			local v = trim(k)
			if v ~= "" then
				KEYMAPS[#KEYMAPS + 1] = v
			end
		end
	end
	if #KEYMAPS == 0 then
		KEYMAPS = nil
		return {}
	end
	return KEYMAPS
end

-- ── users (read-only) ───────────────────────────────────────────────────────
function M.current_user()
	local u = shell("id -un")
	return trim(u) or os.getenv("USER") or "?"
end

function M.uid()
	local u = shell("id -u")
	return trim(u) or "?"
end

function M.primary_group()
	local g = shell("id -gn")
	return trim(g) or "?"
end

function M.groups()
	local g = shell("id -Gn")
	if not g then
		return "?"
	end
	return (trim(g):gsub("%s+", ", "))
end

function M.shell()
	local u = M.current_user()
	-- getent passwd <user> -> name:x:uid:gid:gecos:home:shell
	local line = shell("getent passwd " .. u)
	if line then
		local sh = line:match("[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:\n]+)")
		if sh then
			return trim(sh)
		end
	end
	return os.getenv("SHELL") or "?"
end

function M.account_type()
	-- "Administrator" if in wheel/sudo, else "Standard"
	local g = shell("id -Gn") or ""
	if g:match("%f[%w]wheel%f[%W]") or g:match("%f[%w]sudo%f[%W]") then
		return "Administrator"
	end
	return "Standard"
end

-- currently logged-in sessions (read-only)
function M.logged_in()
	local out = shell("who")
	if not out or trim(out) == "" then
		return "?"
	end
	local names = {}
	local seen = {}
	for name in out:gmatch("(%S+)") do
		-- first token of each line is the user; dedupe
		if not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
		break -- only the first token per call... handled below instead
	end
	-- simpler: collect first column of each line
	names = {}
	seen = {}
	for line in out:gmatch("[^\n]+") do
		local u = line:match("^(%S+)")
		if u and not seen[u] then
			seen[u] = true
			names[#names + 1] = u
		end
	end
	return table.concat(names, ", ")
end

-- ── user management support (read side; writes go through pkexec in the UI) ──
-- List "human" login accounts (UID >= 1000, excluding nobody). Returns
-- { {name=, uid=, locked=bool}, ... }. Used by the Users management screen.
function M.human_users()
	local out = shell("getent passwd")
	if not out then
		return {}
	end
	local users = {}
	for line in out:gmatch("[^\n]+") do
		local name, uid = line:match("^([^:]+):[^:]*:(%d+):")
		uid = tonumber(uid)
		if name and uid and uid >= 1000 and uid < 65534 and name ~= "nobody" then
			users[#users + 1] = { name = name, uid = uid }
		end
	end
	-- annotate locked state from passwd -S (needs no root to read status? it does
	-- for others; best-effort). We check `passwd -S <user>` output starting "LK".
	for _, u in ipairs(users) do
		local st = shell("passwd -S " .. u.name .. " 2>/dev/null")
		if st then
			u.locked = st:match("^%S+%s+L") ~= nil
		else
			u.locked = nil
		end
	end
	table.sort(users, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return users
end

return M
