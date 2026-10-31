#!/bin/bash
# Rolling 7-day token usage + API-equivalent cost, by model.
# Scans Claude Code transcripts (~/.claude/projects/**/*.jsonl) for assistant
# messages with usage data, dedupes by message id + request id, and prices the
# tokens at current Claude API rates (per-model cache write and cache read
# prices, see PRICING). Subscription usage isn't billed per token — this is
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
SENIOR_RATE = 140           # CAD/hr, senior CONTRACT developer equivalent
BUCKET = 600                # 10-min activity buckets for dev-hour estimate
FX_FALLBACK = 1.37          # USD->CAD if the Bank of Canada fetch fails
now = time.time()

def usd_cad():
    """Live USD->CAD from the Bank of Canada Valet API; falls back gracefully."""
    import subprocess
    try:
        out = subprocess.run(
            ["curl", "-s", "--max-time", "8",
             "https://www.bankofcanada.ca/valet/observations/FXUSDCAD/json?recent=1"],
            capture_output=True, text=True, timeout=10).stdout
        v = float(json.loads(out)["observations"][-1]["FXUSDCAD"]["v"])
        if 1.0 < v < 2.5:
            return v
    except Exception:
        pass
    return FX_FALLBACK

FX = usd_cad()

# ---- pricing: USD per MTok as (input, 5m cache write, 1h cache write, cache read,
# output), straight from platform.claude.com/docs/en/about-claude/pricing
# (checked 2026-10-31). Cache reads are NOT a flat 0.1x any more: Fable/Mythos 5.1
# are 0.025x, Opus 5.5 and Sonnet 5.5 are 0.05x. Matched by first substring hit,
# so the more specific ids must come first ("opus-5-5" before "opus-5").
PRICING = [
    ("fable-5-1",  (10.0, 12.5,  20.0, 0.25, 50.0)),
    ("mythos-5-1", (10.0, 12.5,  20.0, 0.25, 50.0)),
    ("fable",      (10.0, 12.5,  20.0, 1.0,  50.0)),
    ("mythos",     (10.0, 12.5,  20.0, 1.0,  50.0)),
    ("opus-5-5",   (4.0,  5.0,   8.0,  0.20, 20.0)),
    ("opus",       (5.0,  6.25,  10.0, 0.50, 25.0)),   # Opus 5 / 4.8 / 4.7 / 4.6
    ("sonnet-5-5", (2.0,  2.5,   4.0,  0.10, 10.0)),
    ("sonnet-5",   (2.0,  2.5,   4.0,  0.20, 10.0)),
    ("sonnet",     (3.0,  3.75,  6.0,  0.30, 15.0)),   # Sonnet 4.6 and older
    ("haiku-5-5",  (0.10, 0.125, 0.20, 0.01, 0.50)),
    ("haiku",      (1.0,  1.25,  2.0,  0.10, 5.0)),    # Haiku 4.5
]
# Haiku 5.5 is priced per request by prompt length (input + cache writes + reads):
# over 100k tokens the whole request pays the higher rates.
HAIKU55_LONG = (0.50, 0.625, 1.0, 0.05, 2.50)

def rates(model, prompt_tokens=0):
    m = model.lower()
    for key, r in PRICING:
        if key in m:
            if key == "haiku-5-5" and prompt_tokens > 100_000:
                return HAIKU55_LONG
            return r
    return None

def entry_cost(model, tin, tout, cw5, cw1, cr):
    r = rates(model, tin + cw5 + cw1 + cr)
    if not r: return None
    pin, pw5, pw1, pcr, pout = r
    return (tin * pin + cw5 * pw5 + cw1 * pw1 + cr * pcr + tout * pout) / 1e6

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
def aggregate(label_text, cutoff):
    seen, agg, slots = set(), {}, set()
    for path, rec in live.items():
        for h, ts, model, tin, tout, cw5, cw1, cr in rec["entries"]:
            if ts < cutoff or h in seen:
                continue
            seen.add(h)
            slots.add((path, int(ts) // BUCKET))
            # price each request on its own model id: a label groups several
            # versions (Sonnet 5.5 + Sonnet 5, Haiku 5.5 + Haiku 4.5) at different rates
            a = agg.setdefault(label(model), {"in": 0, "out": 0, "cw5": 0, "cw1": 0, "cr": 0,
                                              "usd": 0.0, "priced": False})
            a["in"] += tin; a["out"] += tout
            a["cw5"] += cw5; a["cw1"] += cw1; a["cr"] += cr
            c = entry_cost(model, tin, tout, cw5, cw1, cr)
            if c is not None:
                a["usd"] += c; a["priced"] = True

    models, total = [], 0.0
    for name, a in agg.items():
        cost = a["usd"] if a["priced"] else None
        if cost is not None:
            total += cost
        models.append({
            "label": name,
            "input": a["in"], "output": a["out"],
            "cache_write": a["cw5"] + a["cw1"], "cache_read": a["cr"],
            "total_tokens": a["in"] + a["out"] + a["cw5"] + a["cw1"] + a["cr"],
            "usd": round(cost, 2) if cost is not None else None,
            "cad": round(cost * FX, 2) if cost is not None else None,
        })
    models.sort(key=lambda m: -(m["usd"] or 0))
    dev_hours = len(slots) * BUCKET / 3600.0
    return {"label": label_text,
            "total_usd": round(total, 2),
            "total_cad": round(total * FX, 2),
            "models": models,
            "dev_hours": round(dev_hours, 1),
            "dev_cad": round(dev_hours * SENIOR_RATE),
            "dev_rate": SENIOR_RATE}

midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0,
                                               microsecond=0).timestamp()
windows = [aggregate("Today", midnight)]
windows += [aggregate(f"Last {d} days", now - d * 86400) for d in WINDOWS]
json.dump({"ts": now, "fx_usd_cad": round(FX, 4), "windows": windows},
          open(STATE, "w"))
PY
