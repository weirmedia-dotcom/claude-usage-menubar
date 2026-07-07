#!/bin/bash
# Background fetcher for the Claude usage menu-bar widget.
# Polls Anthropic's OAuth usage endpoint (the same source the in-app /usage panel
# uses) and writes the current 5-hour + weekly window utilization to a small cache
# file. Runs detached from the menu-bar draw, and backs off politely on rate limits
# so it never hammers the endpoint.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
DIR="$HOME/.cache/claude-usage-menubar"
STATE="$DIR/poll-state.json"
LOCK="$DIR/fetch.lock"
mkdir -p "$DIR"
# clear a stale lock orphaned by a killed fetch (older than 2 minutes)
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
  rm -rf "$LOCK"
fi
# single-flight: skip if a fetch is already running
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

python3 - "$STATE" <<'PY'
import json, sys, time, subprocess
from datetime import datetime
sp = sys.argv[1]
try: st = json.load(open(sp))
except Exception: st = {}
now = time.time()
if now < st.get("next_ok", 0):
    sys.exit(0)  # still backing off; keep serving last good value

# read the Claude Code OAuth token from the login keychain
try:
    raw = subprocess.check_output(
        ["security","find-generic-password","-s","Claude Code-credentials","-w"],
        text=True, stderr=subprocess.DEVNULL)
    tok = json.loads(raw)["claudeAiOauth"]["accessToken"]
except Exception:
    st["next_ok"] = now + 600; json.dump(st, open(sp,"w")); sys.exit(0)

try:
    r = subprocess.run(
        ["curl","-s","-D","-","--max-time","10","https://api.anthropic.com/api/oauth/usage",
         "-H",f"Authorization: Bearer {tok}","-H","anthropic-beta: oauth-2025-04-20"],
        capture_output=True, text=True, timeout=15).stdout
except Exception:
    st["next_ok"] = now + 300; json.dump(st, open(sp,"w")); sys.exit(0)

head,_,body = r.partition("\r\n\r\n")
if not body: head,_,body = r.partition("\n\n")
status = 0; ra = 0
for ln in head.splitlines():
    if ln.startswith("HTTP/"):
        try: status = int(ln.split()[1])
        except Exception: pass
    if ln.lower().startswith("retry-after:"):
        try: ra = int(ln.split(":",1)[1].strip())
        except Exception: pass
if status == 429:
    st["next_ok"] = now + max(ra,60) + 120  # wait out the sliding-window reset + buffer
    json.dump(st, open(sp,"w")); sys.exit(0)
try: d = json.loads(body)
except Exception:
    st["next_ok"] = now + 300; json.dump(st, open(sp,"w")); sys.exit(0)

if isinstance(d, dict) and "error" not in d:
    def find(o, hints):
        if isinstance(o, dict):
            for k,v in o.items():
                if any(h in k for h in hints) and isinstance(v,dict) and ("utilization" in v or "used_percentage" in v):
                    return v
            for v in o.values():
                x = find(v,hints)
                if x: return x
        if isinstance(o, list):
            for it in o:
                x = find(it,hints)
                if x: return x
        return None
    def pct(o):
        if not o: return None
        if isinstance(o.get("used_percentage"),(int,float)): return round(o["used_percentage"])
        if isinstance(o.get("utilization"),(int,float)):
            u = o["utilization"]; return round(u*100 if u<=1 else u)
        return None
    def loc(v):
        if v is None: return None
        try:
            if isinstance(v,(int,float)): dt = datetime.fromtimestamp(v if v<1e12 else v/1000)
            else: dt = datetime.fromisoformat(str(v).replace("Z","+00:00")).astimezone()
            return dt.strftime("%-I:%M %p")
        except Exception: return None
    def ep(v):
        if v is None: return None
        try:
            if isinstance(v,(int,float)): return int(v if v<1e12 else v/1000)
            return int(datetime.fromisoformat(str(v).replace("Z","+00:00")).timestamp())
        except Exception: return None

    five = find(d, ["five_hour","5h","session"])
    week = find(d, ["seven_day","7d","week"])
    g = {"ts": now}
    if five is not None:
        g["pct5"]=pct(five); g["reset5_str"]=loc(five.get("resets_at")); g["reset5_epoch"]=ep(five.get("resets_at"))
    if week is not None:
        g["pct7"]=pct(week); g["reset7_str"]=loc(week.get("resets_at")); g["reset7_epoch"]=ep(week.get("resets_at"))
    if g.get("pct5") is not None:
        st["last_good"]=g; st["next_ok"]=now + 600  # steady ~10-min cadence
        json.dump(st, open(sp,"w")); sys.exit(0)

st["next_ok"] = now + 300
json.dump(st, open(sp,"w"))
PY
