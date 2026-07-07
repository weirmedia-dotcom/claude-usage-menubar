#!/bin/bash
# Diagnoses why the Claude usage menu-bar widget isn't showing.
# Prints a clear PASS/FAIL for each step and a specific fix for the first failure.
DIR="$HOME/.cache/claude-usage-menubar"
HS="/opt/homebrew/bin/hs"; [ -x "$HS" ] || HS="/usr/local/bin/hs"
pass() { printf "  \033[1;32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[1;31mFAIL\033[0m  %s\n" "$1"; }
note() { printf "        \033[0;36m→ %s\033[0m\n" "$1"; }

echo "Claude usage widget — diagnostics"
echo "---------------------------------"

# 1. OS
if [ "$(uname)" = "Darwin" ]; then pass "macOS"; else fail "not macOS — this is macOS-only"; exit 1; fi

# 2. Hammerspoon installed
if [ -d /Applications/Hammerspoon.app ]; then pass "Hammerspoon installed"
else fail "Hammerspoon not installed"; note "brew install --cask hammerspoon   (or get it from hammerspoon.org)"; exit 1; fi

# 3. Hammerspoon running
if pgrep -x Hammerspoon >/dev/null; then pass "Hammerspoon running"
else fail "Hammerspoon not running"
  note "Open Hammerspoon from Applications. FIRST launch needs you to approve the"
  note "Gatekeeper 'Open' prompt AND the welcome window — a script cannot click those."
  note "Open it, approve, then re-run this doctor."; exit 1; fi

# 4. module + init wiring
[ -f "$HOME/.hammerspoon/claude-usage.lua" ] && pass "module present" || { fail "claude-usage.lua missing in ~/.hammerspoon"; note "re-run ./install.sh"; exit 1; }
if grep -q 'require("claude-usage")' "$HOME/.hammerspoon/init.lua" 2>/dev/null; then pass "init.lua loads the module"
else fail "init.lua does not require the module"; note "add this line to ~/.hammerspoon/init.lua:  require(\"claude-usage\")"; exit 1; fi

# 5. widget actually loaded inside Hammerspoon (authoritative, via CLI)
if [ -x "$HS" ] && "$HS" -c 'print("ok")' >/dev/null 2>&1; then
  "$HS" -c 'hs.reload()' >/dev/null 2>&1; sleep 2
  LOADED=$("$HS" -c 'print(_G.CLAUDE_USAGE_LOADED == true)' 2>/dev/null | tail -1)
  if [ "$LOADED" = "true" ]; then pass "widget loaded in Hammerspoon (menu bar item is live)"
  else fail "Hammerspoon is running but the widget didn't load"
    note "Check Hammerspoon's Console for a red Lua error in your init.lua."
    note "Make sure ~/.hammerspoon/init.lua contains:  require(\"claude-usage\")"
  fi
else
  fail "Hammerspoon isn't responding to the CLI yet"
  note "The config likely hasn't loaded. Quit & reopen Hammerspoon, then re-run this doctor."
  note "(First launch needs you to approve the Gatekeeper 'Open' + welcome window.)"
fi

# 6. keychain token (needed for the real %)
if security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then pass "Claude Code token found in keychain"
else fail "no Claude Code token in keychain"
  note "Log into Claude Code with a Claude Pro/Max subscription, then re-run ./install.sh."
  note "(Without it the widget can show but the % will stay blank.)"; fi

# 7. do we have a real percentage cached?
bash "$DIR/fetch.sh" 2>/dev/null
LG=$(python3 -c "import json;print(json.load(open('$DIR/poll-state.json')).get('last_good') is not None)" 2>/dev/null)
if [ "$LG" = "True" ]; then
  P=$(python3 -c "import json;print(json.load(open('$DIR/poll-state.json'))['last_good'].get('pct5'))" 2>/dev/null)
  pass "real usage fetched (5-hour window: ${P}% used)"
else
  fail "no percentage fetched yet"
  note "Either the keychain token is missing (see above), or the endpoint is briefly"
  note "rate-limited (the fetcher backs off). Wait 2-3 min and re-run this doctor."
fi

echo "---------------------------------"
echo "If everything is PASS but you still don't see it: the item is in the menu bar of"
echo "your ACTIVE display and to the LEFT of the clock — look near your other icons."
echo "On a very full menu bar (many icons + a notch) macOS can hide extra items;"
echo "remove a couple of unused menu bar icons to make room."
