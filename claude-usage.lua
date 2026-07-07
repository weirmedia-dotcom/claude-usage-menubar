-- Claude usage in the macOS menu bar (Hammerspoon module)
-- Shows the Claude "spark" + current 5-hour window %, plus a countdown to reset.
-- Click for a dropdown with the 5-hour and weekly limits and their reset times.
--
-- Loaded from ~/.hammerspoon/init.lua via:  require("claude-usage")

local M = {}

local HOME  = os.getenv("HOME")
local CACHE = HOME .. "/.cache/claude-usage-menubar"
local STATE = CACHE .. "/poll-state.json"
local FETCH = CACHE .. "/fetch.sh"

pcall(require, "hs.ipc")  -- enable the `hs` command-line tool (for headless diagnostics)
hs.menuIcon(false)        -- hide Hammerspoon's own hammer icon (delete this line to keep it)

local bar = hs.menubar.new()
if not bar then
  hs.alert.show("Claude usage: could not create a menu bar item")
  return {}
end

-- the Claude "spark" burst as a template icon (adapts to light/dark menu bar)
local function claudeIcon()
  local sz = 36
  local c = hs.canvas.new({ x = 0, y = 0, w = sz, h = sz })
  local cx, cy = sz / 2, sz / 2
  local rays = 12
  local inner, outer = sz * 0.015, sz * 0.44
  local els = {}
  for i = 0, rays - 1 do
    local a = (i / rays) * 2 * math.pi - math.pi / 2
    els[#els + 1] = {
      type = "segments",
      coordinates = {
        { x = cx + inner * math.cos(a), y = cy + inner * math.sin(a) },
        { x = cx + outer * math.cos(a), y = cy + outer * math.sin(a) },
      },
      action = "stroke",
      strokeColor = { white = 0, alpha = 1 },
      strokeWidth = sz * 0.075,
      strokeCapStyle = "butt",
    }
  end
  c:replaceElements(els)
  return c:imageFromCanvas():setSize({ w = 16, h = 16 }):template(true)
end
local ICON = claudeIcon()

local function readState()
  local ok, t = pcall(function() return hs.json.read(STATE) end)
  if ok and type(t) == "table" then return t end
  return {}
end

local function round(x) return math.floor(tonumber(x) + 0.5) end

local function refresh()
  -- fire the background fetcher (self-gated to ~10 min via poll-state next_ok)
  hs.task.new("/bin/bash", function() return true end, { FETCH }):start()

  local st  = readState()
  local g   = st.last_good or {}
  local pct = g.pct5
  -- Keep showing the last good value while its 5-hour window is still live (the countdown
  -- is computed live from the reset time, so it stays accurate even if a refresh is late).
  -- Only fall back to "…" if we've never fetched, or the window has actually reset.
  local rem = (tonumber(g.reset5_epoch) or 0) - os.time()
  local fresh = pct ~= nil and (rem > 0 or (os.time() - (g.ts or 0)) < 1800)

  bar:setIcon(ICON)
  local cd = ""
  if fresh and g.reset5_epoch then
    local rem = tonumber(g.reset5_epoch) - os.time()
    if rem > 0 then
      local h = math.floor(rem / 3600)
      local m = math.floor((rem % 3600) / 60)
      cd = " · " .. (h > 0 and (h .. "h" .. string.format("%02d", m) .. "m") or (m .. "m"))
    end
  end
  bar:setTitle(fresh and (" " .. round(pct) .. "%" .. cd) or " …")

  local menu = {}
  if fresh then
    menu[#menu+1] = { title = "5-hour window" }
    menu[#menu+1] = { title = "    " .. round(pct) .. "% used" }
    if g.reset5_str then menu[#menu+1] = { title = "    resets " .. g.reset5_str } end
    if g.pct7 ~= nil then
      menu[#menu+1] = { title = "-" }
      menu[#menu+1] = { title = "Weekly limit" }
      menu[#menu+1] = { title = "    " .. round(g.pct7) .. "% used" }
      if g.reset7_str then menu[#menu+1] = { title = "    resets " .. g.reset7_str } end
    end
  else
    menu[#menu+1] = { title = "Fetching real % …" }
  end
  menu[#menu+1] = { title = "-" }
  menu[#menu+1] = { title = "Refresh now", fn = refresh }
  bar:setMenu(menu)
end

refresh()
M.timer = hs.timer.doEvery(60, refresh)  -- redraw + tick countdown every minute
_G.CLAUDE_USAGE_LOADED = true             -- marker the doctor script checks
return M
