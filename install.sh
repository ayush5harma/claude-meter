#!/usr/bin/env bash
# Install Claude Meter for the current user: build the app into /Applications,
# put the collector on PATH, and load the launchd agent that keeps the menu-bar
# item running.
#
# Everything it touches belongs to this user -- no sudo, no system directories,
# nothing outside /Applications, ~/.local/bin, ~/Library/LaunchAgents and
# ~/.cache/claude-meter -- and --uninstall removes exactly those.
#
# Usage:
#   bash install.sh [--force]        build (or rebuild) and load the agent
#   bash install.sh --uninstall      unload the agent and remove what was installed
#   bash install.sh --uninstall --purge   also delete the cache and usage history
#
# Overrides (same names build.sh uses, so the two agree):
#   APP_DIR      directory the bundle is installed into (default /Applications)
#   APP_NAME     bundle name without .app (default "Claude Meter")
#   BIN_DIR      where claude-meter-stats is installed (default ~/.local/bin)
#   AGENT_LABEL  launchd label (default com.ayushsharma.claude-meter)

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${APP_NAME:-Claude Meter}"
APPS_DIR="${APP_DIR:-/Applications}"
BUNDLE="$APPS_DIR/${APP_NAME}.app"
APP_BIN="$BUNDLE/Contents/MacOS/ClaudeMeter"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
STATS="$BIN_DIR/claude-meter-stats"
AGENT_LABEL="${AGENT_LABEL:-com.ayushsharma.claude-meter}"
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
CACHE_DIR="${CLAUDE_METER_CACHE_DIR:-$HOME/.cache/claude-meter}"
LOG="$CACHE_DIR/claude-meter.launchd.log"
DOMAIN="gui/$(id -u)"

MODE=install
FORCE=""
PURGE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --purge) PURGE=1 ;;
    --force) FORCE="--force" ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'install.sh: unknown argument %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

say() { printf '  %s\n' "$*"; }

unload_agent() {
  # bootout returns non-zero when the label is not loaded, which is the normal
  # case on a first install; that is not a failure.
  launchctl bootout "$DOMAIN/$AGENT_LABEL" >/dev/null 2>&1 || true
}

if [ "$MODE" = uninstall ]; then
  unload_agent
  say "agent $AGENT_LABEL unloaded"
  # Say "removed" only about something that was there: `rm -f` succeeds on a
  # path that never existed, and an uninstaller that reports work it did not do
  # is the same lie as a meter reporting a number it did not fetch.
  for p in "$PLIST" "$STATS"; do
    if [ -e "$p" ]; then rm -f "$p" && say "removed $p"; fi
  done
  if [ -d "$BUNDLE" ]; then
    rm -rf "$BUNDLE" && say "removed $BUNDLE"
  fi
  if [ "$PURGE" -eq 1 ]; then
    # CLAUDE_METER_CACHE_DIR is an environment variable, so it can arrive empty
    # or as something no uninstaller should ever recurse into. Refuse anything
    # that is not an absolute path at least three levels deep and holding at
    # least one of this app's own files -- `rm -rf` does not get the benefit of
    # the doubt.
    # The trailing newline matters: awk reads no line at all from an empty
    # string, prints nothing, and the numeric test below would then error out
    # rather than refuse -- which is how CACHE_DIR="/" would have slipped past.
    depth="$(printf '%s\n' "${CACHE_DIR%/}" | awk -F/ '{print NF-1}')"
    if [ -z "$CACHE_DIR" ] || [ "${CACHE_DIR#/}" = "$CACHE_DIR" ] || [ "${depth:-0}" -lt 2 ]; then
      say "refusing to delete '$CACHE_DIR' — not a plausible cache directory"
    elif [ ! -d "$CACHE_DIR" ]; then
      say "no cache at $CACHE_DIR"
    elif [ ! -e "$CACHE_DIR/usage-api.json" ] && [ ! -e "$CACHE_DIR/usage-history.csv" ] \
         && [ ! -e "$CACHE_DIR/usage-api.backoff" ] && [ ! -e "$CACHE_DIR/claude-meter.launchd.log" ]; then
      say "refusing to delete $CACHE_DIR — it holds none of this app's files"
    else
      rm -rf "$CACHE_DIR" && say "removed $CACHE_DIR"
    fi
  else
    say "kept $CACHE_DIR (pass --purge to delete the usage history too)"
  fi
  say "uninstalled"
  exit 0
fi

# ── Build ───────────────────────────────────────────────────────────────────
APP_DIR="$APPS_DIR" bash "$SRC_DIR/build.sh" ${FORCE:+"$FORCE"} || exit 1
if [ ! -x "$APP_BIN" ]; then
  say "no app at $APP_BIN — build.sh could not build it (Xcode Command Line Tools?)"
  exit 1
fi

# ── Collector ───────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" || exit 1
install -m 755 "$SRC_DIR/bin/claude-meter-stats" "$STATS" || exit 1
say "installed $STATS"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  # The app finds the collector by absolute path, so this only matters for
  # running it by hand.
  *) say "note: $BIN_DIR is not on your PATH" ;;
esac

# ── Agent ───────────────────────────────────────────────────────────────────
# The log directory must exist before bootstrap: launchd refuses a job whose
# StandardErrorPath cannot be opened.
mkdir -p "$CACHE_DIR" "$(dirname "$PLIST")" || exit 1
# A plist that is a symlink belongs to something else (a nix-darwin or
# home-manager switch links agents into ~/Library/LaunchAgents from the Nix
# store, read-only): writing over it fails as "Permission denied" and, worse,
# would silently take an agent away from its owner. Measured 2026-09-13 on a
# flake-managed Mac. Say so and stop; that Mac gets the app from its flake.
if [ -L "$PLIST" ]; then
  say "$PLIST is a symlink, so another tool manages this agent (a Nix flake?);"
  say "not touching it. Uninstall that first, or leave Claude Meter to it."
  exit 1
fi
sed -e "s|__LABEL__|$AGENT_LABEL|g" \
    -e "s|__APP__|$APP_BIN|g" \
    -e "s|__LOG__|$LOG|g" \
    "$SRC_DIR/launchd/com.ayushsharma.claude-meter.plist.template" >"$PLIST" || exit 1
/usr/bin/plutil -lint "$PLIST" >/dev/null || { say "rendered plist is not valid: $PLIST"; exit 1; }

# Replace, never reload: `launchctl load` is deprecated and a bootstrap over a
# loaded label fails with "service already loaded", so unload first.
unload_agent
if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
  say "loaded $AGENT_LABEL"
else
  say "could not bootstrap $AGENT_LABEL — check $LOG"
  exit 1
fi
launchctl kickstart -k "$DOMAIN/$AGENT_LABEL" >/dev/null 2>&1 || true

say "done — the meter should be in the menu bar within a few seconds"
say "if it is not, read $LOG and run: bash $SRC_DIR/bin/claude-meter-stats"
exit 0
