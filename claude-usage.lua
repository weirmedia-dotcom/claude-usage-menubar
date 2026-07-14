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
local COST_STATE = CACHE .. "/cost-state.json"
local COST_SCAN = CACHE .. "/cost-scan.sh"

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

local function readCost()
  local ok, t = pcall(function() return hs.json.read(COST_STATE) end)
  if ok and type(t) == "table" then return t end
  return nil
end

local function fmtTokens(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.0fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
  return tostring(n)
end

local function draw()
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
    -- model-scoped weekly limits (Fable, Opus, ...) reported by the usage endpoint
    if type(g.scoped) == "table" then
      for _, s in ipairs(g.scoped) do
        if s.pct ~= nil then
          menu[#menu+1] = { title = "-" }
          menu[#menu+1] = { title = (s.label or "Model") .. " weekly limit" }
          menu[#menu+1] = { title = "    " .. round(s.pct) .. "% used" }
          if s.reset_str then menu[#menu+1] = { title = "    resets " .. s.reset_str } end
        end
      end
    end
  end

  -- rolling 7-day token usage priced at API rates (from cost-scan.sh)
  local cost = readCost()
  if cost and type(cost.models) == "table" and #cost.models > 0 then
    menu[#menu+1] = { title = "-" }
    menu[#menu+1] = { title = string.format("Last 7 days · API value $%.2f", cost.total_usd or 0) }
    for _, m in ipairs(cost.models) do
      local price = m.usd and string.format("$%.2f", m.usd) or "?"
      menu[#menu+1] = {
        title = string.format("    %s  %s · %s tok", m.label or "?", price, fmtTokens(m.total_tokens)),
      }
    end
  end

  if not fresh then
    if #menu > 0 then menu[#menu+1] = { title = "-" } end
    menu[#menu+1] = { title = M.refreshing and "Refreshing …" or "Fetching real % …" }
  end
  menu[#menu+1] = { title = "-" }
  menu[#menu+1] = {
    title = M.refreshing and "Refreshing …" or "Refresh now",
    fn = M.refreshing and function() end or M.forceRefresh,
    disabled = M.refreshing and true or false,
  }
  bar:setMenu(menu)
end

-- periodic tick: redraws every minute (countdown) and fires a normal, backoff-respecting
-- fetch in the background (a no-op if we already fetched recently)
local function refresh()
  hs.task.new("/bin/bash", function() return true end, { FETCH }):start()
  draw()
end

-- manual "Refresh now": bypasses the backoff, waits for the fetch to actually finish,
-- then redraws with the fresh data. This is the fix for the button silently no-op'ing
-- when clicked inside the normal ~10-min polling window.
function M.forceRefresh()
  if M.refreshing then return end
  M.refreshing = true
  draw()  -- show "Refreshing …" immediately
  hs.task.new("/bin/bash", function()
    M.refreshing = false
    draw()
  end, { FETCH, "--force" }):start()
end

local function costScan()
  hs.task.new("/bin/bash", function() draw() end, { COST_SCAN }):start()
end

draw()
refresh()
costScan()
M.timer = hs.timer.doEvery(60, refresh)  -- redraw + tick countdown, and opportunistically fetch
M.costTimer = hs.timer.doEvery(900, costScan)  -- 7-day cost rescan every 15 min (incremental)
_G.CLAUDE_USAGE_LOADED = true             -- marker the doctor script checks
return M
