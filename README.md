# Claude Meter

Claude Meter is a macOS menu-bar item that shows how much of your Claude usage
limits you have spent: the 5-hour session window, the weekly all-models window
and the weekly per-model-family window, each as a percentage of the ceiling that
will actually stop you. The numbers come from the same OAuth usage endpoint
Claude Code's `/usage` command calls, and every reading carries its age, so a
stale one looks stale rather than passing for current.

## Install

You need macOS, the Xcode Command Line Tools (`xcode-select --install`, for
`swiftc`), and Claude Code signed in at least once. `python3` and `curl` come
with the tools and the system.

```sh
git clone https://github.com/ayush5harma/claude-meter
cd claude-meter
bash install.sh
```

That builds `Claude Meter.app` into `/Applications`, installs the collector to
`~/.local/bin/claude-meter-stats`, writes a launchd agent into
`~/Library/LaunchAgents/` and loads it. The item appears in the menu bar within
a few seconds, and comes back at every login.

Nothing here needs `sudo`, but `/Applications` is writable only by an admin
account. On a standard account, install per-user instead — the bundle works
anywhere, and Finder and Spotlight already know `~/Applications`:

```sh
APP_DIR="$HOME/Applications" bash install.sh
```

Everything else it writes is yours: `~/.local/bin`, `~/Library/LaunchAgents`
and `~/.cache/claude-meter`. It says so if `~/.local/bin` is not on your PATH,
which matters only for running the collector by hand. `bash install.sh --force`
rebuilds even when nothing has changed.

To remove it:

```sh
bash uninstall.sh            # or: bash install.sh --uninstall
bash uninstall.sh --purge    # also delete ~/.cache/claude-meter
```

The cache (the API answer, the backoff stamp and the usage history) is kept
unless you pass `--purge`, and `--purge` refuses to delete anything that is not
an absolute path at least two levels deep holding at least one of this app's own
files — `CLAUDE_METER_CACHE_DIR` is an environment variable, and `rm -rf` does
not get the benefit of the doubt.

Built and used on macOS 26 and 27. The sources use no API newer than macOS 14
and the bundle declares `LSMinimumSystemVersion` 14.0, but nothing older than 26
has been tested — treat 14 to 25 as unverified.

## Use

**In the menu bar:** a 16 px glyph of three stacked mini-bars — session on top,
week in the middle, the per-model weekly cap at the bottom — and one number
beside it.

- The number is the **session** percentage, the one that moves while you work.
- If another limit goes hot, that one takes the number over and brings its own
  label, so the number is always self-describing: `wk 92%`, or the model name
  the usage endpoint gave the third limit, `Fable 78%`.
- A bar is blue, purple or teal by series, so three limits sitting at similar
  low percentages can still be told apart. At 75% or a `warning` severity it
  turns orange; at 90% or `critical`, red.
- A **dot at the top-right of the glyph** is the meter's own health, never a
  limit: yellow means the data being shown is more than 45 minutes old (or that
  nothing has been collected yet), red means the collector itself is failing —
  three polls in a row, or 150 seconds, without a usable answer. A greyed-out
  number says the same as either dot.

**In the dropdown:** the account email and which identity it belongs to; one
line saying where the numbers came from and how old they are; a full-width gauge
per limit with its exact percentage and time to reset; and a graph of how the
three limits have moved over the recorded history, auto-scaled to the peak with
the top tick labelled (on a fixed 0-100 axis these limits flatline along the
bottom most of the time — honest, and useless). The percentages are the ones
last collected, with their age worked out as you look; opening the menu also
starts a collection, so the bar, and the next look, are fresh. `Refresh Now`
(⌘R) collects immediately. `Quit Claude Meter` (⌘Q) exits the app, but the launchd agent keeps
it alive and starts it again a moment later; to stop it for longer, unload the
agent (`launchctl bootout gui/$(id -u)/com.ayushsharma.claude-meter`) or
uninstall.

If the live fetch is down, the dropdown says so in words, with the reason and
the retry time, instead of quietly showing an old cache.

