#!/usr/bin/env lua5.4
-- Kernel & Boot (App 2) — read-only introspection of the running kernel,
-- installed kernels, boot command line, bootloader, and modules. Everything
-- here is unprivileged and non-destructive (this pass makes no changes to the
-- system). Values are static for a session, so they're cached once.
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path
local core = require("core")
local kb = require("kernel_boot_backend")

local CAT -- forward-declared so prefetch can rebuild sections

-- one-time cache: none of this changes during a session
local sc = {}
local function once(key, fn)
	if sc[key] == nil then
		local ok, v = pcall(fn)
		sc[key] = ok and v or false
	end
	if sc[key] == false then
		return nil
	end
	return sc[key]
end

-- ── section builders ─────────────────────────────────────────────────────────

local function kernel_rows()
	local rows = {}
	rows[#rows + 1] = { "Running version", once("run", kb.running_kernel) or "—", "" }
	rows[#rows + 1] = { "Architecture", once("arch", kb.arch) or "—", "" }

	local installed = once("installed", kb.installed_kernels)
	if installed and #installed > 0 then
		rows[#rows + 1] = { "Installed", #installed .. " version" .. (#installed == 1 and "" or "s"), "" }
		local running = once("run", kb.running_kernel)
		for _, v in ipairs(installed) do
			local marker = (running and v == running) and "  ● running" or ""
			rows[#rows + 1] = { "  " .. v, marker, "" }
		end
	else
		rows[#rows + 1] = { "Installed", "—", "" }
	end
	return rows
end

local function cmdline_rows()
	local params = once("cmdline", kb.cmdline_params)
	if not params or #params == 0 then
		return { { "Parameters", "—", "" } }
	end
	local rows = {}
	rows[#rows + 1] = { "Parameters", #params .. " total", "" }
	local line, count = {}, 0
	local function flush()
		if #line > 0 then
			rows[#rows + 1] = { "  " .. table.concat(line, "  "), "", "" }
			line, count = {}, 0
		end
	end
	for _, p in ipairs(params) do
		line[#line + 1] = p
		count = count + 1
		if count >= 3 then
			flush()
		end
	end
	flush()
	return rows
end

local function bootloader_rows()
	local rows = {}
	rows[#rows + 1] = { "Type", once("bl", kb.bootloader) or "unknown", "" }
	rows[#rows + 1] = { "Default entry", once("default", kb.default_entry) or "—", "" }
	local timeout = once("timeout", kb.boot_timeout)
	rows[#rows + 1] = { "Menu timeout", timeout and (timeout .. " s") or "—", "" }

	local entries = once("entries", kb.boot_entries)
	if entries and #entries > 0 then
		rows[#rows + 1] = { "Entries", tostring(#entries), "" }
		for _, e in ipairs(entries) do
			rows[#rows + 1] = { "  " .. e.title, "", "" }
		end
	end

	local bt = once("boottime", kb.boot_time)
	if bt then
		rows[#rows + 1] = { "Last boot time", bt, "" }
	end
	return rows
end

local function module_rows()
	local rows = {}
	local n = once("modcount", kb.loaded_module_count)
	rows[#rows + 1] = { "Loaded modules", n and tostring(n) or "—", "" }

	local blk = once("blacklist", kb.blacklisted_modules)
	if blk and #blk > 0 then
		rows[#rows + 1] = { "Blacklisted", tostring(#blk), "" }
		for _, m in ipairs(blk) do
			rows[#rows + 1] = { "  " .. m, "", "" }
		end
	else
		rows[#rows + 1] = { "Blacklisted", "none", "" }
	end

	local lock = once("lockdown", kb.lockdown)
	if lock then
		rows[#rows + 1] = { "Kernel lockdown", lock, "" }
	end
	return rows
end

-- ── prefetch ────────────────────────────────────────────────────────────────

-- Curated maintenance one-shots. Rebuilding the initramfs is privileged and
-- consequential (a bad initramfs can prevent boot), so the confirmation is
-- explicit. Nothing free-form.
local function maintenance_rows()
	return {
		{
			"Rebuild initramfs (current kernel)",
			"",
			"button",
			{
				get = function()
					return "run"
				end,
				set = function()
					local running = once("run", kb.running_kernel) or "current kernel"
					local ok = core.run_confirm(
						"Rebuild initramfs for " .. running .. "?",
						"Regenerates the boot image (dracut -f) for the running\nkernel. Use after driver/config changes. A failed rebuild\ncan affect boot — only proceed if you know why you need it."
					)
					if ok then
						core.run_pkexec(kb.cmd_rebuild_initramfs(), "Rebuild initramfs (current kernel)")
					end
				end,
			},
		},
		{
			"Rebuild initramfs (all kernels)",
			"",
			"button",
			{
				get = function()
					return "run"
				end,
				set = function()
					local ok = core.run_confirm(
						"Rebuild initramfs for ALL installed kernels?",
						"Regenerates boot images for every installed kernel\n(dracut -f --regenerate-all). Slower. Same caution applies:\na failed rebuild can affect boot."
					)
					if ok then
						core.run_pkexec(kb.cmd_rebuild_initramfs_all(), "Rebuild initramfs (all kernels)")
					end
				end,
			},
		},
	}
end

local function prefetch()
	CAT.sections[1][2] = kernel_rows()
	CAT.sections[2][2] = cmdline_rows()
	CAT.sections[3][2] = bootloader_rows()
	CAT.sections[4][2] = module_rows()
	CAT.sections[5][2] = maintenance_rows()
end

CAT = {
	id = "kernel_boot",
	label = "Kernel & Boot",
	icon = "◈",
	sections = {
		{ "Kernel", { { "Loading…", "", "" } } },
		{ "Boot Command Line", { { "Loading…", "", "" } } },
		{ "Boot Loader", { { "Loading…", "", "" } } },
		{ "Modules", { { "Loading…", "", "" } } },
		{ "Maintenance", { { "Loading…", "", "" } } },
	},
	prefetch = prefetch,
}

return core.define_category(CAT)
