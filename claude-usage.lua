-- Claude usage in the macOS menu bar (Hammerspoon module)
-- Shows the Claude "spark" + current 5-hour window % (weekly % on plans without a
-- 5-hour window, e.g. Ultra), plus a countdown to reset.
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
local CREDITS_STATE = CACHE .. "/credits-state.json"
local CREDITS = CACHE .. "/credits.sh"

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

-- The Claude spark as a gauge: its 12 rays fill clockwise from 12 o'clock with the
-- headline % (each ray ~8.3%, the current ray fills partway along its length), unused
-- rays stay faint, and the ray at the even-pace point reaches further out. A template
-- (follows the menu bar's light/dark) until 75%, then amber, red from 90%.
local sparkCache = {}
local function sparkIcon(pct, evenPct)
  pct = math.max(0, math.min(100, math.floor(tonumber(pct) or 0)))
  local rays = 12
  local paceRay = evenPct and math.min(rays - 1, math.floor(math.max(0, evenPct) / 100 * rays)) or -1
  local key = pct .. ":" .. paceRay
  if sparkCache[key] then return sparkCache[key] end
  local sz = 36
  local cx, cy = sz / 2, sz / 2
  local inner, outer, paceOuter = sz * 0.06, sz * 0.40, sz * 0.5
  local warm = pct >= 75
  local lit = pct >= 90 and { red = 0.94, green = 0.36, blue = 0.32, alpha = 1 }
           or warm and { red = 0.91, green = 0.64, blue = 0.24, alpha = 1 }
           or { white = 0, alpha = 1 }
  local faint = warm and { white = 0.5, alpha = 0.5 } or { white = 0, alpha = 0.28 }
  local filled = pct / 100 * rays
  local els = {}
  local function ray(a, r0, r1, color)
    els[#els + 1] = {
      type = "segments", action = "stroke", strokeColor = color,
      strokeWidth = sz * 0.085, strokeCapStyle = "round",
      coordinates = {
        { x = cx + r0 * math.cos(a), y = cy + r0 * math.sin(a) },
        { x = cx + r1 * math.cos(a), y = cy + r1 * math.sin(a) },
      },
    }
  end
  for i = 0, rays - 1 do
    local a = (i / rays) * 2 * math.pi - math.pi / 2
    local len = (i == paceRay) and paceOuter or outer
    ray(a, inner, len, faint)
    local f = math.max(0, math.min(1, filled - i))
    if f > 0 then ray(a, inner, inner + (len - inner) * f, lit) end
  end
  local c = hs.canvas.new({ x = 0, y = 0, w = sz, h = sz })
  c:replaceElements(els)
  local img = c:imageFromCanvas():setSize({ w = 16, h = 16 })
  if not warm then img = img:template(true) end
  c:delete()
  sparkCache[key] = img
  return img
end
M.sparkIcon = sparkIcon   -- for headless icon previews

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

-- One-shot macOS notifications so a dead widget doesn't rely on Mark noticing a
-- blank menu bar item. Debounced in-memory: fires once per state transition, not
-- every 60s tick, and clears itself once things recover.
local function notifyOnce(key, title, text)
  if M["_notified_" .. key] then return end
  M["_notified_" .. key] = true
  hs.notify.new({ title = title, informativeText = text }):send()
end
local function clearNotify(key) M["_notified_" .. key] = nil end

local function draw()
  local st  = readState()
  local g   = st.last_good or {}
  local pct = g.pct5

  if st.auth_error == true then
    clearNotify("stale")
    bar:setIcon(ICON)
    bar:setTitle(" ⚠︎ login")
    notifyOnce("auth", "Claude usage widget",
      "Claude Code is logged out, so usage % can't be fetched. Click the menu bar item → Log in to Claude Code.")
    M.menu = {
      { title = "Claude Code is logged out" },
      {
        title = M.loginPolling and "Waiting for login …" or "Log in to Claude Code …",
        fn = M.loginPolling and function() end or M.login,
        disabled = M.loginPolling and true or false,
      },
      { title = "-" },
      {
        title = M.refreshing and "Refreshing …" or "Refresh now",
        fn = M.refreshing and function() end or M.forceRefresh,
        disabled = M.refreshing and true or false,
      },
    }
    if M.panelUpdate then M.panelUpdate() end
    return
  end
  clearNotify("auth")

  -- Ultra (ex Max 20x, Oct 2026) has no 5-hour window, only the weekly limit. Headline
  -- whichever window the plan actually has: 5-hour if present, else weekly.
  local weeklyOnly = pct == nil and g.pct7 ~= nil
  local headReset = g.reset5_epoch
  if weeklyOnly then pct, headReset = g.pct7, g.reset7_epoch end

  -- Keep showing the last good value while its window is still live (the countdown
  -- is computed live from the reset time, so it stays accurate even if a refresh is late).
  -- Only fall back to "…" if we've never fetched, or the window has actually reset.
  -- A weekly window lives for days, so cap how long a weekly-only value may go unrefreshed.
  local age = os.time() - (g.ts or 0)
  local rem = (tonumber(headReset) or 0) - os.time()
  local fresh = pct ~= nil and ((rem > 0 and (not weeklyOnly or age < 6 * 3600)) or age < 1800)

  if fresh then clearNotify("stale")
  else
    notifyOnce("stale", "Claude usage widget",
      "Usage % hasn't refreshed in a while — check Hammerspoon, or run `claude auth login` if it turns out to be a login problem.")
  end

  -- even-pace point: how far through the headline window we are
  local evenPct
  if fresh and headReset then
    local win = weeklyOnly and 7 * 86400 or 5 * 3600
    local r = tonumber(headReset) - os.time()
    if r > 0 and r <= win then evenPct = (1 - r / win) * 100 end
  end
  bar:setIcon(fresh and sparkIcon(pct, evenPct) or ICON)
  local cd = ""
  if fresh and headReset then
    local rem = tonumber(headReset) - os.time()
    if rem > 0 then
      local d = math.floor(rem / 86400)
      local h = math.floor((rem % 86400) / 3600)
      local m = math.floor((rem % 3600) / 60)
      if d > 0 then cd = " · " .. d .. "d" .. string.format("%02d", h) .. "h"
      elseif h > 0 then cd = " · " .. h .. "h" .. string.format("%02d", m) .. "m"
      else cd = " · " .. m .. "m" end
    end
  end
  bar:setTitle(fresh and (" " .. round(pct) .. "%" .. cd) or " …")

  local menu = {}
  if fresh then
    if not weeklyOnly then
      menu[#menu+1] = { title = "5-hour window" }
      menu[#menu+1] = { title = "    " .. round(pct) .. "% used" }
      if g.reset5_str then menu[#menu+1] = { title = "    resets " .. g.reset5_str } end
    else
      menu[#menu+1] = { title = "No 5-hour window on this plan" }
    end
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

  -- Console API credits (monthly plan grant + purchased balance), from credits.sh
  local ok, cr = pcall(function() return hs.json.read(CREDITS_STATE) end)
  if ok and type(cr) == "table" and (cr.error or cr.ts) then
    menu[#menu+1] = { title = "-" }
    for _, p in ipairs(type(cr.promo) == "table" and cr.promo or {}) do
      local days = p.expires_epoch and math.floor((p.expires_epoch - os.time()) / 86400)
      menu[#menu+1] = { title = string.format("API credits  $%.2f of $%.0f%s", p.remaining or 0, p.granted or 0,
        p.expires_str and (" · expires " .. p.expires_str .. (days and days >= 0 and (" (" .. days .. "d)") or "")) or "") }
      if p.per_day then
        menu[#menu+1] = { title = string.format("    pace $%.2f/day → ~$%.0f unused at expiry", p.per_day, p.unused_at_expiry or 0) }
      end
    end
    if cr.paid then menu[#menu+1] = { title = string.format("    paid balance $%.2f", cr.paid) } end
    if cr.error == "auth" or cr.error == "no_cookie" then
      menu[#menu+1] = { title = "    ⚠︎ Console login expired: re-copy cookie (wmpe-secrets CLAUDE_CONSOLE_SESSION_KEY)" }
    elseif cr.error then
      menu[#menu+1] = { title = "    ⚠︎ credits not refreshed (" .. tostring(cr.error) .. ")" }
    end
  end

  -- rolling token usage priced at API rates + senior-dev labor equivalent
  -- (from cost-scan.sh; 7-day and 30-day windows)
  local cost = readCost()
  if cost and type(cost.windows) == "table" then
    for _, w in ipairs(cost.windows) do
      if type(w.models) == "table" and #w.models > 0 then
        menu[#menu+1] = { title = "-" }
        menu[#menu+1] = { title = string.format("%s · API value CA$%.0f", w.label or "Window", w.total_cad or w.total_usd or 0) }
        for _, m in ipairs(w.models) do
          local v = m.cad or m.usd
          local price = v and string.format("CA$%.2f", v) or "?"
          menu[#menu+1] = {
            title = string.format("    %s  %s · %s tok", m.label or "?", price, fmtTokens(m.total_tokens)),
          }
        end
        if w.dev_hours and w.dev_cad then
          menu[#menu+1] = {
            title = string.format("    ≈ %.0f contract dev-hours · CA$%s at CA$%d/hr",
              w.dev_hours, tostring(w.dev_cad), w.dev_rate or 140),
          }
        end
      end
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
  M.menu = menu   -- plain-text menu, shown on ⌥-click; a normal click opens the panel
  if M.panelUpdate then M.panelUpdate() end
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

-- "Log in to Claude Code …": the logged-out menu used to show `claude auth login` as a
-- plain label, so the only clickable item was Refresh, which re-used the same dead token.
-- This opens Terminal running the real login, then force-fetches every 10s (for up to
-- 5 min) until the fetch stops reporting auth_error, so the % comes back on its own.
function M.login()
  if M.loginPolling then return end
  local ok = hs.osascript.applescript([[
    tell application "Terminal"
      activate
      do script "PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" claude auth login"
    end tell
  ]])
  if not ok then
    hs.alert.show("Couldn't open Terminal. Run `claude auth login` yourself.")
    return
  end
  M.loginPolling = true
  draw()
  local tries = 0
  if M.loginTimer then M.loginTimer:stop() end
  M.loginTimer = hs.timer.doEvery(10, function()
    tries = tries + 1
    if readState().auth_error ~= true or tries > 30 then
      M.loginTimer:stop(); M.loginTimer = nil
      M.loginPolling = false
      draw()
      return
    end
    hs.task.new("/bin/bash", function() draw() end, { FETCH, "--force" }):start()
  end)
end

local function costScan()
  hs.task.new("/bin/bash", function() draw() end, { COST_SCAN }):start()
end

local function creditsFetch()
  hs.task.new("/bin/bash", function() draw() end, { CREDITS }):start()
end

-- ---------- popover panel (panel.html in a borderless webview) ----------
local PANEL = CACHE .. "/panel.html"
local PANEL_W = 340

local function panelData()
  local st = readState()
  local okc, cost = pcall(function() return hs.json.read(COST_STATE) end)
  local okr, cr = pcall(function() return hs.json.read(CREDITS_STATE) end)
  return hs.json.encode({
    usage = st.last_good,
    auth_error = st.auth_error == true,
    credits = okr and cr or nil,
    cost = okc and cost or nil,
    refreshing = M.refreshing and true or false,
    login_polling = M.loginPolling and true or false,
  }) or "{}"
end

function M.panelHide()
  M.panelOpen = false
  if M.wv then M.wv:hide() end
  if M.outsideTap then M.outsideTap:stop() end
end

function M.panelUpdate()
  if M.panelOpen and M.wv then M.wv:evaluateJavaScript("render(" .. panelData() .. ")") end
end

local function within(p, f)
  return f and p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h
end

local function panelMessage(body)
  body = tostring(body or "")
  if body == "refresh" then M.forceRefresh(); creditsFetch()
  elseif body == "login" then M.login()
  elseif body == "close" then M.panelHide()
  elseif body:sub(1, 2) == "h:" and M.wv then
    local h = tonumber(body:sub(3))
    if h then
      local f = M.wv:frame()
      M.wv:frame({ x = f.x, y = f.y, w = PANEL_W, h = math.min(h + 2, 900) })
    end
  end
end

function M.panelShow()
  local bf = bar:frame()
  local scr = (hs.screen.find({ x = bf.x, y = bf.y }) or hs.screen.mainScreen()):frame()
  local x = math.min(math.max(bf.x + bf.w / 2 - PANEL_W / 2, scr.x + 8), scr.x + scr.w - PANEL_W - 8)
  local y = bf.y + bf.h + 4
  if not M.wv then
    local ucc = hs.webview.usercontent.new("cu"):setCallback(function(m) panelMessage(m.body) end)
    M.wv = hs.webview.new({ x = x, y = y, w = PANEL_W, h = 480 }, { developerExtrasEnabled = false }, ucc)
    M.wv:windowStyle({ "borderless" }):transparent(true):shadow(true)
      :level(hs.drawing.windowLevels.popUpMenu)
      :behaviorAsLabels({ "canJoinAllSpaces", "transient" })
    local fh = io.open(PANEL, "r")
    local html = fh and fh:read("*a") or "<p>panel.html missing; re-run install.sh</p>"
    if fh then fh:close() end
    local a, b = html:find("/*DATA*/null/*END*/", 1, true)
    if a then html = html:sub(1, a - 1) .. panelData() .. html:sub(b + 1) end
    M.wv:html(html)
  else
    local f = M.wv:frame()
    M.wv:frame({ x = x, y = y, w = PANEL_W, h = f.h })
  end
  M.panelOpen = true
  M.wv:show()
  M.panelUpdate()
  -- close on any click outside the panel (clicks on the menu bar item toggle instead)
  M.outsideTap = M.outsideTap or hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown },
    function(e)
      local p = e:location()
      if M.panelOpen and not within(p, M.wv:frame()) and not within(p, bar:frame()) then
        hs.timer.doAfter(0, M.panelHide)
      end
      return false
    end)
  M.outsideTap:start()
end

M.bar = bar   -- for headless diagnostics (doctor / hs -c)
bar:setClickCallback(function(mods)
  if mods and mods.alt then
    M.panelHide()
    bar:popupMenu(hs.mouse.absolutePosition(), M.menu or {})
  elseif M.panelOpen then M.panelHide()
  else M.panelShow() end
end)

draw()
refresh()
costScan()
creditsFetch()
M.creditsTimer = hs.timer.doEvery(900, creditsFetch)  -- Console credit balance every 15 min
M.timer = hs.timer.doEvery(60, refresh)  -- redraw + tick countdown, and opportunistically fetch
M.costTimer = hs.timer.doEvery(900, costScan)  -- 7-day cost rescan every 15 min (incremental)
_G.CLAUDE_USAGE_LOADED = true             -- marker the doctor script checks
return M
