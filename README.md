# Claude Meter

A macOS menu-bar item that shows how much of your Claude usage limits you have
actually spent: the 5-hour session window, the weekly all-models window and the
weekly premium-model window, each against its real ceiling, read from the same
OAuth usage endpoint Claude Code's own `/usage` command calls.

The numbers are real, not derived. Token counts without a denominator are
noise; a percentage against the limit that will actually stop you is the only
number worth putting in a menu bar.

There is no Xcode project. Two `swiftc` invocations over one Swift file each
(the app, and the renderer that draws the app's icon from code) are the whole
build, and the result is ad-hoc signed. Nothing is fetched, nothing is vendored.

---

## What it shows

**In the menu bar:** a 16 px glyph of three stacked mini-bars — session on top,
week in the middle, premium week at the bottom — and one number beside it.

- The number is the **session** percentage, the one that moves while you work.
- If another limit goes hot, that one takes the number over and brings its own
  label with it, so the number is always self-describing: `wk 92%`, `pm 78%`.
- A bar is blue, purple or teal by series so three limits sitting at similar low
  percentages can still be told apart. At 75% or a `warning` severity it turns
  orange; at 90% or `critical`, red.
- A small **dot at the top-right of the glyph** is the meter's own health, never
  a limit: yellow means the data being shown is more than 45 minutes old, red
  means the collector itself is failing. It is deliberately separate from the
  limit colours so "the meter is sick" can never masquerade as "a limit is hot".
- A greyed-out number (instead of the usual label colour) means the same thing:
  what you are reading is stale.

**In the dropdown:** the account email and which identity it belongs to; one
line saying where the numbers came from and how old they are; a full-width
gauge per limit with its exact percentage and time to reset; and a graph of how
the three limits have moved over the recorded history, auto-scaled to the peak
with the top tick labelled (on a fixed 0–100 axis these limits flatline along
the bottom most of the time — honest, and useless).

If the live fetch is down, the dropdown says so in words, with the reason and
the retry time. A silent fallback to an old cache is indistinguishable from
freshness, which is the one lie a meter must not tell.

---

## Requirements

- macOS 14 or later (the bundle declares `LSMinimumSystemVersion` 14.0).
- Xcode Command Line Tools, for `swiftc`: `xcode-select --install`.
  Full Xcode is optional — it supplies `actool`, which compiles the
  appearance-aware (light and dark) app icon. Without it the build falls back
  to a legacy `.icns` and says so.
- Claude Code, signed in at least once. The collector reads that account's
  OAuth token from your login keychain and its cached utilisation from Claude
  Code's own config file. It never writes either.
- `python3` and `curl` — both ship with the Command Line Tools / macOS.

---

## Install

```sh
git clone <this repo> claude-meter
cd claude-meter
bash install.sh
```

That builds `Claude Meter.app` into `/Applications`, installs the collector to
`~/.local/bin/claude-meter-stats`, renders
`launchd/com.ayushsharma.claude-meter.plist.template` into
`~/Library/LaunchAgents/`, and loads the agent. The item appears in the menu bar
within a few seconds. Everything it touches belongs to your user: no `sudo`, no
system directories.

Build without installing anything (useful for trying a change while the
installed meter keeps running):

```sh
APP_DIR=/tmp/cm bash build.sh     # or: bash build.sh --out /tmp/cm
```

`build.sh` is idempotent: it rebuilds only when something in `Sources/` or the
script itself is newer than the built binary, and it only restarts the launchd
agent when it built into the default `/Applications`.

Overrides, honoured by both scripts: `APP_DIR` (output directory), `APP_NAME`
(bundle name), `BIN_DIR` (where the collector goes), `AGENT_LABEL` (launchd
label).

### Bundle identifier and launchd label

The bundle id is `local.ayushsharma.claude-meter` and the agent label is
`com.ayushsharma.claude-meter`. **Change them before your first build if you
want your own** — macOS keys every TCC privacy grant to the bundle id, so
changing it after the fact makes the system forget every permission the app was
given, and the app's single-instance sweep uses the same id. The bundle id is
in `build.sh` (in the `Info.plist` heredoc) and in `Sources/main.swift`; the
label is the `AGENT_LABEL` default in `build.sh` and `install.sh`.

## Uninstall

```sh
bash uninstall.sh            # or: bash install.sh --uninstall
bash uninstall.sh --purge    # also delete ~/.cache/claude-meter
```

Unloads the agent and removes the plist, the collector and the app. The cache
(the API answer, the backoff stamp and the usage history) is kept unless you
pass `--purge`.

---

## How identities are detected

One Mac can hold more than one Claude Code identity — a personal account and a
work account, say — each in its own config directory, each caching its own
account's utilisation. The collector reads all of them and shows exactly one.

**Which directories are considered**, in order:

1. `CLAUDE_METER_CONFIG_DIRS` (colon-separated) replaces the list entirely.
2. Otherwise: whatever `CLAUDE_CONFIG_DIR` names, then the default `~/.claude`,
   then any `~/.claude-<name>` directory that actually holds a `.claude.json`.

**Which one is shown:** the identity with the newest **live** session — Claude
Code's own registry at `<config dir>/sessions/<pid>.json`, `updatedAt`, with the
pid still alive — and the freshest cached utilisation only breaks a tie. An
identity with no cached utilisation is still a candidate, because right after a
`/login` the new account has none; skipping it is how an earlier version ended
up wearing the other identity's hours-old account (fixed 2026-09-09).

**The keychain item** is derived, not searched: Claude Code keys its credentials
to the config directory, using the bare service name `Claude Code-credentials`
for the default `~/.claude` and appending `sha256(<absolute config dir>)[:8]`
for any other. Deriving it pins each fetch to that identity's own token — the
alternative, trying every token in turn, means one identity's failure can return
another account's numbers under the first one's name.

Labels in the UI come from the directory: `~/.claude` is `default`,
`~/.claude-personal` is `personal`.

---

## Polling, caching and rate limits

The app polls the collector every 30 seconds (and on wake, and whenever the menu
is opened). The collector does **not** call the network every time.

- The usage endpoint is called at most once per TTL: **120 s** while a `claude`
  process is alive, **900 s** when idle. Limits move slowly, and a 25 s TTL
  against a 30 s poll is ~120 requests/hour, which the endpoint answered with
  `429` — and kept answering, because every poll retried instantly (2026-09-01).
- Any fetch failure writes a **backoff stamp** — 900 s for a 429, 180 s
  otherwise — and no network attempt happens while it is fresh.
- What is displayed is the **freshest** of the last good API answer and Claude
  Code's own session cache, whichever that is, with its age reported.
- The API answer is cached per identity **and** per account email, so switching
  accounts can never show the previous one's numbers.
- The token reaches `curl` through a mode-0600 config file, never through argv,
  so it cannot appear in `ps`. Nothing prints or logs it.
- A history point is appended only when a value changes or 10 minutes pass, and
  the file is capped at 2000 rows — a few tens of KB.

Cache location: `~/.cache/claude-meter/` (`CLAUDE_METER_CACHE_DIR` overrides).
It holds `usage-api.json`, `usage-api.backoff`, `usage-history.csv` and the
agent's stderr log.

The app runs the collector with a 25 s watchdog: the collector bounds its own
slow path (`curl --max-time 15`), so the watchdog only trips when something is
genuinely wedged, and it turns a silent freeze into a visible error state.

---

## Colour

Everything **drawn** — the glyph, the badge dot, the dropdown gauges and the
graph — uses muted variants of the system colours: each is blended 38% toward
mid-grey. A menu-bar meter sits beside monochrome template icons, where full
saturation reads as an alarm, and a meter is furniture, not an alert box.
Severity red and orange go through the same blend, because the **mark** carries
the alarm — the badge dot, the label that appears beside a hot number — and
colour only names it.

Menu **text** keeps the stock system colours: those rows are ordinary UI, where
the system palette is the convention.

If you extend this app, keep that rule. It is the single instruction that makes
the meter look like part of the menu bar rather than a notification.

---

## Running a program under the app's identity

```sh
"/Applications/Claude Meter.app/Contents/MacOS/ClaudeMeter" --run /bin/bash /path/to/job.sh
```

This runs the program as a **child** of the app and waits for it, passing
stdin/stdout/stderr through and forwarding `SIGTERM`/`SIGINT` so the child's own
cleanup runs. The exit status is the child's.

Why it exists: macOS keys privacy grants (Full Disk Access, Files and Folders,
Automation) to the **responsible process**, and a launchd job's responsible
process is its own executable. A bare `/bin/bash` spawned by launchd therefore
gets "Operation not permitted" on paths a user-launched app reads fine, and it
cannot usefully be granted anything, because the grant would attach to
`/bin/bash` itself. A child of this app inherits this bundle's identity, and so
this bundle's grants. If you have a background job that needs a grant, this is
how it gets one without giving `/bin/bash` the keys to everything.

It spawns and waits, never `exec`s: `exec` would replace this image with the
program and the identity along with it. The CLI branch runs before any AppKit
global is touched, because `NSStatusBar.system` registers the process with
LaunchServices as a running copy of this app — and the UI's single-instance
sweep then kills the `--run` parent mid-job (measured 2026-09-06).

---

## Data contract

Anything wiring this app up from the outside — a config-management run, a Nix
module, another launcher — depends on these three things and nothing else.

**App CLI**

| Invocation | Behaviour |
|---|---|
| `ClaudeMeter` | Runs the menu-bar app. Terminates any other running instance of the same bundle id first. |
| `ClaudeMeter --run <program> [args…]` | Spawns the program as a child, waits, exits with its status. Never draws a menu-bar item. |

**Collector output** — `claude-meter-stats` prints one JSON object on stdout:

```json
{"claude": { ... }, "ts": 1789210900}
```

The app reads `root["claude"]` and, inside it:

| Field | Type | Meaning |
|---|---|---|
| `ok` | bool | False (and nothing else) when no identity could be read. |
| `account` | string | Identity label, e.g. `default`, `personal`. |
| `email` | string | The account's email, shown in the dropdown header. |
| `source` | string | `api` (live endpoint) or `session-cache` (Claude Code's own file). |
| `age_s` | int | Seconds since the shown numbers left the API. |
| `stale_hours` | float | The same age in hours; read only if `age_s` is absent. |
| `fetch_err` | string | Why the live path is down: `rate-limited`, `no valid token`, `bad response`, `network error`. Absent when it is up. |
| `retry_in` | int | Seconds until the collector will try the endpoint again. |
| `session`, `weekly`, `scoped` | object | One per limit: `pct` (int), `reset_in` (seconds, 0 = unknown or lapsed), `severity` (`normal` / `warning` / `critical`). |

`scoped` is the weekly cap for premium models; the UI calls it "Premium" in the
dropdown and `pm` in the bar.

The app locates the collector at: `$CLAUDE_METER_STATS`, then
`~/.local/bin/claude-meter-stats`, then `/usr/local/bin/claude-meter-stats`,
then `/opt/homebrew/bin/claude-meter-stats` — first executable wins.

**launchd agent** — `launchd/com.ayushsharma.claude-meter.plist.template`, with
`__LABEL__`, `__APP__` (the app's executable) and `__LOG__` substituted:
`RunAtLoad` and `KeepAlive` true, `ProcessType` `Interactive` (a person is
looking at it; it must not be throttled into the background band),
`StandardOutPath` `/dev/null`, `StandardErrorPath` the log. `ProgramArguments`
waits for the binary to exist before `exec`ing it, so an agent bootstrapped
before the app is built sleeps instead of crash-looping.

---

## Troubleshooting

**Nothing in the menu bar.** Read the agent's stderr log,
`~/.cache/claude-meter/claude-meter.launchd.log`, and check the job:
`launchctl print gui/$(id -u)/com.ayushsharma.claude-meter`.

**A dash instead of a number, or a yellow dot.** Run the collector by hand:

```sh
bash ~/.local/bin/claude-meter-stats
```

`{"claude": {"ok": false}, ...}` means no identity was found — sign in to Claude
Code once, or point `CLAUDE_METER_CONFIG_DIRS` at the right directory.
`"fetch_err": "no valid token"` means the keychain has no unexpired token for
that identity; Claude Code refreshes it, so run `claude` once.

**Two items in the menu bar.** A second copy of the app is running. The app
terminates other instances of its own bundle id at launch, so this only happens
with a *differently* identified build — check that you have not installed two
bundles with different identifiers.

**The icon is white, or flat.** `actool` was not available, so the build used
the legacy `.icns` (light appearance only). Install Xcode and rebuild with
`bash build.sh --force`.

**The build says `swiftc not usable`.** Install the Command Line Tools:
`xcode-select --install`. `build.sh` exits 0 in that case on purpose, so a
wrapper can report it rather than dying on a build step.

---

## Layout

```
Sources/main.swift    the app: collection, drawing, the menu
Sources/icon.swift    draws the app icon at build time (no binary asset in the repo)
build.sh              two swiftc calls, the icon, ad-hoc signing
bin/claude-meter-stats  the collector: identities, the usage endpoint, the JSON
launchd/…plist.template the resident agent
install.sh            build + install + load; also --uninstall
uninstall.sh          thin wrapper over install.sh --uninstall
```

Comments in these files record *why* a thing is the way it is, and what was
measured, with dates. Several of them describe bugs that were expensive to find;
they are there so the fix cannot be undone by accident.

## Provenance

This is used daily on the author's Macs, where it is installed by a Nix flake
rather than by `install.sh`. It needs none of that: the scripts here are the
whole thing, and they assume nothing about your setup beyond the requirements
listed above.

## License

MIT — see `LICENSE`.
