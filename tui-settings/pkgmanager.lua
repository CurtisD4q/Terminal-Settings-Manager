-- pkgmanager.lua — package-manager abstraction.
-- env.package_manager() identifies WHICH manager the system uses; this module
-- provides the OPERATIONS the Package Management category needs, dispatched to
-- the right per-manager implementation. Categories call these functions and
-- never touch rpm/apt/pacman directly, so adding a distro means adding a driver
-- here, not editing the category.
--
-- Operations (kept to what the category actually uses):
--   available()      -> is a usable manager present
--   name()           -> the manager's name ("dnf", "apt", ...)
--   list_names()     -> sorted list of installed package NAMES
--   count()          -> total installed package count (nil if unknown)
--   remove_cmd(pkg)  -> privileged command STRING to uninstall (run via pkexec)
--   is_protected(pkg)-> should this package be hidden from removal
--
-- Note: flatpak is cross-distro and not a system package manager, so it stays
-- handled separately by the category; this module is about the SYSTEM manager.
local M = {}
local util = require("util")
local env = require("env")

-- ── driver interface ─────────────────────────────────────────────────────────
-- Each driver is a table with:
--   bin        : the binary that must exist for this driver to be usable
--   list_names : function() -> list of package name strings
--   count      : function() -> number or nil
--   remove_cmd : function(pkg) -> command string (unprivileged form; the caller
--                wraps it in pkexec)
-- Drivers use util.run_lines / util.run_value so returns are unambiguous.

local drivers = {}

-- dnf / rpm (Fedora, RHEL, CentOS). rpm is the query layer; dnf the transaction
-- layer. zypper systems also use rpm for queries, so they reuse the readers.
local function rpm_list_names()
	-- one name per line
	return util.run_lines("rpm", "-qa", "--qf", "%{NAME}\\n")
end
local function rpm_count()
	-- cheap: emit one byte per package, count bytes
	local out = util.shell_value("rpm -qa --qf '.' | wc -c")
	return out and tonumber(out) or nil
end

drivers.dnf = {
	bin = "rpm", -- queries go through rpm even when dnf drives transactions
	list_names = rpm_list_names,
	count = rpm_count,
	remove_cmd = function(pkg)
		return "dnf remove -y " .. util.shquote(pkg)
	end,
}

drivers.zypper = {
	bin = "rpm",
	list_names = rpm_list_names,
	count = rpm_count,
	remove_cmd = function(pkg)
		return "zypper remove -y " .. util.shquote(pkg)
	end,
}

-- apt / dpkg (Debian, Ubuntu). dpkg-query is the reader; apt-get the remover.
drivers.apt = {
	bin = "dpkg-query",
	list_names = function()
		return util.run_lines("dpkg-query", "-W", "-f", "${Package}\\n")
	end,
	count = function()
		local out = util.shell_value("dpkg-query -W -f '.' | wc -c")
		return out and tonumber(out) or nil
	end,
	remove_cmd = function(pkg)
		return "apt-get remove -y " .. util.shquote(pkg)
	end,
}

-- pacman (Arch, Manjaro). -Qq lists installed package names quietly.
drivers.pacman = {
	bin = "pacman",
	list_names = function()
		return util.run_lines("pacman", "-Qq")
	end,
	count = function()
		local lines = util.run_lines("pacman", "-Qq")
		return #lines > 0 and #lines or nil
	end,
	remove_cmd = function(pkg)
		return "pacman -R --noconfirm " .. util.shquote(pkg)
	end,
}

-- apk (Alpine). `apk info` lists installed package names.
drivers.apk = {
	bin = "apk",
	list_names = function()
		return util.run_lines("apk", "info")
	end,
	count = function()
		local lines = util.run_lines("apk", "info")
		return #lines > 0 and #lines or nil
	end,
	remove_cmd = function(pkg)
		return "apk del " .. util.shquote(pkg)
	end,
}

-- ── driver selection ─────────────────────────────────────────────────────────

-- The active driver for this system, or nil. Chosen from env's detected
-- package manager, but only if the driver's query binary is actually present.
local function current_driver()
	if M._driver ~= nil then
		if M._driver == false then
			return nil
		end
		return M._driver
	end
	local pm = env.package_manager()
	local d = drivers[pm]
	if d and util.have(d.bin) then
		M._driver = d
		M._name = pm
		return d
	end
	M._driver = false
	return nil
end

-- ── public operations ────────────────────────────────────────────────────────

-- Is a usable system package manager present?
function M.available()
	return current_driver() ~= nil
end

-- The active manager's name ("dnf"/"apt"/"pacman"/...), or "unknown".
function M.name()
	current_driver()
	return M._name or "unknown"
end

-- Sorted, de-duplicated list of installed package names. Empty list if no
-- manager is available (never nil), so callers can ipairs() freely.
function M.list_names()
	local d = current_driver()
	if not d then
		return {}
	end
	local raw = d.list_names()
	local seen, list = {}, {}
	for _, n in ipairs(raw) do
		if n ~= "" and not seen[n] then
			seen[n] = true
			list[#list + 1] = n
		end
	end
	table.sort(list)
	return list
end

-- Total installed package count, or nil if the manager can't report it.
function M.count()
	local d = current_driver()
	if not d then
		return nil
	end
	return d.count()
end

-- The privileged uninstall command string for a package (caller runs it via
-- pkexec). Returns nil if there's no manager. The package name is shell-quoted
-- inside the driver, so odd names can't break the command.
function M.remove_cmd(pkg)
	local d = current_driver()
	if not d then
		return nil
	end
	return d.remove_cmd(pkg)
end

-- ── protected packages (generalized) ─────────────────────────────────────────
-- Only dnf has a first-class "protected packages" concept (packages it refuses
-- to remove). We honor it where it exists and return false elsewhere, so the
-- category's hide-protected logic works uniformly without assuming Fedora.

local protected_cache = nil
local BASE_PROTECTED = {
	kernel = true,
	glibc = true,
	systemd = true,
	bash = true,
	sudo = true,
	dnf = true,
	rpm = true,
	apt = true,
	dpkg = true,
	pacman = true,
	apk = true,
	["apt-get"] = true,
	coreutils = true,
	util = true,
}

local function load_protected()
	if protected_cache then
		return protected_cache
	end
	local set = {}
	for k in pairs(BASE_PROTECTED) do
		set[k] = true
	end
	-- dnf's protected.d config, if present (Fedora/RHEL). Harmless elsewhere.
	local lines = util.shell_lines("cat /etc/dnf/protected.d/*.conf 2>/dev/null")
	for _, name in ipairs(lines) do
		if name ~= "" and not name:match("^#") then
			set[name] = true
		end
	end
	protected_cache = set
	return set
end

-- Should this package be hidden from the removable list? True for base/system
-- packages the manager protects (or our conservative base list). This keeps the
-- category from offering to uninstall something that would break the system.
function M.is_protected(pkg)
	return load_protected()[pkg] == true
end

return M
