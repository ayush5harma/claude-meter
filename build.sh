#!/usr/bin/env bash
# Build "Claude Meter.app" — the menu-bar readout — from the two Swift files in
# Sources/, into /Applications by default.
#
# NO XCODE PROJECT ON PURPOSE. Two `swiftc` invocations — one for the app, one
# for the icon renderer that draws its artwork — are the whole build; there is
# no .xcodeproj to drift, no signing identity to expire, and nothing to fetch.
# The Xcode Command Line Tools supply swiftc.
#
# IDEMPOTENT and version-guarded: it rebuilds only when something in Sources/
# (or this script) is newer than the built binary, so an installer or an
# automation can call it on every run for pennies. Pass --force to rebuild
# regardless.
#
# Usage:
#   bash build.sh [--force] [--out <dir>]
#   APP_DIR=<dir> bash build.sh           # same as --out
#
# --out / APP_DIR is the DIRECTORY the bundle is written into (the bundle lands
# at "<dir>/Claude Meter.app"), so a build can go to a scratch directory and
# never has to replace the copy a launchd agent is running. APP_NAME renames the
# bundle. When the output directory is not the default, the script does NOT
# restart the launchd agent — a scratch build must not take over the menu bar.

set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES="$SRC_DIR/Sources"
APP_NAME="${APP_NAME:-Claude Meter}"
DEFAULT_OUT="/Applications"
OUT_DIR="${APP_DIR:-$DEFAULT_OUT}"
AGENT_LABEL="${AGENT_LABEL:-com.ayushsharma.claude-meter}"
FORCE=0

say() { printf '  %s\n' "$*"; }

# The header comment above IS the help text: printing it from the file keeps the
# two from drifting, and stopping at the first line that is not a comment means
# an edit to the header cannot silently truncate it, the way a hardcoded line
# range once did.
usage() { awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --out) shift; OUT_DIR="${1:-$DEFAULT_OUT}" ;;
    --out=*) OUT_DIR="${1#--out=}" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'build.sh: unknown argument %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

BUNDLE="$OUT_DIR/${APP_NAME}.app"
BIN="$BUNDLE/Contents/MacOS/ClaudeMeter"

# A path is not a compiler: /usr/bin/swiftc is a shim that exists on every Mac
# and fails until the Xcode Command Line Tools are installed, so the guard must
# RUN it (a fresh Mac's first build failed past this line, 2026-09-07). Exit 0
# either way, so an installer that calls this can report the missing tools
# itself rather than dying on a build step.
SWIFTC="$(command -v swiftc 2>/dev/null || xcrun --find swiftc 2>/dev/null)"
[ -n "$SWIFTC" ] && "$SWIFTC" --version >/dev/null 2>&1 \
  || { say "swiftc not usable — install the Xcode Command Line Tools (xcode-select --install)"; exit 0; }

# Nothing in Sources/ and no change to this script is newer than the built
# binary. EVERY file counts, not just main.swift: a guard that watched that one
# alone let an edit to icon.swift compile locally and never reach the installed
# bundle (2026-09-07). Dot-files are excluded because this script writes
# .build.log itself and Finder writes .DS_Store. A bundle with no icon is NOT up
# to date, so a run that failed midway through the artwork retries.
is_up_to_date() {
  [ "$FORCE" -eq 0 ] && [ -x "$BIN" ] \
    && [ -f "$BUNDLE/Contents/Resources/AppIcon.icns" ] \
    && [ -z "$(find "$SOURCES" -type f ! -name '.*' -newer "$BIN" -print -quit)" ] \
    && [ ! "${BASH_SOURCE[0]}" -nt "$BIN" ]
}

# CFBundleIdentifier is load-bearing and deliberately stable: macOS keys every
# TCC privacy grant (and the single-instance sweep in main.swift) to it, so
# changing it makes the system forget every permission this app was given.
# Change it BEFORE the first build if you want your own, never after.
write_info_plist() {
  cat >"$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Meter</string>
  <key>CFBundleDisplayName</key><string>Claude Meter</string>
  <key>CFBundleIdentifier</key><string>local.ayushsharma.claude-meter</string>
  <key>CFBundleExecutable</key><string>ClaudeMeter</string>
  <!-- CFBundleIconFile is the pre-macOS-26 path (Resources/AppIcon.icns).
       CFBundleIconName, which points at the appearance-aware icon inside
       Assets.car, is added by build_icon only when actool produced one. -->
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Menu-bar only: no Dock tile, no app menu. Matches setActivationPolicy(.accessory). -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
}

# Compile beside the target and rename into place: swiftc -o straight onto the
# installed path truncates the inode a RUNNING meter has mapped, which can
# SIGBUS it mid-draw. A same-volume rename gives the new build a fresh inode
# and the old process keeps its pages until it exits.
compile_app() {
  say "compiling"
  if ! "$SWIFTC" -O -whole-module-optimization \
        -framework AppKit \
        -o "$BIN.new" "$SOURCES/main.swift" 2>"$SRC_DIR/.build.log"; then
    say "BUILD FAILED — see $SRC_DIR/.build.log"
    tail -15 "$SRC_DIR/.build.log" | sed 's/^/      /'
    rm -f "$BIN.new"
    exit 1
  fi
  chmod +x "$BIN.new"
  mv -f "$BIN.new" "$BIN"
  rm -f "$SRC_DIR/.build.log"
}

