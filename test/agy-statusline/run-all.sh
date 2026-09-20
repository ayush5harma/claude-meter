#!/usr/bin/env bash
# Exercise the documented agy status-line payload through to the collector's
# menu model. No Google account, network or live configuration is needed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.gemini/antigravity-cli" "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/agy"
chmod +x "$tmp/bin/agy"
export HOME="$tmp/home" GEMINI_HOME="$tmp/home/.gemini"
export PATH="$tmp/bin:$PATH" USAGE_METER_CACHE_DIR="$tmp/home/.cache/usage-meter"
export USAGE_METER_CODEX=0 USAGE_METER_CONFIG_DIRS="$tmp/home/no-claude"

printf '%s\n' '{"model":{"display_name":"Gemini Pro"},"plan_tier":"Pro","quota":{"weekly":{"remaining_fraction":0.16,"reset_in_seconds":3600},"daily":{"remaining_fraction":0.6,"reset_in_seconds":400}}}' \
  | "$root/bin/agy-usage-statusline" > "$tmp/status"
rg -q 'quota 84%' "$tmp/status"
test "$(stat -f %Lp "$USAGE_METER_CACHE_DIR/agy-quota.json")" = 600
"$root/bin/usage-meter-stats" > "$tmp/collector"
jq -e '.agy.ok == true and (.agy.limits | length) == 2 and
       (.agy.limits[] | select(.label == "weekly") | .pct) == 84 and
       .agy.source == "agy status line"' "$tmp/collector" >/dev/null

# Empty or malformed updates leave the last real quota in place.
printf '%s\n' '{"quota":{}}' | "$root/bin/agy-usage-statusline" > /dev/null
printf '%s\n' 'not JSON' | "$root/bin/agy-usage-statusline" > /dev/null
"$root/bin/usage-meter-stats" | jq -e '.agy.ok == true' >/dev/null
printf 'agy status line -> private cache -> Usage Meter: PASS\n'
