-- provider.lua — encapsulated driver selection for swappable subsystems.
--
-- Several subsystems (firewall, and later networking, etc.) have more than one
-- real implementation across the Linux systems that run Sway: a firewall might
-- be firewalld, ufw, or nftables. Categories should not know or care which one
-- is present — they should call a stable interface and get an answer.
--
-- This module provides that, with encapsulation as a hard guarantee rather than
-- a convention:
--
--   * The caller hands in an ordered list of drivers and the names of the
--     interface methods.
--   * It gets back a SEALED PROXY that forwards ONLY those named methods to
--     whichever driver is present. The proxy exposes nothing else.
--   * The driver list, the resolved choice, and all detection state are
--     PRIVATE to the closure — there is no field on the returned object that
--     leaks them, so no caller can reach a specific driver, discover which one
--     won (except via an explicit interface method), or mutate the selection.
--
-- Contract each driver must satisfy:
--   driver:available()  -> boolean   (is this implementation usable here?)
--   driver:<method>(...) for every name in interface_methods
-- Drivers are plain tables with methods; they own all their own internals
-- (tool name, command syntax, privilege handling) and expose only the contract.
local M = {}

-- Build a sealed provider proxy.
--   drivers            : ordered list; first available() wins (priority order)
--   interface_methods  : list of method names the proxy will forward
-- Returns a proxy table with exactly those methods plus available().
function M.select(drivers, interface_methods)
	-- PRIVATE state, captured in this closure and never exposed on the proxy.
	local resolved = nil -- nil = not yet resolved, false = none, table = driver

	local function resolve()
		if resolved ~= nil then
			return resolved or nil
		end
		for _, d in ipairs(drivers) do
			local ok, present = pcall(function()
				return d:available()
			end)
			if ok and present then
				resolved = d
				return d
			end
		end
		resolved = false
		return nil
	end

	local proxy = {}

	-- Forward each named interface method to the resolved driver. If nothing is
	-- available, calls return (nil, reason) uniformly so callers never crash on
	-- a missing subsystem.
	for _, name in ipairs(interface_methods) do
		proxy[name] = function(...)
			local d = resolve()
			if not d then
				return nil, "no provider available"
			end
			return d[name](d, ...)
		end
	end

	-- Whether any implementation is present. The only selection detail exposed.
	function proxy.available()
		return resolve() ~= nil
	end

	return proxy
end

return M
