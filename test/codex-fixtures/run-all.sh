#!/usr/bin/env bash
# Drive the REAL collector against each fixture and check what it emits.
#
# These are not unit tests and there is no framework: each case runs
# bin/usage-meter-stats as the menu-bar app runs it, with a `codex` on PATH
# that serves a fixture over the real app-server protocol, and asserts the JSON
# that came out. The point is the paid-plan shapes -- a rolling 5-hour window
# with a weekly one beside it, several metered buckets, credits, a ceiling
# already reached -- which no request to a free account can produce.
#
# Offline and free: nothing here reaches OpenAI, and the Claude half of the
# collector is pointed at an empty HOME so a test run cannot spend the
# account's usage-endpoint budget either.
#
# Usage: bash test/codex-fixtures/run-all.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
COLLECTOR="$REPO/bin/usage-meter-stats"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0

# The shim PATH entry. It must be named `codex`, because that is what the
# collector looks for -- the binary's NAME is half the presence check.
mkdir -p "$WORK/bin" "$WORK/home/.codex"
: >"$WORK/home/.codex/auth.json"          # existence is the signed-in check
printf '#!/bin/bash\nexec python3 %s/fake-codex.py\n' "$HERE" >"$WORK/bin/codex"
chmod +x "$WORK/bin/codex"

# Run the collector with `codex` shimmed and every other path pointed at
# scratch. HOME is empty, so the Claude section reports ok:false and no network
# call is made for it.
collect() {
  # GEMINI_HOME defaults to a directory that does not exist, so agy is absent
  # unless a case deliberately sets one; a caller's value wins.
  CODEX_FIXTURE="$1" \
  PATH="$WORK/bin:/usr/bin:/bin" \
  HOME="$WORK/home" \
  CODEX_HOME="$WORK/home/.codex" \
  GEMINI_HOME="${GEMINI_HOME:-$WORK/no-gemini}" \
  USAGE_METER_CACHE_DIR="$WORK/cache-$2" \
    bash "$COLLECTOR"
}

check() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    printf '  ok    %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
    fail=$((fail + 1))
  fi
}

# `jq` is not assumed: python3 is already a hard dependency of the collector.
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["codex"]'"$1"')' 2>&1; }
codex_expr() { python3 -c 'import json,sys; c=json.loads(sys.stdin.read())["codex"]; print(eval(sys.argv[1], {}, {"c":c}))' "$1" 2>&1; }

say() { printf '\n%s\n' "$*"; }

say "free-single-window — the shape this fleet's own account reports"
out="$(collect "$HERE/free-single-window.json" free)"
check "one window"        "$(printf '%s' "$out" | field '["limits"].__len__()')" "1"
check "labelled 30-day"   "$(printf '%s' "$out" | field '["limits"][0]["label"]')" "30-day"
check "30-day duration"   "$(printf '%s' "$out" | field '["limits"][0]["duration_mins"]')" "43200"
check "30-day not weekly" "$(printf '%s' "$out" | codex_expr '"cadence" in c["limits"][0]')" "False"
check "plan free"         "$(printf '%s' "$out" | field '["plan"]')" "free"
check "no details yet"    "$(printf '%s' "$out" | field '.get("details", ["Model: GPT-5.6-Terra"])[0]')" "Model: GPT-5.6-Terra"