if is_up_to_date; then
  say "${APP_NAME} up to date"
  exit 0
fi

if ! mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"; then
  # /Applications is writable by admin accounts only. A standard account is not
  # stuck: the bundle works anywhere, and ~/Applications is a per-user location
  # Finder and Spotlight already know about.
  say "cannot write to $OUT_DIR"
  [ "$OUT_DIR" = "$DEFAULT_OUT" ] && \
    say "for a per-user install: APP_DIR=\"\$HOME/Applications\" bash install.sh"
  exit 1
fi

write_info_plist
compile_app

# ── App icon ─────────────────────────────────────────────────────────────────
# Drawn from Sources/icon.swift at build time, so no binary asset lives in the
# repo. TWO products from that one source: an Icon Composer .icon package, which
# actool compiles into an Assets.car carrying separate light and dark artwork
# (the .icns format has no notion of appearance, so this is the only way to get
# a dark variant at all), and a legacy AppIcon.icns for everything before
# macOS 26. actool ships inside Xcode.app and NOT with the Command Line Tools,
# so a Mac that has only the CLT falls back to the icns alone — iconutil does
# ship with them.
build_icon() {
  local work res plist
  work="$1"
  res="$BUNDLE/Contents/Resources"
  plist="$BUNDLE/Contents/Info.plist"

  if ! "$SWIFTC" -O -framework AppKit -o "$work/iconrender" "$SOURCES/icon.swift" \
        2>"$work/icon.log"; then
    say "icon renderer FAILED to compile"
    sed 's/^/      /' "$work/icon.log" | tail -10
    return 1
  fi
  "$work/iconrender" "$work" || { say "icon renderer FAILED to draw"; return 1; }

  if xcrun --find actool >/dev/null 2>&1; then
    # actool refuses to create its own output directory ("The output directory
    # ... does not exist"), so make it first.
    mkdir -p "$work/car"
    # --standalone-icon-behavior all is load-bearing: by default actool writes
    # an .icns holding only the 16 and 128 pt tiles, and Get Info, the Dock and
    # Finder's larger views all want the rest (measured 2026-09-07).
    if xcrun actool "$work/AppIcon.icon" --compile "$work/car" \
          --platform macosx --minimum-deployment-target 26.0 \
          --app-icon AppIcon --standalone-icon-behavior all \
          --output-partial-info-plist "$work/partial.plist" \
          --output-format human-readable-text --errors >"$work/actool.log" 2>&1 \
       && [ -s "$work/car/Assets.car" ] && [ -s "$work/car/AppIcon.icns" ]; then
      cp -f "$work/car/Assets.car" "$res/Assets.car"
      cp -f "$work/car/AppIcon.icns" "$res/AppIcon.icns"
      /usr/bin/plutil -replace CFBundleIconName -string AppIcon "$plist" >/dev/null 2>&1
      say "icon: Assets.car (light + dark) and AppIcon.icns"
      return 0
    fi
    say "actool could not compile the .icon — using the legacy icns alone"
    sed 's/^/      /' "$work/actool.log" | tail -10
  fi

  # Legacy path. Drop any CFBundleIconName an earlier build left behind, or the
  # plist would point at an Assets.car that is no longer in the bundle.
  rm -f "$res/Assets.car"
  /usr/bin/plutil -remove CFBundleIconName "$plist" >/dev/null 2>&1 || true
  iconutil -c icns -o "$res/AppIcon.icns" "$work/AppIcon.iconset" \
    || { say "iconutil FAILED"; return 1; }
  say "icon: AppIcon.icns (no actool — light appearance only)"
}

ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-meter-icon.XXXXXX")"
build_icon "$ICON_WORK" || say "icon build failed — the bundle keeps the icon it had"
rm -rf "$ICON_WORK"

# Ad-hoc sign so macOS does not kill it for having no signature at all. This is
# a locally built tool, so a real identity buys nothing here. It runs AFTER the
# icon lands: the signature covers Contents/Resources, so writing the icns or
# the car afterwards would invalidate it.
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
/usr/bin/xattr -cr "$BUNDLE" 2>/dev/null || true
# Bump the bundle's mtime and re-index it. LaunchServices caches an app's icon
# against the bundle, and a Finder window already showing the old (or blank) one
# keeps showing it until something invalidates that cache; these two are what
# does it without asking anyone to killall Finder.
touch "$BUNDLE"
/usr/bin/mdimport "$BUNDLE" >/dev/null 2>&1 || true
say "built $BUNDLE"

# The launchd agent (KeepAlive) is still running the OLD binary; kick it so the
# menu bar shows this build now rather than after the next login. Guarded twice:
# a scratch build must not touch the installed meter, and no agent (a fresh
# machine, a first install) is not an error.
if [ "$OUT_DIR" = "$DEFAULT_OUT" ] \
   && launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null \
    && say "restarted the ${AGENT_LABEL} agent" || true
fi
exit 0