One Mac can hold more than one Claude Code identity — a personal account and a
work account, say. The meter reads all of them and shows the one you are
working in; see [Identities](#identities) to name them yourself.

## How it works

Two pieces, and a launchd agent that keeps the app running.

- **`bin/claude-meter-stats`**, a shell script wrapping a Python program, prints
  one JSON object: the three limits of the identity you are working in, the
  account it belongs to, where the numbers came from and how old they are. It
  reads Claude Code's own config files, derives that identity's keychain item to
  get its OAuth token, and calls the usage endpoint at most once per TTL,
  falling back to Claude Code's cached numbers when the live path is down.
- **`Sources/main.swift`**, the app, runs the collector every 30 seconds (and at
  wake, and whenever the menu is opened), draws the glyph and the number, and
  rebuilds the dropdown every time it opens.

The app never touches the network or the keychain, and the collector never draws
anything. Neither writes to Claude Code's own files.

## Build from source

There is no Xcode project. Two `swiftc` invocations over one Swift file each
(the app, and the renderer that draws the app's icon from code) are the whole
build, and the result is ad-hoc signed. Nothing is fetched, nothing is vendored.

```sh
bash build.sh                    # into /Applications
APP_DIR=/tmp/cm bash build.sh    # or: bash build.sh --out /tmp/cm
bash build.sh --force            # rebuild even if nothing changed
```

`build.sh` rebuilds only when something in `Sources/` or the script itself is
newer than the built binary, and it restarts the launchd agent only when it
built into the default `/Applications` — so a scratch build can be tried while
the installed meter keeps running.

Full Xcode is optional. It supplies `actool`, which compiles the
appearance-aware (light and dark) app icon; without it the build falls back to a
legacy `.icns` and says so. If `swiftc` is not usable, `build.sh` says so and
exits 0 on purpose, so a wrapper can report the missing tools rather than dying
on a build step.

Both scripts take the same overrides: `APP_DIR` (output directory), `APP_NAME`
(bundle name) and `AGENT_LABEL` (launchd label); `BIN_DIR` (where the collector
goes) is `install.sh` only.

## Reference

### Identities

**Which directories are considered**, in order:

1. `CLAUDE_METER_CONFIG_DIRS` (colon-separated) replaces the list entirely.
2. Otherwise: whatever `CLAUDE_CONFIG_DIR` names, then the default `~/.claude`,
   then any `~/.claude-<name>` directory that actually holds a `.claude.json`.

**Which one is shown:** the identity with the newest **live** session — Claude
Code's own registry at `<config dir>/sessions/<pid>.json`, `updatedAt`, with the
pid still alive — and the freshest cached utilisation only breaks a tie. An
identity with no cached utilisation is still a candidate, because right after a
`/login` the new account has none.

**Naming them yourself.** An entry in `CLAUDE_METER_CONFIG_DIRS` may be
`label=path` instead of a bare path, and the label is then what the dropdown
header and the usage history record:

```sh
CLAUDE_METER_CONFIG_DIRS="work=$HOME/.claude:personal=$HOME/.claude-personal"
```

A bare path keeps the directory-derived name: `~/.claude` is `default`,
`~/.claude-personal` is `personal`. The `label=path` form is recognised only
when the part before the first `=` is a bare name with no `/` in it, so a
directory whose own name contains an `=` is still read as a path. Set the
variable in whatever launches the meter — for the launchd agent, add an
`EnvironmentVariables` dict to the plist.

**The keychain item** is derived, not searched: Claude Code keys its credentials
to the config directory, using the bare service name `Claude Code-credentials`
for the default `~/.claude` and appending `sha256(<absolute config dir>)[:8]`
for any other. Deriving it pins each fetch to that identity's own token — the
alternative, trying every token in turn, means one identity's failure can return
another account's numbers under the first one's name.

Because that hash is over the **path string**, give a directory the same
absolute path, with no trailing slash, that `CLAUDE_CONFIG_DIR` was given.
`/Users/you/.claude-work` and `/Users/you/.claude-work/` hash differently, and
so does a path through a symlink. Nothing in the collector resolves or rewrites
the path to paper over a mismatch, and the failure is quiet: the dropdown says
`no valid token` and falls back to Claude Code's own cached numbers.

### Polling, caching and rate limits

The app polls the collector every 30 seconds. The collector does **not** call
the network every time.

- The usage endpoint is called at most once per TTL: **120 s** while a `claude`
  process is alive, **900 s** when idle.
- Any fetch failure writes a **backoff stamp** — 900 s for a 429, 180 s
  otherwise — and no network attempt happens while it is fresh.
- What is displayed is the **freshest** of the last good API answer and Claude
  Code's own session cache, whichever that is, with its age reported.
- The API answer is cached per identity **and** per account email, so switching
  accounts can never show the previous one's numbers.
- The token reaches `curl` on **stdin** (`--config -`), never through argv and
  never through a file: argv is readable by any process through `ps`, and a
  temporary file puts the token on disk even if it is created 0600 and deleted
  afterwards. Nothing prints or logs it.
- The cache directory is created 0700 and `usage-api.json` is written 0600: it
  is not a credential, but it holds the account's email and the full usage
  response, and no other account on the Mac needs either.
- A history point is appended only when a value changes or 10 minutes pass, and
  the file is capped at 2000 rows — a few tens of KB. The graph draws the most
  recent 400 of them.

The app runs the collector with a 25 s watchdog. The collector bounds its own
slow path (`curl --max-time 15`), so the watchdog only trips when something is
genuinely wedged, and it turns a silent freeze into a visible error state.

### Files

```
~/.cache/claude-meter/usage-api.json       the last good API answer
~/.cache/claude-meter/usage-api.backoff    when the network path may be tried again
~/.cache/claude-meter/usage-history.csv    the points the dropdown graphs
~/.cache/claude-meter/claude-meter.launchd.log   the agent's stderr
```

`CLAUDE_METER_CACHE_DIR` moves that directory for the collector and the
installer. The app's history graph always reads `~/.cache/claude-meter`, so
pointing the collector elsewhere leaves the graph empty.

In the repository:

```
Sources/main.swift      the app: collection, drawing, the menu
Sources/icon.swift      draws the app icon at build time (no binary asset in the repo)
build.sh                two swiftc calls, the icon, ad-hoc signing
bin/claude-meter-stats  the collector: identities, the usage endpoint, the JSON
launchd/…plist.template the resident agent
install.sh              build + install + load; also --uninstall
uninstall.sh            thin wrapper over install.sh --uninstall
```

Comments in these files record why a thing is the way it is, and what was
measured, with dates. Several of them describe bugs that were expensive to find;
they are there so the fix cannot be undone by accident.

### Data contract

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
| `ok` | bool | False **and nothing else** when there is nothing honest to show: no identity could be read, or the chosen one has no limits, or has no timestamp to age them by. The app paints its empty state (a dash) rather than a 0%. |
| `account` | string | Identity label, e.g. `default`, `personal`. |
| `email` | string | The account's email, shown in the dropdown header. |
| `source` | string | `api` (live endpoint) or `session-cache` (Claude Code's own file). |
| `age_s` | int | Seconds since the shown numbers left the API. |
| `stale_hours` | float | The same age in hours; read only if `age_s` is absent. |
| `fetch_err` | string | Why the live path is down: `rate-limited`, `no valid token`, `bad response`, `network error`. Absent when it is up. |
| `retry_in` | int | Seconds until the collector will try the endpoint again. Present only alongside `fetch_err`. |
| `session`, `weekly`, `scoped` | object | One per limit: `pct` (int), `reset_in` (seconds, 0 = unknown or lapsed), `severity` (`normal` / `warning` / `critical`). A reading in the older flat shape, without `limits[]`, has no per-model cap, so `scoped` is then absent. |
| `scoped_label` | string | What the `scoped` cap applies to, for the UI to print. |

`scoped` is the weekly cap that applies to one model family rather than to
everything. Which family is not hardcoded anywhere: the usage endpoint reports
it per limit, and the collector passes that through as `scoped_label` (the
response shape it reads from, and when it was inspected, are in the collector's
comments). When the response names nothing the collector emits `"Model"`, and
the app falls back to `"Model"` too if the field is absent entirely — an older
collector, say. The app truncates it to 12 characters in the menu bar, where
width is not free, and prints it in full in the dropdown.

**Collector environment** — `CLAUDE_METER_CONFIG_DIRS` (colon-separated config
dirs, each optionally `label=path`, replacing discovery), `CLAUDE_CONFIG_DIR`
(Claude Code's own, added to the defaults), `CLAUDE_METER_CACHE_DIR`,
`USAGE_API_TTL`.

The app locates the collector at: `$CLAUDE_METER_STATS`, then
`~/.local/bin/claude-meter-stats`, then `/usr/local/bin/claude-meter-stats`,
then `/opt/homebrew/bin/claude-meter-stats` — first executable wins.

**launchd agent** — `launchd/com.ayushsharma.claude-meter.plist.template`, with
`__LABEL__`, `__APP__` (the app's executable) and `__LOG__` substituted:
`RunAtLoad` and `KeepAlive` true, `ProcessType` `Interactive` (a person is
looking at it; it must not be throttled into the background band),
`StandardOutPath` `/dev/null`, `StandardErrorPath` the log. `ProgramArguments`
waits for the binary to exist, looking every five minutes, before `exec`ing it,
so an agent bootstrapped before the app is built sleeps instead of
crash-looping.

### Bundle identifier and launchd label

The bundle id is `local.ayushsharma.claude-meter` and the agent label is
`com.ayushsharma.claude-meter`. **Change them before your first build if you
want your own** — macOS keys every TCC privacy grant to the bundle id, so
changing it after the fact makes the system forget every permission the app was
given, and the app's single-instance sweep uses the same id. The bundle id is in
`build.sh` (in the `Info.plist` heredoc) and in `Sources/main.swift`; the label
is the `AGENT_LABEL` default in `build.sh` and `install.sh`.

### Running a program under the app's identity

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
this bundle's grants.

**Know what this costs.** The flag is not a privilege check: anything already
running as you can borrow this app's grants by exec'ing `ClaudeMeter --run`.
That is the same trust boundary every program you run already sits inside, but
it means the grants you give this bundle are effectively grants to your whole
user session — so give it only what you would give any program you run, and if
that is more than you want to hand out, install a separate ad-hoc bundle for the
job that needs the grant rather than widening this one.

Ad-hoc signing also means the code directory hash changes on every rebuild, so
macOS may ask you to approve a grant again after `build.sh`. That prompt is
expected: it is the system noticing the binary is genuinely different.

### Colour

Everything **drawn** — the glyph, the badge dot, the dropdown gauges and the
graph — uses muted variants of the system colours: each is blended 38% toward
mid-grey. A menu-bar meter sits beside monochrome template icons, where full
saturation reads as an alarm, and a meter is furniture, not an alert box.
Severity red and orange go through the same blend, because the **mark** carries
the alarm — the badge dot, the label that appears beside a hot number — and
colour only names it. Menu **text** keeps the stock system colours: those rows
are ordinary UI, where the system palette is the convention.

If you extend this app, keep that rule. It is the single instruction that makes
the meter look like part of the menu bar rather than a notification.

### Troubleshooting

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
`xcode-select --install`.

**`install.sh` says the plist is read-only or a symlink.** Another tool manages
that launchd agent — a Nix flake, or home-manager. `install.sh` will not write
over it; uninstall that first, or leave Claude Meter to it.

### What was measured

The dates in the code comments are what each rule came from. The short version:

- **2026-09-01, the rate limit.** A 25 s TTL against the app's 30 s poll is
  ~120 requests/hour; the endpoint answered `429` and kept answering it, because
  every poll retried instantly. The meter then fell back to the file cache
  forever while still looking live — 30% shown from a 3-hour-old cache while the
  last good API answer, 7 minutes earlier, said 46%. Hence the adaptive TTL, the
  backoff stamp, and reporting the age of whatever is shown.
- **2026-09-06, the CLI and the single-instance sweep.** Touching
  `NSStatusBar.system` registers the process with LaunchServices as a running
  copy of this app, and the sweep then killed a `--run` parent mid-job. The
  `--run` branch therefore runs before any AppKit global.
- **2026-09-07, the build guard and the icon.** A freshness guard that watched
  only `main.swift` let an edit to `icon.swift` never reach the installed
  bundle; `/usr/bin/swiftc` exists on a Mac without the Command Line Tools and
  fails when run, so the guard has to run it.
- **2026-09-09, the identity.** Choosing by the freshest cached utilisation made
  the meter wear the other identity's hours-old account right after a `/login`.
  The newest live session decides; the cache only breaks a tie.
- **2026-09-12, the third limit and the empty state.** The usage endpoint names
  the scoped cap itself, so no model family is hardcoded. A reading with no
  timestamp to age it by is not a reading: it is reported as `ok: false` and the
  app paints a dash, rather than three grey 0% bars that look like data.
- **2026-09-13, the managed plist.** A flake-managed Mac's LaunchAgents are
  read-only or symlinked into the Nix store; the installer refuses to write over
  one rather than silently taking the agent away from its owner.

### Provenance

This is used daily on the author's Macs, where it is installed by a Nix flake
rather than by `install.sh`. It needs none of that: the scripts here are the
whole thing, and they assume nothing about your setup beyond what
[Install](#install) lists.

## Licence

MIT — see [LICENSE](LICENSE).