say "paid-two-windows — the 5-hour + weekly pair a paid plan reports"
out="$(collect "$HERE/paid-two-windows.json" paid)"
check "two windows"       "$(printf '%s' "$out" | field '["limits"].__len__()')" "2"
check "first is 5h"       "$(printf '%s' "$out" | field '["limits"][0]["label"]')" "5h"
check "second is Weekly"  "$(printf '%s' "$out" | field '["limits"][1]["label"]')" "Weekly"
check "5h metadata"       "$(printf '%s' "$out" | codex_expr '(c["limits"][0]["duration_mins"], c["limits"][0]["cadence"])')" "(300, 'short')"
check "weekly metadata"   "$(printf '%s' "$out" | codex_expr '(c["limits"][1]["duration_mins"], c["limits"][1]["cadence"])')" "(10080, 'weekly')"
check "5h percentage"     "$(printf '%s' "$out" | field '["limits"][0]["pct"]')" "42"
check "weekly percentage" "$(printf '%s' "$out" | field '["limits"][1]["pct"]')" "7"
check "5h counts down"    "$(printf '%s' "$out" | field '["limits"][0]["reset_in"] > 0')" "True"
check "plan pro"          "$(printf '%s' "$out" | field '["plan"]')" "pro"
check "credit balance"    "$(printf '%s' "$out" | field '["details"][0]')" "Credits: 1,250"
check "model named"       "$(printf '%s' "$out" | field '["details"][1]')" "Model: GPT-5.6-Terra"
check "others listed"     "$(printf '%s' "$out" | field '["details"][2]')" \
                          "Also available: GPT-5.6-Luna, GPT-5.5"

say "multi-bucket — several metered buckets, one of them at its ceiling"
out="$(collect "$HERE/multi-bucket.json" multi)"
check "four windows"      "$(printf '%s' "$out" | field '["limits"].__len__()')" "4"
check "bucket named"      "$(printf '%s' "$out" | field '["limits"][0]["label"]')" "Agents Hourly"
check "codex 5h named"    "$(printf '%s' "$out" | field '["limits"][2]["label"]')" "Codex 5h"
check "bucket durations"  "$(printf '%s' "$out" | codex_expr '[(x["duration_mins"], x.get("cadence")) for x in c["limits"]]')" "[(60, 'short'), (43200, None), (300, 'short'), (10080, 'weekly')]"
check "reached=critical"  "$(printf '%s' "$out" | field '["limits"][2]["severity"]')" "critical"
check "other bucket calm" "$(printf '%s' "$out" | field '["limits"][0]["severity"]')" "normal"
check "state in words"    "$(printf '%s' "$out" | field '["details"][0]')" "Rate limit reached"
check "unlimited credits" "$(printf '%s' "$out" | field '["details"][1]')" "Credits: unlimited"

say "missing duration — metadata stays optional"
python3 - "$HERE/paid-two-windows.json" "$WORK/missing-duration.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
usage = data["account/rateLimits/read"]
for snapshot in [usage.get("rateLimits", {})] + list((usage.get("rateLimitsByLimitId") or {}).values()):
    for key in ("primary", "secondary"):
        if isinstance(snapshot.get(key), dict):
            snapshot[key].pop("windowDurationMins", None)
json.dump(data, open(sys.argv[2], "w"))
PY
out="$(collect "$WORK/missing-duration.json" missing-duration)"
check "unknown labels remain" "$(printf '%s' "$out" | codex_expr '[x["label"] for x in c["limits"]]')" "['Limit', 'Limit']"
check "unknown has no metadata" "$(printf '%s' "$out" | codex_expr '[set(x) & {"duration_mins", "cadence"} for x in c["limits"]]')" "[set(), set()]"

say "config.toml — the top-level model key, and the three stops that guard it"
# Each case writes a config.toml and asserts what reached the MENU, which is
# the only thing that matters: the claim being tested is that nothing from a
# table, a multi-line string or a structure can get into the blob.
cfg() { printf '%s' "$1" >"$WORK/home/.codex/config.toml"; }

cfg 'model = "gpt-5.6-luna"
approval_policy = "on-failure"
'
out="$(collect "$HERE/paid-two-windows.json" cfg1)"
check "top-level model wins" "$(printf '%s' "$out" | field '["details"][1]')" "Model: GPT-5.6-Luna"

cfg '[mcp_servers.github]
http_headers = { Authorization = "Bearer ghp_NOTATOKEN" }
model = "from-a-table"
'
out="$(collect "$HERE/paid-two-windows.json" cfg2)"
check "stops at a table"     "$(printf '%s' "$out" | field '["details"][1]')" "Model: GPT-5.6-Terra"
check "no token in the blob" "$(printf '%s' "$out" | grep -c ghp_NOTATOKEN || true)" "0"

