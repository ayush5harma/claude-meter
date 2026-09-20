#!/usr/bin/env bash
# Drive the REAL collector against each fixture and check what it emits.
#
# These are not unit tests and there is no framework: each case runs
# bin/claude-meter-stats as the menu-bar app runs it, with a `codex` on PATH
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
COLLECTOR="$REPO/bin/claude-meter-stats"
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
  CODEX_FIXTURE="$1" \
  PATH="$WORK/bin:/usr/bin:/bin" \
  HOME="$WORK/home" \
  CODEX_HOME="$WORK/home/.codex" \
  CLAUDE_METER_CACHE_DIR="$WORK/cache-$2" \
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

say() { printf '\n%s\n' "$*"; }

say "free-single-window — the shape this fleet's own account reports"
out="$(collect "$HERE/free-single-window.json" free)"
check "one window"        "$(printf '%s' "$out" | field '["limits"].__len__()')" "1"
check "labelled 30-day"   "$(printf '%s' "$out" | field '["limits"][0]["label"]')" "30-day"
check "plan free"         "$(printf '%s' "$out" | field '["plan"]')" "free"
check "no bucket prefix"  "$(printf '%s' "$out" | field '["limits"][0]["label"].split()[0]')" "30-day"

say "paid-two-windows — the 5-hour + weekly pair a paid plan reports"
out="$(collect "$HERE/paid-two-windows.json" paid)"
check "two windows"       "$(printf '%s' "$out" | field '["limits"].__len__()')" "2"
check "first is 5h"       "$(printf '%s' "$out" | field '["limits"][0]["label"]')" "5h"
check "second is Weekly"  "$(printf '%s' "$out" | field '["limits"][1]["label"]')" "Weekly"
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
check "reached=critical"  "$(printf '%s' "$out" | field '["limits"][2]["severity"]')" "critical"
check "other bucket calm" "$(printf '%s' "$out" | field '["limits"][0]["severity"]')" "normal"
check "state in words"    "$(printf '%s' "$out" | field '["details"][0]')" "Rate limit reached"
check "unlimited credits" "$(printf '%s' "$out" | field '["details"][1]')" "Credits: unlimited"

say "malformed — every field the wrong type"
out="$(collect "$HERE/malformed.json" bad)"
check "section survives"  "$(printf '%s' "$out" | python3 -c 'import json,sys; print("codex" in json.loads(sys.stdin.read()))')" "True"
check "not ok"            "$(printf '%s' "$out" | field '["ok"]')" "False"
check "says why"          "$(printf '%s' "$out" | field '["note"]')" "codex reported no usage window"
check "invents no number" "$(printf '%s' "$out" | field '.get("limits", [])')" "[]"

say "absence — no codex home, so no codex key at all"
out="$(CODEX_HOME="$WORK/nothing-here" PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK/home" \
       CLAUDE_METER_CACHE_DIR="$WORK/cache-absent" bash "$COLLECTOR")"
check "no codex key"      "$(printf '%s' "$out" | python3 -c 'import json,sys; print("codex" in json.loads(sys.stdin.read()))')" "False"
check "claude key stays"  "$(printf '%s' "$out" | python3 -c 'import json,sys; print("claude" in json.loads(sys.stdin.read()))')" "True"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
