#!/bin/bash
# Console API credit balance for the Claude usage menu-bar widget.
# The monthly API credits that come with Max/Ultra (and any purchased prepaid
# balance) are only exposed by the Console's own web API, which authenticates with
# the browser session cookie, not an API or Admin key. The cookie lives in the login
# keychain (claude-usage-menubar / console_session_key), put there by
# `wmpe-secrets`: ./rotate deploy CLAUDE_CONSOLE_SESSION_KEY. It expires every few
# weeks; the widget says "re-copy" when the Console stops accepting it.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
DIR="$HOME/.cache/claude-usage-menubar"
LOCK="$DIR/credits.lock"
mkdir -p "$DIR"
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rm -rf "$LOCK"; fi
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

python3 - "$DIR" <<'PY'
import json, os, sys, time, subprocess
from datetime import datetime

DIR = sys.argv[1]
STATE = os.path.join(DIR, "credits-state.json")
# Console org UUID: local-only, never in this (public) repo. Find it in the Console URL
# or Settings → Organization, then: echo <uuid> > ~/.config/claude-usage-menubar/console-org
ORG_FILE = os.path.expanduser("~/.config/claude-usage-menubar/console-org")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
now = time.time()

try: prev = json.load(open(STATE))
except Exception: prev = {}

def save(st):
    tmp = STATE + ".tmp"
    json.dump(st, open(tmp, "w")); os.replace(tmp, STATE)

def fail(kind):
    # keep the last good numbers so the dropdown can still show them, flagged stale
    st = dict(prev); st["error"] = kind; st["error_ts"] = now
    save(st); sys.exit(0)

try: ORG = open(ORG_FILE).read().strip()
except Exception: ORG = ""
if not ORG: sys.exit(0)   # credits not configured: the dropdown section stays hidden
URL = f"https://platform.claude.com/api/organizations/{ORG}/prepaid/credits"

try:
    cookie = subprocess.check_output(["security","find-generic-password","-s","claude-usage-menubar",
                                      "-a","console_session_key","-w"], text=True,
                                     stderr=subprocess.DEVNULL).strip()
except Exception:
    fail("no_cookie")
if not cookie: fail("no_cookie")
if not cookie.startswith("sessionKey="): cookie = "sessionKey=" + cookie

# headers go in via a curl config on stdin so the cookie never sits in argv / `ps`
cfg = f'header = "Cookie: {cookie}"\nheader = "User-Agent: {UA}"\nheader = "Accept: application/json"\n'
try:
    out = subprocess.run(["curl","-s","--max-time","15","-w","\n%{http_code}","-K","-",URL],
                         input=cfg, capture_output=True, text=True, timeout=20).stdout
except Exception:
    fail("network")
body, _, code = out.rpartition("\n")
code = int(code) if code.strip().isdigit() else 0
if code in (401, 403):
    fail("blocked" if "cloudflare" in body.lower() or "just a moment" in body.lower() else "auth")
if code != 200: fail("http_%d" % code)
try: d = json.loads(body)
except Exception: fail("parse")

def epoch(s):
    try: return int(datetime.fromisoformat(str(s).replace("Z","+00:00")).timestamp())
    except Exception: return None
def local(s):
    e = epoch(s)
    return datetime.fromtimestamp(e).strftime("%b %-d") if e else None

promo = []
for t in d.get("promo_tranches") or []:
    rem, gr = t.get("remaining_amount_minor_units"), t.get("granted_amount_minor_units")
    if not isinstance(rem, (int, float)) or not isinstance(gr, (int, float)): continue
    g_ep, x_ep = epoch(t.get("granted_at")), epoch(t.get("expires_at"))
    p = {"remaining": rem / 100, "granted": gr / 100,
         "expires_epoch": x_ep, "expires_str": local(t.get("expires_at"))}
    # pace since the grant landed, and what that pace leaves unused at expiry
    if g_ep and x_ep and now - g_ep > 86400:
        rate = (gr - rem) / 100 / ((now - g_ep) / 86400)
        p["per_day"] = round(rate, 2)
        p["unused_at_expiry"] = round(max(0.0, rem / 100 - rate * max(0, (x_ep - now) / 86400)), 2)
    promo.append(p)

paid = d.get("amount_without_scoped_credits")
save({"ts": now, "promo": promo,
      "paid": paid / 100 if isinstance(paid, (int, float)) else None,
      "error": None})
PY
