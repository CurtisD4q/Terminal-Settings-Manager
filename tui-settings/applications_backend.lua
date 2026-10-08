-- applications_backend.lua — non-admin Applications settings.
--   Default apps  : get/set browser, mail, file-manager via xdg tools (no root)
--   Autostart     : READ-ONLY merged list from user + system .desktop dirs
--   Installed apps: READ-ONLY count + names (rpm + flatpak)
-- Nothing here needs root. Default-app changes are per-user. Autostart and
-- installed lists are read-only (toggling autostart or uninstalling would mean
-- writing files / root, which is deliberately out of scope).
local M = {}
local util = require("util")

-- Session cache: expensive, rarely-changing lookups (installed apps, autostart,
-- candidate lists) are computed once on first access and reused for the rest of
-- the run. This makes reopening the Applications category instant. Data is
-- fixed for the session; restart the app to pick up newly installed/removed
-- apps or autostart changes. Current default-app values are NOT cached (cheap,
-- and must reflect the user's own changes when they cycle a default).
local CACHE = {}

local function shell(cmd)
	local out, err = util.shell(cmd)
	return out, (err == nil)
end

local function have(bin)
	return util.have(bin)
end

local trim = util.trim

local read_file = util.read_file

-- Resolve a .desktop id (e.g. "org.mozilla.firefox.desktop") to a friendly
-- Name= by finding the file in the standard application dirs. Falls back to
-- the id with the .desktop stripped.
local APP_DIRS = nil
local function app_dirs()
	if APP_DIRS then
		return APP_DIRS
	end
	APP_DIRS = {}
	local home = os.getenv("HOME") or ""
	local cands = {
		home ~= "" and home .. "/.local/share/applications" or nil,
		"/usr/local/share/applications",
		"/usr/share/applications",
		home ~= "" and home .. "/.local/share/flatpak/exports/share/applications" or nil,
		"/var/lib/flatpak/exports/share/applications",
	}
	for _, d in ipairs(cands) do
		APP_DIRS[#APP_DIRS + 1] = d
	end
	return APP_DIRS
end

local function desktop_name(id)
	if not id or id == "" then
		return nil
	end
	local fname = id:match("%.desktop$") and id or (id .. ".desktop")
	for _, dir in ipairs(app_dirs()) do
		local body = read_file(dir .. "/" .. fname)
		if body then
			local name = body:match("\nName=([^\n]+)") or body:match("^Name=([^\n]+)")
			if name then
				return trim(name)
			end
		end
	end
	return (id:gsub("%.desktop$", ""))
end
M.desktop_name = desktop_name

-- Parse every .desktop file across the application dirs ONCE, caching it. Both
-- candidates() and installed_apps() read from this instead of re-scanning the
-- filesystem per call. Previously each of the 8 default types triggered its
-- own full directory scan; now it's a single pass reused everywhere.
local function all_desktops()
	if CACHE.desktops then
		return CACHE.desktops
	end
	local list, seen = {}, {}
	for _, dir in ipairs(app_dirs()) do
		local out = shell("ls -1 " .. util.shquote(dir))
		if out then
			for fname in out:gmatch("[^\n]+") do
				if fname:match("%.desktop$") and not seen[fname] then
					seen[fname] = true
					local body = read_file(dir .. "/" .. fname) or ""
					list[#list + 1] = {
						id = fname,
						name = (body:match("\nName=([^\n]+)") or body:match("^Name=([^\n]+)")),
						mimetypes = body:match("\nMimeType=([^\n]+)") or "",
						nodisplay = body:match("\nNoDisplay=true") ~= nil,
						type = body:match("\nType=([^\n]+)"),
					}
				end
			end
		end
	end
	CACHE.desktops = list
	return list
end

-- All launchable applications (Type=Application, not NoDisplay), sorted by
-- name. This is the full list the default-app picker offers so the user can
-- choose ANY installed app as a default — not only ones that pre-declare the
-- exact MIME type in their .desktop. Returns { {id,name}, ... }.
function M.all_apps()
	local list = {}
	for _, e in ipairs(all_desktops()) do
		local is_app = (e.type == nil) or (e.type == "Application")
		if e.name and not e.nodisplay and is_app then
			list[#list + 1] = { id = e.id, name = trim(e.name) }
		end
	end
	table.sort(list, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return list
end

-- Candidates for a kind, but never empty: if no app advertises the kind's MIME
-- type, fall back to the full installed-app list so the picker always has
-- something to choose from. MIME-matched apps are marked `recommended`.
function M.candidates_or_all(which)
	local cands = M.candidates(which)
	local rec = {}
	for _, c in ipairs(cands) do
		rec[c.id] = true
	end
	local all = M.all_apps()
	local result = {}
	for _, c in ipairs(all) do
		if rec[c.id] then
			result[#result + 1] = { id = c.id, name = c.name, recommended = true }
		end
	end
	for _, c in ipairs(all) do
		if not rec[c.id] then
			result[#result + 1] = { id = c.id, name = c.name, recommended = false }
		end
	end
	return result
end

-- ── default apps ────────────────────────────────────────────────────────────
-- Each "kind" maps to how it's queried/set. Browser has a dedicated
-- xdg-settings verb; the others go through xdg-mime on one or more mimetypes.
-- For multi-MIME kinds, `mime` is the PRIMARY (used for the get/current
-- reading) and `mimes` is the full set that a set-default applies to.
local DEFAULTS = {
	browser = { kind = "browser", mime = "x-scheme-handler/http" },
	mail = { kind = "mime", mime = "x-scheme-handler/mailto" },
	files = { kind = "mime", mime = "inode/directory" },
	-- Text & code share one entry: on Linux there is a single default handler
	-- for text/plain, so "notes" and "code" were really two views of the same
	-- setting. They are merged here into one "text" kind that owns text/plain
	-- plus the common source-code mimetypes.
	text = {
		kind = "mime",
		mime = "text/plain",
		mimes = {
			"text/plain",
			"text/x-python",
			"application/javascript",
			"application/json",
			"text/x-shellscript",
			"text/x-csrc",
			"text/x-c++src",
			"text/x-chdr",
			"text/x-lua",
			"text/markdown",
			"text/x-rustsrc",
			"text/x-go",
			"application/x-yaml",
			"text/x-tex",
		},
	},
	documents = {
		kind = "mime",
		mime = "application/vnd.oasis.opendocument.text",
		mimes = {
			"application/vnd.oasis.opendocument.text",
			"application/msword",
			"application/vnd.openxmlformats-officedocument.wordprocessingml.document",
		},
	},
	presentations = {
		kind = "mime",
		mime = "application/vnd.oasis.opendocument.presentation",
		mimes = {
			"application/vnd.oasis.opendocument.presentation",
			"application/vnd.ms-powerpoint",
			"application/vnd.openxmlformats-officedocument.presentationml.presentation",
		},
	},
	spreadsheets = {
		kind = "mime",
		mime = "application/vnd.oasis.opendocument.spreadsheet",
		mimes = {
			"application/vnd.oasis.opendocument.spreadsheet",
			"application/vnd.ms-excel",
			"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
		},
	},
}

function M.get_default(which)
	local d = DEFAULTS[which]
	if not d then
		return nil
	end
	if not have("xdg-mime") and not have("xdg-settings") then
		return nil, "xdg tools not found"
	end
	local id
	if d.kind == "browser" and have("xdg-settings") then
		id = trim(shell("xdg-settings get default-web-browser"))
	end
	if (not id or id == "") and have("xdg-mime") then
		id = trim(shell("xdg-mime query default " .. d.mime))
	end
	if not id or id == "" then
		return nil, "unset"
	end
	return { id = id, name = desktop_name(id) }, nil
end

-- list installed apps that can handle a given kind, so the UI can cycle among
-- them. For a browser: any .desktop whose MimeType includes the http handler
-- OR that declares a WebBrowser category. Simpler + robust: scan application
-- dirs for entries advertising the relevant mimetype.
function M.candidates(which)
	local d = DEFAULTS[which]
	if not d then
		return {}
	end
	CACHE.cands = CACHE.cands or {}
	if CACHE.cands[which] then
		return CACHE.cands[which]
	end
	local mime = d.mime
	local list = {}
	for _, e in ipairs(all_desktops()) do
		if e.name and not e.nodisplay and e.mimetypes:find(mime, 1, true) then
			list[#list + 1] = { id = e.id, name = trim(e.name) }
		end
	end
	table.sort(list, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	CACHE.cands[which] = list
	return list
end

function M.set_default(which, id)
	local d = DEFAULTS[which]
	if not d then
		return false, "unknown"
	end
	if d.kind == "browser" and have("xdg-settings") then
		local _, ok = shell("xdg-settings set default-web-browser " .. util.shquote(id))
		if ok then
			return true, nil
		end
	end
	if have("xdg-mime") then
		-- apply to every mimetype in the group (or the single primary)
		local mimes = d.mimes or { d.mime }
		local all_ok = true
		for _, mt in ipairs(mimes) do
			local _, ok = shell("xdg-mime default " .. util.shquote(id) .. " " .. util.shquote(mt))
			if not ok then
				all_ok = false
			end
		end
		if all_ok then
			return true, nil
		end
		return false, "some types failed"
	end
	return false, "set failed"
end

-- ── autostart (read-only, merged) ───────────────────────────────────────────
-- Merge ~/.config/autostart (user) over $XDG_CONFIG_DIRS/autostart + the
-- default /etc/xdg/autostart (system). User entries with the same filename
-- override system ones. Reports enabled/disabled from Hidden= and
-- X-GNOME-Autostart-enabled= keys.
local function autostart_dirs()
	local dirs = {}
	local home = os.getenv("HOME") or ""
	-- system dirs first (lower priority), user dir last (overrides)
	local cfgdirs = os.getenv("XDG_CONFIG_DIRS")
	if not cfgdirs or cfgdirs == "" then
		cfgdirs = "/etc/xdg"
	end
	for d in cfgdirs:gmatch("[^:]+") do
		dirs[#dirs + 1] = { path = d .. "/autostart", scope = "system" }
	end
	if home ~= "" then
		dirs[#dirs + 1] = { path = home .. "/.config/autostart", scope = "user" }
	end
	return dirs
end

local function entry_enabled(body)
	-- disabled if Hidden=true or X-GNOME-Autostart-enabled=false
	if body:match("\nHidden=true") or body:match("^Hidden=true") then
		return false
	end
	if body:match("X%-GNOME%-Autostart%-enabled=false") then
		return false
	end
	return true
end

function M.autostart()
	if CACHE.autostart then
		return CACHE.autostart
	end
	local by_name = {} -- filename -> entry (user overrides system)
	for _, d in ipairs(autostart_dirs()) do
		local out = shell("ls -1 " .. util.shquote(d.path))
		if out then
			for fname in out:gmatch("[^\n]+") do
				if fname:match("%.desktop$") then
					local body = read_file(d.path .. "/" .. fname) or ""
					local name = body:match("\nName=([^\n]+)") or body:match("^Name=([^\n]+)")
					by_name[fname] = {
						file = fname,
						name = name and trim(name) or (fname:gsub("%.desktop$", "")),
						enabled = entry_enabled(body),
						scope = d.scope,
					}
				end
			end
		end
	end
	local list = {}
	for _, e in pairs(by_name) do
		list[#list + 1] = e
	end
	table.sort(list, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	CACHE.autostart = list
	return list
end

-- ── installed apps (read-only) ──────────────────────────────────────────────
function M.installed_counts()
	if CACHE.counts then
		return CACHE.counts
	end
	-- System package count comes through the package-manager abstraction, so this
	-- works on any supported distro (dnf/apt/pacman/zypper/apk), not just rpm.
	-- The field stays named `rpm` for the category's existing display, but it now
	-- holds the count from whatever manager this system uses. flatpak is
	-- cross-distro and handled separately.
	local pkgmanager = require("pkgmanager")
	local sys_n = pkgmanager.count()
	local flat_n
	if have("flatpak") then
		local out = shell("flatpak list --app --columns=application | wc -l")
		flat_n = out and tonumber(trim(out)) or nil
	end
	CACHE.counts = { rpm = sys_n, system = sys_n, manager = pkgmanager.name(), flatpak = flat_n }
	return CACHE.counts
end

-- A list of GUI apps (from .desktop entries) is more useful to a person than
-- 3000 rpm packages. Returns sorted unique display names of installed apps
-- that show in menus (no NoDisplay). Reads the cached single-pass parse.
function M.installed_apps()
	if CACHE.apps then
		return CACHE.apps
	end
	local seen, list = {}, {}
	for _, e in ipairs(all_desktops()) do
		if e.name and not e.nodisplay and (not e.type or trim(e.type) == "Application") then
			local nm = trim(e.name)
			if not seen[nm] then
				seen[nm] = true
				list[#list + 1] = nm
			end
		end
	end
	table.sort(list, function(a, b)
		return a:lower() < b:lower()
	end)
	CACHE.apps = list
	return list
end

-- Write the installed-apps list to ~/Downloads as plain text, one app per line.
-- Returns the file path on success, or nil + an error message. Writing is done
-- with io.open (no shell), so app names can't cause injection.
function M.export_installed_apps()
	local home = os.getenv("HOME") or ""
	if home == "" then
		return nil, "no HOME"
	end
	local dir = home .. "/Downloads"
	-- Make sure ~/Downloads exists (mkdir -p is a no-op if it already does).
	util.run("mkdir", "-p", dir)
	local path = dir .. "/installed-apps.txt"
	local f, oerr = io.open(path, "w")
	if not f then
		return nil, oerr or "could not open file"
	end
	local apps = M.installed_apps()
	for _, name in ipairs(apps) do
		f:write(name, "\n")
	end
	f:close()
	return path, nil
end

-- ── installed packages, grouped by family (read-only) ───────────────────────
-- Groups the full rpm package set by a family name and hides base/protected
-- packages (the ones dnf itself won't remove). The TOTAL count stays honest
-- (all packages), only the displayed grouping is condensed/filtered.
--
-- Protected set comes from /etc/dnf/protected.d/*.conf (fast file reads, no
-- dnf invocation) plus a small hardcoded base-system list. Cached per session.

-- Prefixes where splitting on the first "-" would over-collapse everything
-- into one huge blob; for these we keep two segments as the family.
local TWO_SEG_PREFIXES = {
	lib = true,
	python3 = true,
	python2 = true,
	perl = true,
	rust = true,
	golang = true,
	ghc = true,
	nodejs = true,
	php = true,
	ruby = true,
	["rubygem"] = true,
}

-- hardcoded base/essential families never worth listing as removable
local BASE_ALWAYS = {
	kernel = true,
	glibc = true,
	systemd = true,
	dnf = true,
	rpm = true,
	bash = true,
	coreutils = true,
	filesystem = true,
	setup = true,
	["ca-certificates"] = true,
	["dnf-data"] = true,
	["rpm-libs"] = true,
	sudo = true,
	util = true,
	["gnupg2"] = true,
	grub2 = true,
	shim = true,
	dracut = true,
	systemd = true,
}

local function family_of(pkgname)
	-- pkgname is the bare NAME (no version). Derive a grouping key.
	local first = pkgname:match("^([^%-]+)")
	if first and TWO_SEG_PREFIXES[first] then
		local two = pkgname:match("^([^%-]+%-[^%-]+)")
		return two or pkgname
	end
	return first or pkgname
end

local function load_protected()
	local prot = {}
	-- read every *.conf in /etc/dnf/protected.d/ — one package name per line
	local out = shell("cat /etc/dnf/protected.d/*.conf 2>/dev/null")
	if out then
		for line in out:gmatch("[^\n]+") do
			local name = line:gsub("%s+", "")
			if name ~= "" and not name:match("^#") then
				prot[name] = true
			end
		end
	end
	return prot
end

-- Returns:
--   groups : sorted list of { family=, count= } after filtering base/protected
--   total  : honest total package count (unfiltered, ungrouped)
--   hidden : how many packages were filtered out as base/protected
function M.package_families()
	if CACHE.pkgfam then
		return CACHE.pkgfam
	end
	local pkgmanager = require("pkgmanager")
	if not pkgmanager.available() then
		CACHE.pkgfam = { groups = {}, total = nil, hidden = 0, err = "no package manager" }
		return CACHE.pkgfam
	end
	-- list_names() returns installed package names for whatever manager this
	-- system uses (rpm/dpkg/pacman/apk), so the grouping below is distro-neutral.
	local names = pkgmanager.list_names()
	if #names == 0 then
		CACHE.pkgfam = { groups = {}, total = nil, hidden = 0, err = "package query failed" }
		return CACHE.pkgfam
	end
	local total = 0
	local hidden = 0
	local fam_count = {}
	local fam_members = {}
	for _, name in ipairs(names) do
		total = total + 1
		local fam = family_of(name)
		-- filter: hide if the package is protected (per the manager, generalized)
		-- or its family is in our base list
		if pkgmanager.is_protected(name) or BASE_ALWAYS[fam] then
			hidden = hidden + 1
		else
			fam_count[fam] = (fam_count[fam] or 0) + 1
			fam_members[fam] = fam_members[fam] or {}
			fam_members[fam][#fam_members[fam] + 1] = name
		end
	end
	local groups = {}
	for fam, n in pairs(fam_count) do
		-- expose the exact package name only for singleton families (so the UI can
		-- offer single-package uninstall safely; multi-package families are not
		-- individually removable from this view)
		local pkg = (n == 1) and fam_members[fam][1] or nil
		groups[#groups + 1] = { family = fam, count = n, package = pkg }
	end
	table.sort(groups, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end -- biggest families first
		return a.family:lower() < b.family:lower()
	end)
	CACHE.pkgfam = { groups = groups, total = total, hidden = hidden }
	return CACHE.pkgfam
end

return M
