#!/usr/bin/env lua5.4
-- a1_networkpass.lua — password-entry screen for joining a secured Wi-Fi
-- network. Not a category; a helper invoked by a1_network.lua. Exposes
-- prompt_and_connect(ssid) which shows the masked password screen, then
-- attempts the connection. Returns:
--   true            connected
--   false, reason   attempted but failed (e.g. wrong password)
--   nil             user cancelled (Esc)
local dir = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = dir.."/?.lua;"..package.path
local core = require("core")
local net = require("network_backend")

local M = {}

function M.prompt_and_connect(ssid)
  local pw = core.run_password_prompt(
    "Connect to "..ssid,
    "Enter the network password"
  )
  if pw == nil then return nil end          -- cancelled
  if pw == "" then return false, "no password entered" end
  return net.connect_with_password(ssid, pw)
end

-- allow standalone testing: `lua a1_networkpass.lua <ssid>`
if not package.loaded["__settings_home__"] and arg and arg[1] then
  core.screen_enter()
  local ok, res, reason = pcall(M.prompt_and_connect, arg[1])
  core.screen_leave()
  if not ok then io.stderr:write("error: "..tostring(res).."\n"); os.exit(1) end
  if res == nil then print("cancelled")
  elseif res == true then print("connected")
  else print("failed: "..tostring(reason)) end
  os.exit(0)
end

return M
