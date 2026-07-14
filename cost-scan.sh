#!/bin/bash
# Rolling 7-day token usage + API-equivalent cost, by model.
# Scans Claude Code transcripts (~/.claude/projects/**/*.jsonl) for assistant
# messages with usage data, dedupes by message id + request id, and prices the
# tokens at current Claude API rates (incl. cache write 1.25x/2x and cache
# read 0.1x multipliers). Subscription usage isn't billed per token — this is
# "what the last 7 days would have cost through the API".
#
# Incremental: per-file extraction results are cached (keyed on mtime+size) in
# cost-cache.json, so only new/changed session files are re-parsed. First run
# over a large backlog can take a minute; later runs are cheap.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
DIR="$HOME/.cache/claude-usage-menubar"
LOCK="$DIR/cost-scan.lock"
mkdir -p "$DIR"
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rm -rf "$LOCK"; fi
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

python3 - "$DIR" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

DIR = sys.argv[1]
CACHE = os.path.join(DIR, "cost-cache.json")
STATE = os.path.join(DIR, "cost-state.json")
ROOT = os.path.expanduser("~/.claude/projects")

CACHE_VERSION = 2           # bump when extraction shape/window changes (forces re-extract)
WINDOWS = [7, 30]           # aggregate windows, days
SCAN_WINDOW = 31 * 86400    # keep an extra day of entries cached
SENIOR_RATE = 100           # USD/hr, senior-dev labor equivalent
BUCKET = 600                # 10-min activity buckets for dev-hour estimate
now = time.time()

# ---- pricing: (input, output) USD per MTok; matched by first substring hit.
# Cache multipliers per Anthropic pricing: write 5m TTL = 1.25x input,
# write 1h TTL = 2x input, cache read = 0.1x input.
PRICING = [
    ("fable",    (10.0, 50.0)),
    ("mythos",   (10.0, 50.0)),
    ("opus",     (5.0, 25.0)),
    ("sonnet-5", (2.0, 10.0)),   # intro pricing through 2026-08-31; then 3/15
    ("sonnet",   (3.0, 15.0)),
    ("haiku",    (1.0, 5.0)),
]

def rates(model):
    m = model.lower()
    for key, r in PRICING:
        if key in m:
            return r
    return None

def label(model):
    m = model.lower()
    if "fable" in m: return "Fable"
    if "mythos" in m: return "Mythos"
    if "opus" in m: return "Opus"
    if "sonnet" in m: return "Sonnet"
    if "haiku" in m: return "Haiku"
    return model

def parse_ts(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def extract(path):
    """Pull (hash, epoch, model, in, out, cw5m, cw1h, cr) tuples from one file."""
    out = []
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                if '"usage"' not in line or '"model"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                u = msg.get("usage")
                model = msg.get("model")
                if not isinstance(u, dict) or not model or model == "<synthetic>":
                    continue
                ts = parse_ts(d.get("timestamp") or "")
                if ts is None or ts < now - SCAN_WINDOW:
                    continue
                cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
                cw_total = u.get("cache_creation_input_tokens") or 0
                cw5 = cc.get("ephemeral_5m_input_tokens")
                cw1 = cc.get("ephemeral_1h_input_tokens")
                if cw5 is None and cw1 is None:
                    cw5, cw1 = cw_total, 0   # no breakdown: assume 5m TTL
                h = f'{msg.get("id") or d.get("uuid")}:{d.get("requestId")}'
                out.append([h, int(ts), model,
                            u.get("input_tokens") or 0,
                            u.get("output_tokens") or 0,
                            cw5 or 0, cw1 or 0,
                            u.get("cache_read_input_tokens") or 0])
    except Exception:
        pass
    return out

# ---- incremental file cache
try:
    cache = json.load(open(CACHE))
    if cache.get("v") != CACHE_VERSION:
        cache = {"files": {}}
except Exception:
    cache = {"files": {}}
files = cache.get("files", {})

live = {}
for dirpath, _dirs, names in os.walk(ROOT):
    for n in names:
        if not n.endswith(".jsonl"):
            continue
        p = os.path.join(dirpath, n)
        try:
            st = os.stat(p)
        except OSError:
            continue
        if st.st_mtime < now - SCAN_WINDOW:
            continue
        key = f"{int(st.st_mtime)}:{st.st_size}"
        prev = files.get(p)
        if prev and prev.get("key") == key:
            live[p] = prev
        else:
            live[p] = {"key": key, "entries": extract(p)}

json.dump({"v": CACHE_VERSION, "files": live}, open(CACHE, "w"))

# ---- aggregate per window: global dedup, group by model label, plus a
# senior-dev labor equivalent (distinct (session, 10-min bucket) slots of
# assistant activity — parallel sessions count separately, since a human
# would have to do that work serially — priced at SENIOR_RATE/hr).
def aggregate(days):
    cutoff = now - days * 86400
    seen, agg, slots = set(), {}, set()
    for path, rec in live.items():
        for h, ts, model, tin, tout, cw5, cw1, cr in rec["entries"]:
            if ts < cutoff or h in seen:
                continue
            seen.add(h)
            slots.add((path, int(ts) // BUCKET))
            a = agg.setdefault(label(model), {"model": model, "in": 0, "out": 0,
                                              "cw5": 0, "cw1": 0, "cr": 0})
            a["in"] += tin; a["out"] += tout
            a["cw5"] += cw5; a["cw1"] += cw1; a["cr"] += cr

    models, total = [], 0.0
    for name, a in agg.items():
        r = rates(a["model"])
        cost = None
        if r:
            rin, rout = r
            cost = (a["in"] * rin + a["out"] * rout
                    + a["cw5"] * rin * 1.25 + a["cw1"] * rin * 2.0
                    + a["cr"] * rin * 0.1) / 1e6
            total += cost
        models.append({
            "label": name,
            "input": a["in"], "output": a["out"],
            "cache_write": a["cw5"] + a["cw1"], "cache_read": a["cr"],
            "total_tokens": a["in"] + a["out"] + a["cw5"] + a["cw1"] + a["cr"],
            "usd": round(cost, 2) if cost is not None else None,
        })
    models.sort(key=lambda m: -(m["usd"] or 0))
    dev_hours = len(slots) * BUCKET / 3600.0
    return {"window_days": days, "total_usd": round(total, 2), "models": models,
            "dev_hours": round(dev_hours, 1),
            "dev_usd": round(dev_hours * SENIOR_RATE),
            "dev_rate": SENIOR_RATE}

json.dump({"ts": now, "windows": [aggregate(d) for d in WINDOWS]},
          open(STATE, "w"))
PY
