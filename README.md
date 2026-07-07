# Claude Usage Menu Bar

Shows your **Claude Max/Pro usage right in the macOS menu bar** — the Claude spark,
your current 5-hour window %, and a live countdown to reset:

```
✳ 30% · 23m
```

Click it for a dropdown with the 5-hour and weekly limits and their reset times.

It reads the **same numbers Claude's own `/usage` panel shows** (Anthropic's OAuth
usage endpoint) — no scraping, no guessing. It polls politely (about every 10
minutes, with rate-limit backoff) so it never gets throttled.

---

## Requirements

- **macOS**
- **[Hammerspoon](https://www.hammerspoon.org)** — the menu-bar host (the installer
  installs it for you via Homebrew if you don't have it)
- **Claude Code, logged in with a Claude Pro or Max subscription** — the widget reads
  your usage token from the login keychain. If you use Claude Code, you already have this.

That's it. No Node, no extra services.

---

## Install

### Option A — let Claude Code do it (easiest)

Open Claude Code in this folder and say:

> Install this. Follow CLAUDE.md.

### Option B — one command

```bash
git clone https://github.com/weirmedia-dotcom/claude-usage-menubar.git
cd claude-usage-menubar
./install.sh
```

When it finishes, look for the Claude spark + % in your menu bar. To make it start
automatically at login: **Hammerspoon → Settings → “Launch Hammerspoon at login.”**

---

## What it installs

| Path | What |
|------|------|
| `~/.hammerspoon/claude-usage.lua` | the menu-bar widget (Hammerspoon module) |
| `~/.hammerspoon/init.lua` | gets one line: `require("claude-usage")` (created if absent, appended if present — your existing config is never overwritten) |
| `~/.cache/claude-usage-menubar/fetch.sh` | the background poller |
| `~/.cache/claude-usage-menubar/poll-state.json` | the tiny cache of the latest numbers |

## Not showing up? Run the doctor

```bash
./doctor.sh
```

It prints a PASS/FAIL for each step (Hammerspoon installed, running, config loaded,
token present, real % fetched) and tells you the exact fix for the first failure.

The most common cause on a fresh install: **Hammerspoon was just installed and needs a
one-time manual approval** — macOS shows a Gatekeeper "Open" prompt and a Hammerspoon
welcome window that a script can't click. Open Hammerspoon from Applications, approve it,
then re-run `./doctor.sh` (or `./install.sh`).

## Uninstall

```bash
rm ~/.hammerspoon/claude-usage.lua
rm -rf ~/.cache/claude-usage-menubar
# then remove the  require("claude-usage")  line from ~/.hammerspoon/init.lua
# and reload/quit Hammerspoon
```

## Tweaks

Everything is in `~/.hammerspoon/claude-usage.lua`:

- **Icon size** — `setSize({ w = 16, h = 16 })` (try 14 or 18)
- **Icon shape** — the `rays` / `strokeWidth` in `claudeIcon()`
- **Keep Hammerspoon's own hammer icon** — delete the `hs.menuIcon(false)` line
- **Poll cadence** — `next_ok = now + 600` in `fetch.sh` (seconds)

After editing, reload Hammerspoon (its menu → Reload Config, or quit/reopen).

---

## Notes / honesty

- The **5-hour window is a rolling window** — it resets 5 hours after your first
  message in the current block, so the reset time is usually **not** on the hour.
  The **weekly** limit is calendar-aligned.
- The % only moves as you actually use Claude, and snaps back near 0 at reset.
- Numbers can lag up to ~10 minutes (the poll cadence). If the endpoint ever rate-limits,
  the widget backs off and keeps showing the last known value.
