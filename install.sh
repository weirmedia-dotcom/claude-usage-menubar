#!/bin/bash
# Installer for the Claude usage menu-bar widget.
# Idempotent: safe to re-run. Does not overwrite an existing Hammerspoon init.lua —
# it appends one require() line if needed.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"

say() { printf "\033[1;36m==>\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!! \033[0m %s\n" "$1"; }

# --- 0. sanity ---
[ "$(uname)" = "Darwin" ] || { echo "This is macOS-only."; exit 1; }

# --- 1. Hammerspoon (the menu-bar host) ---
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  if command -v brew >/dev/null 2>&1; then
    say "Installing Hammerspoon via Homebrew…"
    brew install --cask hammerspoon
  else
    echo "Hammerspoon is not installed and Homebrew was not found."
    echo "Install Hammerspoon from https://www.hammerspoon.org then re-run this."
    exit 1
  fi
else
  say "Hammerspoon already installed."
fi

# --- 2. fetcher ---
say "Installing the usage fetcher…"
mkdir -p "$HOME/.cache/claude-usage-menubar"
cp "$SRC/fetch.sh" "$HOME/.cache/claude-usage-menubar/fetch.sh"
chmod +x "$HOME/.cache/claude-usage-menubar/fetch.sh"
cp "$SRC/cost-scan.sh" "$HOME/.cache/claude-usage-menubar/cost-scan.sh"
chmod +x "$HOME/.cache/claude-usage-menubar/cost-scan.sh"

# --- 3. Hammerspoon module ---
say "Installing the Hammerspoon module…"
mkdir -p "$HOME/.hammerspoon"
cp "$SRC/claude-usage.lua" "$HOME/.hammerspoon/claude-usage.lua"

INIT="$HOME/.hammerspoon/init.lua"
if [ ! -f "$INIT" ]; then
  echo 'require("claude-usage")' > "$INIT"
  say "Created ~/.hammerspoon/init.lua"
elif ! grep -q 'require("claude-usage")' "$INIT"; then
  printf '\nrequire("claude-usage")\n' >> "$INIT"
  say "Added require(\"claude-usage\") to your existing init.lua"
else
  say "init.lua already loads the widget."
fi

# --- 4. seed one fetch so the first draw has data ---
say "Fetching your current usage…"
bash "$HOME/.cache/claude-usage-menubar/fetch.sh" || true

# --- 5. launch / reload Hammerspoon ---
FIRST_RUN=0
pgrep -x Hammerspoon >/dev/null || FIRST_RUN=1
say "Starting Hammerspoon…"
osascript -e 'quit app "Hammerspoon"' 2>/dev/null || true
sleep 1
open -a Hammerspoon
sleep 4

if [ "$FIRST_RUN" = "1" ]; then
  warn "Hammerspoon was just launched for the first time."
  warn "macOS may show a Gatekeeper 'Open' prompt and/or a Hammerspoon welcome window."
  warn "You must approve/close those once — a script can't click them for you."
fi

# --- 6. verify ---
echo ""
say "Verifying…"
bash "$SRC/doctor.sh" || true

echo ""
say "If you see PASS on every line above, look for the Claude spark + % in your menu bar."
echo ""
warn "Requirements for the real % to show:"
echo "   • Claude Code must be installed and logged in with a Claude Pro/Max"
echo "     subscription (the widget reads that token from your login keychain)."
echo "   • To have it start automatically: Hammerspoon → Settings →"
echo "     'Launch Hammerspoon at login'."
echo ""
echo "If it shows a spinner for a minute, that's the first poll — it fills in shortly."