cfg 'notes = """
model = "from-inside-a-string"
"""
'
out="$(collect "$HERE/paid-two-windows.json" cfg3)"
check "stops at \"\"\""        "$(printf '%s' "$out" | field '["details"][1]')" "Model: GPT-5.6-Terra"

cfg 'model = { id = "a", token = "ghp_NOTATOKEN" }
'
out="$(collect "$HERE/paid-two-windows.json" cfg4)"
check "refuses a structure"  "$(printf '%s' "$out" | field '["details"][1]')" "Model: GPT-5.6-Terra"
check "structure not in blob" "$(printf '%s' "$out" | grep -c ghp_NOTATOKEN || true)" "0"

cfg 'model = "gpt-5.6-luna"
'
out="$(USAGE_METER_CODEX_MODELS=0 collect "$HERE/paid-two-windows.json" cfg5)"
check "MODELS=0 drops rows"  "$(printf '%s' "$out" | field '["details"]')" "['Credits: 1,250']"
check "MODELS=0 keeps bars"  "$(printf '%s' "$out" | field '["limits"].__len__()')" "2"
: >"$WORK/home/.codex/config.toml"

say "no model/list — a codex too old to have it keeps its windows"
out="$(collect "$HERE/no-model-list.json" nomodels)"
check "windows survive"   "$(printf '%s' "$out" | field '["limits"].__len__()')" "2"
check "no model row"      "$(printf '%s' "$out" | field '["details"]')" "['Credits: 1,250']"

say "cache version — a cache from an older collector is not a cache"
mkdir -p "$WORK/cache-stale"
printf '{"fetched_at": 99999999999, "data": {"email": "old@example.com", "plan": "old", "rate_limits": {}}}' \
  >"$WORK/cache-stale/codex-usage.json"
out="$(collect "$HERE/paid-two-windows.json" stale)"
check "refetched, not served" "$(printf '%s' "$out" | field '["plan"]')" "pro"

say "agy — installed before its first status-line quota"
mkdir -p "$WORK/gemini/antigravity-cli"
printf '#!/bin/bash\nexit 0\n' >"$WORK/bin/agy"; chmod +x "$WORK/bin/agy"
out="$(GEMINI_HOME="$WORK/gemini" collect "$HERE/paid-two-windows.json" agy)"
check "agy key present"   "$(printf '%s' "$out" | python3 -c 'import json,sys; print("agy" in json.loads(sys.stdin.read()))')" "True"
check "agy waits for quota" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["agy"]["note"])')" "Open agy once to collect its quota"
check "agy has no limits" "$(printf '%s' "$out" | python3 -c 'import json,sys; print("limits" in json.loads(sys.stdin.read())["agy"])')" "False"
out="$(collect "$HERE/paid-two-windows.json" noagy)"
check "no agy, no key"    "$(printf '%s' "$out" | python3 -c 'import json,sys; print("agy" in json.loads(sys.stdin.read()))')" "False"

say "malformed — every field the wrong type"
out="$(collect "$HERE/malformed.json" bad)"
check "section survives"  "$(printf '%s' "$out" | python3 -c 'import json,sys; print("codex" in json.loads(sys.stdin.read()))')" "True"
check "not ok"            "$(printf '%s' "$out" | field '["ok"]')" "False"
check "says why"          "$(printf '%s' "$out" | field '["note"]')" "codex reported no usage window"
check "invents no number" "$(printf '%s' "$out" | field '.get("limits", [])')" "[]"

say "absence — no codex home, so no codex key at all"
out="$(CODEX_HOME="$WORK/nothing-here" PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" \
       USAGE_METER_CACHE_DIR="$WORK/cache-absent" bash "$COLLECTOR")"
check "no codex key"      "$(printf '%s' "$out" | python3 -c 'import json,sys; print("codex" in json.loads(sys.stdin.read()))')" "False"
check "claude key stays"  "$(printf '%s' "$out" | python3 -c 'import json,sys; print("claude" in json.loads(sys.stdin.read()))')" "True"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
