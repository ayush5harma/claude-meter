# Claude Meter

Claude Meter is a macOS menu-bar item that shows how much of your Claude usage
limits you have spent: the 5-hour session window, the weekly all-models window
and the weekly per-model-family window, each as a percentage of the ceiling that
will actually stop you. The numbers come from the same OAuth usage endpoint
Claude Code's `/usage` command calls, and every reading carries its age, so a
stale one looks stale rather than passing for current.

If another agentic CLI is installed on the same Mac and can report its own
quota locally, it gets a bar in the menu-bar glyph and a section in the
dropdown, under Claude's — today that is [Codex](#codex--supported). One that
is installed but exposes no number gets a single line saying so, which today is
[Antigravity](#antigravity-agy--installed-but-unreadable). A tool you do not
have contributes nothing at all — no bar, no section, no empty row, no error.

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
not get the benefit of the doubt. The one gap: an explicitly EMPTY
`CLAUDE_METER_CACHE_DIR` falls back to the default directory and is purged, so
unset the variable rather than emptying it.

Built and used on macOS 26 and 27. The sources use no API newer than macOS 14
and the bundle declares `LSMinimumSystemVersion` 14.0, but nothing older than 26
has been tested — treat 14 to 25 as unverified.

## Use

**In the menu bar:** a 16 px glyph of stacked mini-bars and one number beside
it. The stack is **Claude's three windows — session, week, the per-model weekly
cap — and then one bar for every other tool the meter has a number for**, set
off by a slightly wider gap. Claude alone is three bars; Claude and Codex, four.

- The number is the **session** percentage, the one that moves while you work.
- If any window goes hot — Claude's or another tool's — that one takes the
  number over and brings its own label, so the number is always
  self-describing: `wk 92%`, the model name the usage endpoint gave the third
  limit (`Fable 78%`), or a tool's tag when the hot window is not Claude's
  (`cdx 96%`).
- A bar is blue, purple, teal, indigo or green by series, so windows sitting at
  similar low percentages can still be told apart. At 75% or a `warning`
  severity it turns orange; at 90% or `critical`, red.
- The item never gets **wider** as tools are added: at five bars the stack
  tightens by a tenth rather than the item growing, so nothing else in the menu
  bar moves.
- A **dot at the top-right of the glyph** is the meter's own health, never a
  limit: yellow means the data being shown is more than 45 minutes old (or that
  nothing has been collected yet), red means the collector itself is failing —
  three polls in a row, or 150 seconds, without a usable answer. A greyed-out
  number says the same as either dot.

**In the dropdown:** one section per installed tool, in a fixed order, each
with the same four parts in the same places, so the eye learns one layout:

1. **Name · identity · plan** — `Claude · you@example.com · personal`,
   `Codex · you@example.com · pro`. The name appears only when there is more
   than one section: with one tool there is nothing to tell apart, so a Mac
   with only Claude reads exactly as it always has.
2. **Where the number came from and how old it is** — `Usage API · fetched 8s
   ago`, `codex app-server · read 2m ago`. If the live fetch is down it says so
   in words, with the reason and the retry time, instead of quietly showing an
   old cache.
3. **One full-width gauge per window**, with its exact percentage and time to
   reset. Claude's section also carries a graph of how its three limits have
   moved over the recorded history, auto-scaled to the peak with the top tick
   labelled (on a fixed 0-100 axis these limits flatline along the bottom most
   of the time — honest, and useless). Other tools have no recorded history, so
   they draw rows only rather than an empty plot that promises one.
4. **Facts that are not percentages** — the model in use, the models available,
   credits, a ceiling the backend says has been reached.

A tool that is installed but **signed out** gets its section with the sign-in
hint in place of the bars. A tool that is installed but has **no number to
give** gets one dim line after the last section rather than a section that
could only ever say "no data" — today that is Antigravity, and
[the reason is below](#antigravity-agy--installed-but-unreadable). A tool that
is not installed contributes nothing at all.

The percentages are the ones last collected, with their age worked out as you
look; opening the menu also starts a collection, so the bar, and the next look,
are fresh. `Refresh Now` (⌘R) collects immediately. `Quit Claude Meter` (⌘Q)
exits the app, but the launchd agent keeps it alive and starts it again a
moment later; to stop it for longer, unload the agent (`launchctl bootout
gui/$(id -u)/com.ayushsharma.claude-meter`) or uninstall.

### Why the glyph is shaped that way

With more than one tool installed, a meter that shows only Claude is not a
meter: a Codex window at 96% would be invisible until somebody opened the menu.
Two other shapes were considered for the 16 px item and both lost.

- **One bar for the tightest window across every tool, with a letter saying
  whose.** On the commonest Mac — Claude alone — it throws away two of the
  three limits that are legible there today, to solve a problem that Mac does
  not have; and it puts a glyph, a letter and a number in 16 px, which is three
  things competing for one glance.
- **One bar per tool, uniformly.** The same objection in a weaker form: with
  one tool installed it is a single bar where three fit. What ships *is* this,
  for every tool except the one the app is named for — the only tool whose
  per-window detail the item already has room for.
- **Rotating between tools** was rejected outright. A value that changes while
  nothing changed is noise, and a meter that is sometimes showing you the other
  tool is one you cannot read at a glance.

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
  falling back to Claude Code's cached numbers when the live path is down. It
  adds a key per other agentic CLI it finds installed, and none for one it does
  not.
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
`EnvironmentVariables` dict to the plist. `install.sh` re-renders that plist from
the template on every run, so re-apply the dict afterwards, or let whatever else
manages the agent own the file.

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

Codex is asked on the same terms, through its own local server rather than over
the network directly: at most once per TTL (120 s while a `codex` process is
alive, 900 s idle, `CODEX_USAGE_TTL` overrides), a 180 s backoff after a
failure, the answer cached in its own file, and the age of what is shown
reported beside it. The app-server call is bounded at 10 s — measured at 0.79 s,
so the bound is for something wedged rather than a budget — and the child is
killed whatever happens, so a hung server cannot outlive the poll that made it.
A cached poll costs no process at all: the whole collector ran in 0.105 s with
both readings warm, against 1.59 s when both had to be fetched.

The app runs the collector with a **40 s** watchdog — 25 s until Codex was read,
which covered `curl --max-time 15` alone and would have killed a merely-slow run
that also did the 10 s Codex read, reporting a timeout for something that was
working. It is not a bound on every timeout the collector can impose (that sum
exceeded 25 s before Codex existed too); it is the line past which a run is
wedged rather than slow, and crossing it turns a silent freeze into a visible
error state. 40 s still sits well under the 150 s without a good collection that
marks the meter sick.

### Files

```
~/.cache/claude-meter/usage-api.json       the last good API answer
~/.cache/claude-meter/usage-api.backoff    when the network path may be tried again
~/.cache/claude-meter/usage-history.csv    the points the dropdown graphs
~/.cache/claude-meter/codex-usage.json     the last good codex reading (only if codex is installed)
~/.cache/claude-meter/codex-usage.backoff  when codex may be asked again
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
{"claude": { ... }, "ts": 1789210900, "codex": { ... }}
```

`claude` and `ts` are always present. Every other key is a tool that is
installed on this Mac, and is **absent** — not empty, not `ok: false` — when the
tool is not. The app reads `root["claude"]` and, inside it:

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

It reads one key per other tool — today only `codex` — and, inside it:

| Field | Type | Meaning |
|---|---|---|
| `ok` | bool | False when there is nothing honest to show. The section still appears (the tool *is* installed), with `note` saying why. |
| `note` | string | Why there are no numbers, in words: "Not signed in — run `codex login`", "No usage read yet". |
| `email`, `plan` | string | Joined with ` · ` into the section header beside the tool's name. |
| `source` | string | Where the reading came from, printed as-is: `codex app-server`. |
| `age_s` | int | Seconds since the reading was taken. The app adds the time since collection, as it does for Claude. |
| `fetch_err`, `retry_in` | string, int | Why the live read is down and when it is tried again. Absent when it is up. |
| `limits` | array | One object per usage window, in the tool's own order: `label` (string, what the window is), `pct` (int), `reset_in` (seconds, 0 = unknown or lapsed), `severity`. An `ok` section with an empty `limits` is treated as not ok. |
| `details` | array of strings | Facts that are not percentages, already worded by the collector, printed under the bars. The collector owns the words and the app owns the drawing, so a new fact is one line there and none here. |
| `tag` | string | The short form the menu bar has room for when this tool's window is the hottest on the machine and takes the number over (`cdx`). Defaults to the first three letters of the name. |
| `footnote` | bool | True for a tool that is installed but has no number to give. It is drawn as ONE line after the sections, contributes no bar to the glyph and never claims the number. `note` carries what the line says. |

Which tools the app knows how to name, and in what order, is one table in
`main.swift` (`toolNames`). A key not in it is ignored; a tool in it whose key
the collector does not emit draws nothing.

**Collector environment** — `CLAUDE_METER_CONFIG_DIRS` (colon-separated config
dirs, each optionally `label=path`, replacing discovery), `CLAUDE_CONFIG_DIR`
(Claude Code's own, added to the defaults), `CLAUDE_METER_CACHE_DIR`,
`USAGE_API_TTL`, `CODEX_HOME` (Codex's own), `CODEX_USAGE_TTL`,
`CLAUDE_METER_CODEX` (`0` to drop the Codex section),
`CLAUDE_METER_CODEX_MODELS` (`0` to drop just its model rows), `GEMINI_HOME`
(where `agy` keeps its state) and `CLAUDE_METER_AGY` (`0` to drop its line).

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

### Other agentic CLIs

Claude Code is not the only thing on a developer's Mac with a quota. The meter
shows any other agentic CLI that is **installed** and can report its usage
**locally** — read from what is already on the machine, or asked of the tool's
own local server. Nothing here signs anything in, and nothing makes a model
request to find out how much of a model you have used.

Presence decides everything. A tool the meter cannot find contributes no key to
the collector's output, so the menu on a Mac without it is identical, item for
item, to the menu before that tool was ever supported.

#### Codex — supported

[Codex CLI](https://developers.openai.com/codex/cli) will not tell you its quota
from a file, but it will answer for it — the meter asks Codex's own local server
the question Codex's own UI asks.

- **Detected by** a `codex` executable — `PATH` first, then `~/.local/bin`,
  `/run/current-system/sw/bin`, `/etc/profiles/per-user/$USER/bin`,
  `~/.nix-profile/bin`, `/opt/homebrew/bin`, `/usr/local/bin` — **and**
  `$CODEX_HOME` (default `~/.codex`) existing. PATH alone was not enough: a
  launchd-spawned shell inherits a sparse one, so an installed codex was
  invisible to the resident meter while being plainly on the developer's own
  `$PATH`.
- **Read from** `codex app-server`, the stdio JSON-RPC server Codex ships for
  its own desktop app. One spawn answers two methods: `account/read` (the
  account's email and plan, out of `$CODEX_HOME` alone, no network) and
  `account/rateLimits/read` (the usage read, with `excludeResetCreditDetails`,
  which the method's own schema describes as the shape for background usage
  polls). Neither is a model request, so neither spends any quota. The server is
  spawned per read, and the whole process *group* is killed in a `finally` —
  the group rather than the child because a `codex` that is a wrapper script
  launches the real server as a grandchild, and killing the wrapper alone was
  measured leaving that grandchild running. It leaves no process and writes no
  file.
- **The credential stays Codex's.** `$CODEX_HOME/auth.json` holds the account's
  OAuth tokens and the meter never opens it — it is checked for *existence*, to
  tell "signed out" from "not installed", and nothing more. The tokens are used
  by the app-server, in its own process, exactly as Codex already uses them.
  Calling `chatgpt.com/backend-api/codex/usage` with a token read out of that
  file would have been a shorter path and the wrong one.
- **Shown as** one row per usage window Codex reports — **every** window, in
  every metered bucket. The response carries the same windows twice: its own
  schema calls `rateLimits` the "backward-compatible single-bucket view" and
  `rateLimitsByLimitId` the "multi-bucket view keyed by metered `limit_id`", so
  the multi-bucket view wins when it has anything in it and each bucket
  contributes its `primary` and its `secondary`. A bucket's name prefixes its
  rows only when there is more than one bucket. Each row carries the percentage
  used, the time to reset, and a label derived from the window's own length —
  `5h`, `Weekly`, `30-day`, or the exact duration when it is none of those. The
  names are not hardcoded, because they are not stable: this account's free
  plan reports a single 43200-minute window where a paid plan reports a rolling
  5-hour one with a weekly one beside it.
- **The model** in use and the models the account can pick, from `model/list`
  in the same spawn. Which model is in use is `config.toml`'s top-level `model`
  key when it sets one, and the catalog entry the server marks `isDefault` when
  it does not. Hidden models are left out — Codex hides them from its own
  picker, so listing them would offer something the tool will not.
- **Credits, and any ceiling the backend states outright** — `Credits:
  unlimited`, `Credits: 1,250`, `Rate limit reached`, `Spend control reached` —
  as plain sentences under the bars, and only when they say something. "Credits:
  none" under every window of a plan that has no credits is a row that never
  changes and never helps.
- **Severity** comes from the same percentage thresholds the Claude limits use
  (75% warning, 90% critical), because Codex sends none — except for the two
  states its backend states outright, `rateLimitReachedType` and
  `spendControlReached`, which are taken as critical whatever the percentage
  says.
- **Cached** in `~/.cache/claude-meter/codex-usage.json` (0600; it holds the
  account email), refreshed at most once per TTL — 120 s while a `codex` process
  is alive, 900 s when idle — with a 180 s backoff after a failure. The cache
  carries a **version**, and an older one is not a cache: an upgraded collector
  refetches once rather than serving a reading with its new rows missing for up
  to a TTL. `CODEX_HOME` and `CODEX_USAGE_TTL` are honoured;
  `CLAUDE_METER_CODEX=0` turns the section off entirely and
  `CLAUDE_METER_CODEX_MODELS=0` drops just the model rows.
- **Not shown, deliberately:** `account/usage/read` exists and answers, with
  lifetime and per-day **token** totals. Token counts with no ceiling to divide
  by are exactly what the Claude side of this meter replaced with percentages,
  and showing them under another tool's name would put the one thing this meter
  refuses to show back on the screen.
- **`config/read` is never called**, and that is a security decision rather
  than a taste one: it returns the whole effective config, `mcp_servers` and
  their headers included, and those headers can carry an API token. The one
  value needed is taken by parsing **only** the top-level keys of `config.toml`,
  stopping dead at the first `[table]` header, so the parse cannot reach a
  credential even in principle.

#### What the plans get — OpenAI's published limits

The menu shows measured numbers. This table is documentation, read from
OpenAI's own pages on **2026-09-21**, for deciding whether a plan change is
worth it. **Read it for its shape, not its precision:** OpenAI publishes these
as ranges and estimates rather than as hard numbers, and says so.

| Plan | Short window | Weekly window | Other |
|---|---|---|---|
| Free | Not published as a number — "explore Codex capabilities on quick coding tasks" [2] | Not published | No Free row exists in OpenAI's own comparison table. No image generation in Codex. |
| Go | Not published as a number [2] | Not published | "Lightweight coding tasks." |
| Plus | Published as a **range per model, per 5-hour period** — e.g. GPT-5.6 Terra 25–200 local messages, Luna 250–2,000, Sol 10–100. Explicitly "estimates", "not fixed message limits" [2] | "Weekly limits may also apply" — stated, never numbered [2] | Cloud chats may consume more of the allowance than local messages. |
| Pro (5×) | The same rows at 5× Plus — Terra 125–1,000 per 5 h [2][3] | Same wording, no number | "5x or 20x higher Codex usage than Plus" [3]. |
| Pro (20×) | The same rows at 20× Plus — Terra 500–4,000 per 5 h [2][3] | Same wording, no number | **New sign-ups and upgrades to the 20× tier were paused as of 2026-09-10**; existing subscriptions renew [3]. |
| Business | Pro-5× column [2] | No number | One allowance pooled across Codex, ChatGPT Work, Excel, PowerPoint, Word and Workspace Agents; a credits rate card takes over once included limits are spent [4]. |
| Enterprise / Edu | "Same per-seat usage limits as Plus for most features" [2] | As Plus | On flexible/credit pricing there are **no fixed rate limits** — usage scales with credits [2][4]. |

**What upgrading actually changes.** Free is not in OpenAI's comparison table at
all — it is not published as a smaller multiple of Plus, it is simply absent, so
there is no documented number to compare a free account against. From Plus
upward the change is a multiplier on the same 5-hour estimate table, not a new
kind of window: Pro is the Plus rows at 5× or 20× [2][3]. Model access is the
same roster across Plus and Pro.

**Credits.** Plus and Pro users who hit a limit can buy additional credits
rather than upgrading; Business/Edu/Enterprise workspaces buy workspace credits.
A typical Codex task on GPT-5.6 Sol is quoted at 5–30 credits [4]. The
`hasCredits` / `unlimited` / `balance` fields this meter reads are the CLI's own
API shape and are not documented as product terms anywhere on OpenAI's pages.

**The 30-day window is undocumented.** This account reports
`windowDurationMins: 43200` on the free plan, and no OpenAI page names,
explains or attributes that window. The meter shows it because the server sends
it; what it means is not something OpenAI has published.

**These numbers move.** All three help-centre articles carried "updated N days
ago" stamps two to four days before they were read, and the pricing page itself
notes GPT-5.5 retiring on 2026-10-14 and promotional GPT-5.6 Sol pricing
running to 2026-11-21. Re-read before relying on any figure here.

1. help.openai.com/en/articles/11369540, "Using Codex with your ChatGPT plan" — read 2026-09-21, page stamped ≈2026-09-17.
2. developers.openai.com/codex/pricing — read 2026-09-21, no visible stamp, content current to Nov 2026.
3. help.openai.com/en/articles/9793128, "About ChatGPT Pro tiers" — read 2026-09-21, stamped ≈2026-09-19.
4. help.openai.com/en/articles/20001106, "ChatGPT Rate Card" — read 2026-09-21, stamped ≈2026-09-18.

Nothing about Codex reaches the menu-bar glyph or the number beside it. Those
are Claude Code's three limits, and a fourth or fifth bar would break the one
thing the glyph says.

#### Antigravity (`agy`) — installed but unreadable

Google's [Antigravity CLI](https://antigravity.google/docs/cli) has quota — the
TUI's `/usage`, `/quota` and `/credits` panels show it — and **nothing outside
the process can read it**. An installed `agy` therefore gets one dim line after
the last section, saying exactly that, and no bar in the menu bar: a section
that could only ever say "no data" is a permanent empty chair, where the fact
worth carrying is that the meter knows `agy` is there and knows why it has
nothing.

Probed twice against agy 1.2.7 on macOS — signed **out** on 2026-09-20 and
signed **in** on 2026-09-21, because the first result could have been an
artefact of having no account:

- **No subcommand reports it.** The whole 1.2.7 set is `agent`/`agents`,
  `changelog`, `help`, `install`, `mcp`, `mic-serve`, `models`,
  `plugin`/`plugins`, `remote-control`, `update`. The quota panels are slash
  commands *inside* a session, not commands you can run. `agy models` lists
  models and efforts with no plan or quota field.
- **Signed in, the refresh runs and logs no result.** `doRefreshQuota` fires
  four or five times a session and only ever logs `starting reload (force=true)`
  or `skipped (throttled)`. There is no completion line: a grep across both log
  files for `QuotaSummary`, `remaining_fraction` and `FetchQuotaStatus` matched
  **zero** times. The refresh calls `v1internal:loadCodeAssist` and the response
  is never written to disk in any form.
- **Nothing persists it.** `jetski_state.pbtxt` holds onboarding state and no
  quota key; `cache/`, `implicit/`, `brain/`, `knowledge/` and the conversation
  database hold nothing quota-shaped; no file under `~/.gemini` is named for
  quota, usage or credits. The quota types (`RetrieveUserQuotaSummary`,
  `FetchQuotaStatus`, `QuotaSummaryBucket`) are gRPC messages feeding the TUI.
- **Its statusline cannot carry it.** `agy` has a `/statusline` mechanism, but
  it is output-only: it runs a shell command and renders that command's stdout.
  Unlike Claude Code's, it pipes no JSON payload *in*, so there is no quota
  field for a script to pick up.
- **There is a local server, and it answers one thing.** A live `agy` listens on
  loopback, and the only endpoint that responds is `/healthz`, with a liveness
  object. There is no documented equivalent of Codex's
  `account/rateLimits/read`, and guessing at undocumented routes against a
  signed-in session is not something a menu-bar meter gets to do.

**What would unblock it:** a persisted snapshot, the way Claude Code writes
`cachedUsageUtilization` and Codex answers `account/rateLimits/read` — a local
file `agy` writes after a quota refresh, a completion line in its own log with
the number in it, a non-interactive subcommand that prints it, a documented
quota endpoint beside `/healthz`, or a statusline payload that includes it. Any
one of them, and the footnote flag comes off and `agy` becomes a section like
Codex's: the collector and the app already draw one from the same data.

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
- **2026-09-20, where Codex keeps its quota — and where it does not.** The five
  sqlite databases under `$CODEX_HOME` hold threads, logs, goals, memories and a
  queue, and no rate-limit table between them. `codex doctor` reports thirty-odd
  facts about the install and not one number about usage. There were no rollout
  files to read either — `codex doctor` counted "active rollouts 0 files" and
  "rollout DB rows 0", and `$CODEX_HOME/sessions` did not exist, because
  rollouts are written only while a session runs. (The binary's symbols put
  `rate_limits` beside the rollout types, so a rollout of a session that *has*
  run probably carries one; not measured, and it would be as old as the last
  session either way.) Grepping all of `$CODEX_HOME` for a rate-limit string
  returned one hit, in an unrelated plugin catalogue. `codex app-server` answered `account/rateLimits/read` in 0.79 s and
  `account/read` in 0.03 s, and left no process and no file behind.
- **2026-09-20, the window has no fixed name.** The account this was built
  against reports a single 43200-minute (30-day) primary window on a free plan,
  where a paid plan reports 300 minutes. A hardcoded `5h` / `weekly` pair would
  have been wrong for one of them, so the label is derived from
  `windowDurationMins`.
- **2026-09-20 and 2026-09-21, Antigravity has no local number, signed out or
  in.** The signed-out probe could have been an artefact of having no account,
  so it was run again with one. Signed in, `doRefreshQuota` runs and logs no
  result — a grep for `QuotaSummary`, `remaining_fraction` and
  `FetchQuotaStatus` across both log files matched zero times — nothing under
  `~/.gemini` persists a number, and the local HTTP server a live `agy` runs
  answers `/healthz` and nothing else. Recorded as a blocker rather than
  engineered around; see
  [Antigravity](#antigravity-agy--installed-but-unreadable).
- **2026-09-21, the window label column was too narrow, and only the running
  app said so.** The multi-bucket fixture's JSON was correct and the menu was
  not: labels like "Agents 30-day" were drawn straight through the gauge beside
  them, because the label column had been a constant 60 pt since it only ever
  held "Session" and "Week". It is now as wide as the section's own widest
  label, clamped between 60 and 120 pt, with truncation past that.
- **2026-09-21, an upgraded collector served its old cache.** The first run of
  the new collector showed correct numbers and no model rows, for up to a full
  TTL, with nothing on screen to say why — the cache predated the fields. The
  cache now carries a version and an older one is simply not a cache.
- **2026-09-21, Codex's three free methods.** `account/rateLimits/read` (0.79 s,
  the windows), `account/read` (0.03 s, no network, the plan and email) and
  `model/list` (the account's models and which is the catalog default) all
  answer without a model request. `account/usage/read` answers too, with token
  totals, and is deliberately not used.

### Provenance

This is used daily on the author's Macs, where it is installed by a Nix flake
rather than by `install.sh`. It needs none of that: the scripts here are the
whole thing, and they assume nothing about your setup beyond what
[Install](#install) lists.

## Licence

MIT — see [LICENSE](LICENSE).
