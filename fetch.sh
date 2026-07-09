#!/bin/bash
# Background fetcher for the Claude usage menu-bar widget.
# Reads your Claude Code OAuth token from the login keychain, AUTO-REFRESHES it when
# it expires (so it never goes stale for desktop-app-only users), and polls Anthropic's
# usage endpoint for your current 5-hour + weekly window utilization. Backs off on rate
# limits so it never hammers the endpoint. Runs detached from the menu-bar draw.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
DIR="$HOME/.cache/claude-usage-menubar"
STATE="$DIR/poll-state.json"
LOCK="$DIR/fetch.lock"
mkdir -p "$DIR"
# clear a stale lock orphaned by a killed fetch (older than 2 minutes)
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rm -rf "$LOCK"; fi
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

python3 - "$STATE" "$1" <<'PY'
import json, sys, time, subprocess
from datetime import datetime

STATE = sys.argv[1]
KC = "Claude Code-credentials"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"     # Claude Code public OAuth client
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

FORCE = len(sys.argv) > 2 and sys.argv[2] == "--force"

try: st = json.load(open(STATE))
except Exception: st = {}
now = time.time()
if not FORCE and now < st.get("next_ok", 0):
    sys.exit(0)  # backing off; keep serving last good value

# ---------- keychain + token refresh ----------
def kc_read():
    raw = subprocess.check_output(["security","find-generic-password","-s",KC,"-w"],
                                  text=True, stderr=subprocess.DEVNULL)
    return json.loads(raw)

def kc_account():
    out = subprocess.run(["security","find-generic-password","-s",KC], capture_output=True, text=True).stdout
    for l in out.splitlines():
        if '"acct"' in l:
            parts = l.split('"')
            if len(parts) >= 2: return parts[-2]
    return subprocess.check_output(["id","-un"], text=True).strip()

def kc_write(cred):
    subprocess.run(["security","add-generic-password","-U","-s",KC,"-a",kc_account(),
                    "-w",json.dumps(cred)], capture_output=True, text=True)

def refresh(cred):
    o = cred.get("claudeAiOauth", {})
    rt = o.get("refreshToken")
    if not rt: return None
    body = json.dumps({"grant_type":"refresh_token","refresh_token":rt,"client_id":CLIENT_ID})
    out = subprocess.run(["curl","-s","--max-time","15","-X","POST",TOKEN_URL,
                          "-H","Content-Type: application/json","-H","User-Agent: claude-cli/2.1.202",
                          "--data",body], capture_output=True, text=True).stdout
    try: t = json.loads(out)
    except Exception: return None
    if "access_token" not in t: return None
    o["accessToken"]  = t["access_token"]
    o["refreshToken"] = t.get("refresh_token", rt)
    o["expiresAt"]    = int((time.time() + t.get("expires_in", 28800)) * 1000)
    cred["claudeAiOauth"] = o
    kc_write(cred)
    return o["accessToken"]

try:
    cred = kc_read()
except Exception:
    st["next_ok"] = now + 900; json.dump(st, open(STATE,"w")); sys.exit(0)   # not logged in

o = cred.get("claudeAiOauth", {})
tok = o.get("accessToken")
# proactively refresh if expired (or within 60s of expiry)
if (o.get("expiresAt", 0) / 1000) < now + 60:
    tok = refresh(cred) or tok

# ---------- fetch usage (with one refresh-and-retry on 401) ----------
def call_usage(access):
    r = subprocess.run(["curl","-s","-D","-","--max-time","10",USAGE_URL,
                        "-H",f"Authorization: Bearer {access}",
                        "-H","anthropic-beta: oauth-2025-04-20"],
                       capture_output=True, text=True, timeout=15).stdout
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
    return status, ra, body

try:
    status, ra, body = call_usage(tok)
    if status == 401:                       # token rejected -> refresh once and retry
        tok2 = refresh(cred)
        if tok2: status, ra, body = call_usage(tok2)
except Exception:
    st["next_ok"] = now + 300; json.dump(st, open(STATE,"w")); sys.exit(0)

if status == 429:
    fails = st.get("fails", 0) + 1
    st["fails"] = fails
    st["next_ok"] = now + min(max(ra, 1800) * fails, 14400)   # escalating backoff
    json.dump(st, open(STATE,"w")); sys.exit(0)

try: d = json.loads(body)
except Exception:
    st["next_ok"] = now + 300; json.dump(st, open(STATE,"w")); sys.exit(0)

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
        # /usage returns utilization/percent already on a 0-100 scale — never rescale it
        if not o: return None
        for k in ("pct","percent","used_percentage","utilization"):
            if isinstance(o.get(k),(int,float)): return round(o[k])
        return None
    def loc(v):
        if v is None: return None
        try:
            if isinstance(v,(int,float)): dt = datetime.fromtimestamp(v if v<1e12 else v/1000)
            else: dt = datetime.fromisoformat(str(v).replace("Z","+00:00")).astimezone()
            today = datetime.now().astimezone().date()
            # same day -> time only; otherwise include the weekday (e.g. "Wed 8:59 AM")
            return dt.strftime("%-I:%M %p") if dt.date() == today else dt.strftime("%a %-I:%M %p")
        except Exception: return None
    def ep(v):
        if v is None: return None
        try:
            if isinstance(v,(int,float)): return int(v if v<1e12 else v/1000)
            return int(datetime.fromisoformat(str(v).replace("Z","+00:00")).timestamp())
        except Exception: return None

    # Prefer the canonical `limits` array (clean integer percents); fall back to the
    # five_hour/seven_day utilization objects.
    limits = d.get("limits") if isinstance(d.get("limits"), list) else []
    def from_limits(kind):
        for L in limits:
            if isinstance(L, dict) and L.get("kind") == kind and isinstance(L.get("percent"),(int,float)):
                return {"percent": L["percent"], "resets_at": L.get("resets_at")}
        return None
    five = from_limits("session")    or find(d, ["five_hour","5h","session"])
    week = from_limits("weekly_all") or find(d, ["seven_day","7d","week"])
    g = {"ts": now}
    if five is not None:
        g["pct5"]=pct(five); g["reset5_str"]=loc(five.get("resets_at")); g["reset5_epoch"]=ep(five.get("resets_at"))
    if week is not None:
        g["pct7"]=pct(week); g["reset7_str"]=loc(week.get("resets_at")); g["reset7_epoch"]=ep(week.get("resets_at"))
    if g.get("pct5") is not None:
        st["last_good"]=g; st["next_ok"]=now + 60; st["fails"]=0    # success: poll every ~1 min
        json.dump(st, open(STATE,"w")); sys.exit(0)

st["next_ok"] = now + 300
json.dump(st, open(STATE,"w"))
PY
