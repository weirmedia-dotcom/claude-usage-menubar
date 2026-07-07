# Instructions for Claude Code: install this widget

You are helping a user install the **Claude Usage Menu Bar** widget on their Mac.
It shows their Claude usage % + reset countdown in the macOS menu bar, via Hammerspoon.

Do the following. Be concise and tell the user what you're doing.

## 0. Preconditions (check, don't assume)
- Confirm the OS is macOS (`uname` = `Darwin`). If not, stop and explain it's macOS-only.
- Confirm the user has Claude Code installed and logged in with a **Claude Pro/Max
  subscription**. The widget reads the usage token from the login keychain
  (`security find-generic-password -s "Claude Code-credentials" -w`). If that command
  returns nothing, the real % can't load — tell the user to log into Claude Code first.

## 1. Run the installer
From this repo directory:

```bash
./install.sh
```

It is idempotent and:
- installs Hammerspoon via Homebrew if missing (if there's no `brew`, tell the user to
  install Hammerspoon from https://www.hammerspoon.org and re-run),
- copies `fetch.sh` to `~/.cache/claude-usage-menubar/`,
- copies `claude-usage.lua` to `~/.hammerspoon/`,
- adds `require("claude-usage")` to `~/.hammerspoon/init.lua` **without** overwriting an
  existing config,
- runs one fetch and launches Hammerspoon.

## 2. Verify it actually shows up
Do **not** just trust "it should be there." Verify:

```bash
# the cache should contain a real percentage
python3 -c "import json;print(json.load(open('$HOME/.cache/claude-usage-menubar/poll-state.json')).get('last_good'))"
```

If `last_good` is `None`/absent:
- Re-run `bash ~/.cache/claude-usage-menubar/fetch.sh` and check again.
- If still empty, the keychain token is missing (user not logged into Claude Code with a
  subscription) **or** the endpoint is briefly rate-limited (the fetcher backs off — wait
  a few minutes). The menu bar shows a spinner ( `✳ …` ) until the first real value lands.

Ask the user to confirm they see the Claude spark + % in their menu bar.

## 3. Offer auto-start
Tell the user: to launch at login, open **Hammerspoon → Settings → "Launch Hammerspoon at
login."** (This can't be reliably set from the CLI; it's a one-click toggle.)

## Notes
- The widget uses **only** Hammerspoon + system `python3`/`curl` + the keychain token.
  No Node, no ccusage, no extra services.
- The 5-hour window is a **rolling** window (reset is usually not on the hour); the weekly
  limit is calendar-aligned. This is expected, not a bug.
- Everything the user might tweak (icon size/shape, poll cadence) is documented in
  `README.md` under "Tweaks."
- If Hammerspoon is brand-new on this machine, its first launch may show a welcome window;
  that's fine — the menu-bar item still loads.
