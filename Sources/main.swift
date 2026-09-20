// Claude Meter — one menu-bar item showing the Claude account's real rate-limit
// utilisation: the 5-hour session window, the weekly all-models window and the
// weekly premium-model ("scoped") window, each against its real ceiling.
//
// GLANCEABLE, NOT A WALL. The bar shows ONE number — the session % beside a
// three-bar glyph that encodes all three limits — because a menu-bar item is
// read in a saccade, not studied. The detail (per-limit bars, resets, history
// graph) lives in the dropdown, rebuilt fresh every time it opens.
//
// A STALE METER MUST LOOK STALE. The collector can fail (network down, the
// usage endpoint rate-limiting) and the OS can sleep for days, so the app
// tracks when data was last collected AND how old the data itself is (age_s),
// badges the glyph when either goes bad, and prints exact ages in the dropdown.
// A silent fallback to an old cache is indistinguishable from freshness, which
// is the one lie a meter must not tell.
//
// CONTRAST. Menu-bar text uses the ADAPTIVE label colours, which macOS keeps
// legible on a light, dark or desktop-tinted bar. Saturated colour is confined
// to the filled gauges, which carry their own contrast, and is never the only
// thing making a number readable; a number goes warning-coloured only when a
// limit is actually hot.
//
// ONE METER, EVERY AGENT. Claude Code owns the menu-bar glyph and the number
// -- that is what this app is -- and any OTHER agentic CLI installed on this
// Mac gets its own section in the dropdown, with the same gauges and the same
// colours. A tool that is not installed contributes NOTHING: no section, no
// empty row, no error. The collector simply does not name it, and this file
// draws what it is given.
//
// IT COLLECTS NO DATA ITSELF. bin/claude-meter-stats emits the JSON.

import AppKit

// MARK: - CLI mode — run a command under this app's identity
//
// `ClaudeMeter --run <program> [args…]` runs the program as a CHILD of this
// binary and waits for it. The point is macOS's per-app privacy model: TCC
// grants (Full Disk Access, Files and Folders, Automation) are keyed to the
// RESPONSIBLE process, and a launchd job's responsible process is its own
// executable — so a bare /bin/bash spawned by launchd gets "Operation not
// permitted" on paths a user-launched app reads fine, and it cannot be granted
// anything durable because the grant would follow /bin/bash itself. A child of
// this app inherits this bundle's identity and therefore this bundle's grants.
// Spawn-and-wait, NEVER exec: exec would swap this image for the program and
// the identity with it.
//
// FIRST THING IN THE FILE, before any global that touches AppKit:
// `NSStatusBar.system` registers the process with LaunchServices as a running
// copy of this app, and the UI's single-instance sweep then terminated a
// `--run` parent mid-job (measured 2026-09-06). A CLI run must never look like
// a second meter.
var cliChild: Process?
func runUnderThisIdentity(_ argv: [String]) -> Never {
    guard let program = argv.first, !program.isEmpty else {
        FileHandle.standardError.write(Data("usage: ClaudeMeter --run <program> [args…]\n".utf8))
        exit(64)
    }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: program)
    child.arguments = Array(argv.dropFirst())
    child.standardInput = FileHandle.standardInput
    child.standardOutput = FileHandle.standardOutput
    child.standardError = FileHandle.standardError
    cliChild = child
    // launchd stops a job with SIGTERM; pass it on so the child's own exit trap
    // runs instead of leaving its locks and temporary state behind.
    signal(SIGTERM) { _ in cliChild?.terminate() }
    signal(SIGINT) { _ in cliChild?.interrupt() }
    do { try child.run() } catch {
        FileHandle.standardError.write(Data("ClaudeMeter: cannot run \(program): \(error)\n".utf8))
        exit(126)
    }
    child.waitUntilExit()
    exit(child.terminationStatus)
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "--run" { runUnderThisIdentity(Array(cliArgs.dropFirst())) }


// MARK: - Paths

// The collector's cache directory, the only place outside the collector this
// app reads. It does NOT follow CLAUDE_METER_CACHE_DIR, which the collector
// does: point that elsewhere and the dropdown's history graph goes empty.
let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/claude-meter")

// MARK: - Model

struct Limit { var pct = 0; var resetIn = 0; var severity = "normal" }

struct Stats {
    var ok = false
    var account = ""
    var email = ""
    var source = ""          // "api" (live endpoint) or "session-cache"
    var ageS = -1            // seconds since the shown numbers left the API
    var fetchErr = ""        // why the live path is down ("rate-limited", ...)
    var retryIn = 0          // seconds until the collector tries the API again
    var session = Limit(), weekly = Limit(), scoped = Limit()
    // What the scoped weekly cap applies to. The usage endpoint names it
    // (limits[].scope.model.display_name), so nothing here hardcodes a model
    // family that a release would falsify; "Model" is the placeholder for a
    // response, or an older collector, that names nothing.
    var scopedLabel = "Model"
}

// One dropdown section for an agentic CLI that is NOT Claude Code. Its limits
// arrive as a LIST rather than as three named fields, because how many usage
// windows a tool has, and what each one means, is the tool's business: codex
// reports one 30-day window on a free plan where a paid plan reports a 5-hour
// one, so a fixed set of names here would be wrong for somebody.
struct ToolReading {
    var name = ""            // "Codex" — this app's word for the tool
    var ok = false
    var headline = ""        // account line beside the name, e.g. "you@example.com · free"
    var source = ""
    var ageS = -1
    var fetchErr = ""
    var retryIn = 0
    var note = ""            // why there is nothing to show, in words
    var limits: [(String, Limit)] = []
}

// Everything one collector run produced.
struct Snapshot {
    var claude = Stats()
    var tools: [ToolReading] = []
}

// MARK: - Formatting

// Time left until a limit resets, e.g. "45m" / "3h07" / "2d4h".
func formatCountdown(_ seconds: Int) -> String {
    if seconds <= 0 { return "—" }
    if seconds < 3600 { return "\(max(1, seconds / 60))m" }
    if seconds < 86400 {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return "\(h)h\(String(format: "%02d", m))"
    }
    let d = seconds / 86400, h = (seconds % 86400) / 3600
    return h > 0 ? "\(d)d\(h)h" : "\(d)d"
}

// Relative age for the dropdown, e.g. "8s ago" / "3m ago" / "2.4h ago".
func formatAge(_ seconds: Int) -> String {
    if seconds < 0 { return "never" }
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86400 { return String(format: "%.1fh ago", Double(seconds) / 3600) }
    return "\(seconds / 86400)d ago"
}

// MARK: - Colour

// Everything DRAWN in the bar (the bars glyph, the badge — and the dropdown
// gauges and graph, which share the same series colours) uses MUTED variants of
// the system colours: full-saturation system colours shout next to the bar's
// monochrome template icons, and a meter is furniture, not an alert box.
// Blending ~a third of the chroma toward mid-grey keeps every hue nameable in a
// light or dark bar without the neon look; severity red/orange pass through the
// same blend because the MARK (the badge dot, the exclaimed number) carries the
// alarm — colour only names it. Menu TEXT keeps stock system colours: those
// rows are standard UI where the system palette is the convention.
func muted(_ c: NSColor) -> NSColor {
    c.blended(withFraction: 0.38, of: NSColor(calibratedWhite: 0.58, alpha: 1)) ?? c
}

// Per-limit ACCENT colour, Little Snitch style: the colour identifies which
// series a bar belongs to, so three meters at similar low percentages are still
// told apart at a glance (all-green bars were indistinguishable). Severity still
// wins when a limit is actually hot — danger must never be traded for prettiness.
let seriesColors: [NSColor] = [muted(.systemBlue), muted(.systemPurple), muted(.systemTeal)]

// One rule shared by every renderer, so the glyph, the number and the dropdown
// can never disagree about "hot".
enum AlertLevel: Int, Comparable {
    case normal, warning, critical
    static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }
}

func alertLevel(_ l: Limit) -> AlertLevel {
    if l.severity == "critical" || l.pct >= 90 { return .critical }
    if l.severity == "warning"  || l.pct >= 75 { return .warning }
    return .normal
}

func gaugeColor(_ l: Limit, _ series: Int = 0) -> NSColor {
    switch alertLevel(l) {
    case .critical: return muted(.systemRed)
    case .warning: return muted(.systemOrange)
    case .normal: return seriesColors[series % seriesColors.count]
    }
}

// MARK: - Usage history (for the graph in the dropdown)

struct HistoryPoint { var time: Double; var session: Double; var weekly: Double; var scoped: Double }

// How many of the most recent points the graph draws.
let historyPointsShown = 400

func loadHistory() -> [HistoryPoint] {
    let file = cacheDir.appendingPathComponent("usage-history.csv")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    var points: [HistoryPoint] = []
    for line in text.split(separator: "\n") {
        // time, identity label (not graphed), session %, weekly %, scoped %.
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count == 5, let time = Double(f[0]) else { continue }
        points.append(HistoryPoint(time: time, session: Double(f[2]) ?? 0,
                                   weekly: Double(f[3]) ?? 0, scoped: Double(f[4]) ?? 0))
    }
    return points.suffix(historyPointsShown)
}

// MARK: - Gauge drawing

// Match the real menu-bar height so drawn images fill it instead of being
// scaled down (a notched MacBook is ~24pt, a classic bar ~22). Floor at 18 for
// safety if the status bar reports something tiny.
let menuBarHeight: CGFloat = max(18, NSStatusBar.system.thickness)

// A rounded track with the limit's fill over it — the one shape the glyph and
// the dropdown both draw, so the two views cannot drift apart.
//
// A nonzero fill is floored at one cap-width: a strict proportional fill makes
// 1-9% invisible at these sizes, and the precise number is printed beside the
// gauge anyway.
func drawGauge(_ rect: NSRect, pct: Int, color: NSColor) {
    let trackRadius = rect.height / 2
    NSColor.quaternaryLabelColor.setFill()
    NSBezierPath(roundedRect: rect, xRadius: trackRadius, yRadius: trackRadius).fill()

    var fillWidth = CGFloat(min(100, pct)) / 100 * rect.width
    if pct > 0 { fillWidth = max(fillWidth, rect.height) }
    guard fillWidth > 0 else { return }
    let fillRadius = min(trackRadius, fillWidth / 2)
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height),
                 xRadius: fillRadius, yRadius: fillRadius).fill()
}

// The menu-bar glyph: three stacked mini-bars, one per limit, colour-coded like
// the dropdown so the two views share one visual language. `badge` paints a
// small dot floating at the top-right — the meter's OWN health indicator
// (yellow = data old, red = collector failing), deliberately separate from the
// limit colours inside the bars so "the meter is sick" never masquerades as
// "a limit is hot".
func barsGlyph(_ limits: [Limit], badge: NSColor? = nil) -> NSImage {
    let width: CGFloat = 16, barHeight: CGFloat = 2.6, gap: CGFloat = 2.2
    let stackHeight = barHeight * 3 + gap * 2
    let image = NSImage(size: NSSize(width: width, height: menuBarHeight))
    image.lockFocus()
    NSGraphicsContext.current?.shouldAntialias = true
    let bottom = (menuBarHeight - stackHeight) / 2
    for (i, limit) in limits.enumerated() {
        let y = bottom + CGFloat(limits.count - 1 - i) * (barHeight + gap)   // first limit on top
        drawGauge(NSRect(x: 0, y: y, width: width, height: barHeight),
                  pct: limit.pct, color: gaugeColor(limit, i))
    }
    if let badge {
        let size: CGFloat = 4.5
        badge.setFill()
        NSBezierPath(ovalIn: NSRect(x: width - size, y: min(menuBarHeight - size, bottom + stackHeight + 0.5),
                                    width: size, height: size)).fill()
    }
    image.unlockFocus()
    image.isTemplate = false
    return image
}

// MARK: - Dropdown view

// The click-through view: full-size colourful progress bars for the three
// limits, and underneath a multi-series graph of how they have moved over time.
// Drawn as a real NSView rather than menu text so it can use colour and shape —
// the text rows could show the numbers but never the shape of the usage.
final class UsageView: NSView {
    var limits: [(String, Limit)] = []
    var history: [HistoryPoint] = []
    // A section with no recorded history draws ROWS ONLY. Drawing the graph
    // anyway would put "collecting usage history…" under every tool that has
    // none forever, which reads as a promise the meter is not keeping.
    var drawsHistory = true

    private static let rowHeight: CGFloat = 30
    private static let graphHeight: CGFloat = 60
    private let pad: CGFloat = 14
    private let labelColumn: CGFloat = 60
    private let graphHeight: CGFloat = UsageView.graphHeight

    // The exact height this view needs, so a section is sized from its own
    // content instead of from a constant that has to be re-guessed every time a
    // tool with a different number of limits is added.
    static func height(rows: Int, history: Bool) -> CGFloat {
        let rowsHeight = 10 + CGFloat(rows) * rowHeight
        return history ? rowsHeight + 8 + graphHeight + 8 : rowsHeight + 8
    }

    override func draw(_ dirty: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        let belowRows = drawLimitRows(top: bounds.height - 10)
        guard drawsHistory else { return }
        let graphY = belowRows - 8 - graphHeight
        guard graphY > 4 else { return }
        drawHistory(in: NSRect(x: pad + labelColumn, y: graphY,
                               width: bounds.width - pad * 2 - labelColumn, height: graphHeight))
    }

    // One row per limit: name, gauge, percentage, time to reset. Sized to be
    // read instantly — a 12pt track with a full-height rounded fill and 13pt
    // percentages. The first cut used 7pt bars, whose fill at 20-30% was a
    // barely-visible stub. Returns the y the rows end at.
    private func drawLimitRows(top: CGFloat) -> CGFloat {
        let rowHeight = UsageView.rowHeight, barHeight: CGFloat = 12
        let percentColumn: CGFloat = 104
        let gaugeWidth = bounds.width - pad * 2 - labelColumn - percentColumn
        var y = top
        for (i, item) in limits.enumerated() {
            let (name, limit) = item
            y -= rowHeight
            let middle = y + rowHeight / 2
            drawText(name, .secondaryLabelColor, x: pad, centredOn: middle, size: 12, weight: .medium)
            drawGauge(NSRect(x: pad + labelColumn, y: middle - barHeight / 2,
                             width: gaugeWidth, height: barHeight),
                      pct: limit.pct, color: gaugeColor(limit, i))
            drawText("\(limit.pct)%", alertLevel(limit) != .normal ? gaugeColor(limit, i) : .labelColor,
                     x: pad + labelColumn + gaugeWidth + 44, centredOn: middle,
                     size: 13, weight: .semibold, rightAligned: true)
            drawText(formatCountdown(limit.resetIn), .secondaryLabelColor,
                     x: bounds.width - pad, centredOn: middle, rightAligned: true)
        }
        return y
    }

    private func drawHistory(in frame: NSRect) {
        // AUTO-SCALE the y axis. These limits sit in single digits most of the
        // time, and on a fixed 0-100 axis every series flatlines along the
        // bottom — technically honest, visually useless. Scale to the peak
        // instead and LABEL the top tick, so the axis still says exactly what it
        // means. Floor of 20 keeps a near-zero graph from magnifying noise.
        let peak = history.reduce(0.0) { max($0, max($1.session, max($1.weekly, $1.scoped))) }
        let yMax = min(100.0, max(20.0, (peak * 1.35 / 10).rounded(.up) * 10))

        NSColor.quaternaryLabelColor.setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let gridline = NSBezierPath()
            gridline.move(to: NSPoint(x: frame.minX, y: frame.minY + CGFloat(fraction) * frame.height))
            gridline.line(to: NSPoint(x: frame.maxX, y: frame.minY + CGFloat(fraction) * frame.height))
            gridline.lineWidth = 0.5
            gridline.stroke()
        }
        func tick(_ text: String, _ y: CGFloat) {
            drawCaption(text) { size in NSPoint(x: frame.minX - 6 - size.width, y: y - 5) }
        }
        tick("\(Int(yMax))%", frame.maxY); tick("0", frame.minY)

        guard history.count >= 2 else {
            NSAttributedString(string: "collecting usage history…", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor,
            ]).draw(at: NSPoint(x: frame.minX + 6, y: frame.midY - 6))
            return
        }
        // Time is the x axis. Points are irregular (only written when a value
        // changes or 10 min pass), so plot against real elapsed time, not index —
        // otherwise a long flat stretch looks like a fast climb.
        let start = history.first!.time, end = max(history.last!.time, start + 1)
        func line(_ pick: (HistoryPoint) -> Double, _ color: NSColor) {
            let path = NSBezierPath()
            for (i, point) in history.enumerated() {
                let x = frame.minX + CGFloat((point.time - start) / (end - start)) * frame.width
                let y = frame.minY + CGFloat(min(yMax, max(0, pick(point))) / yMax) * frame.height
                i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            }
            path.lineWidth = 1.6; path.lineJoinStyle = .round; path.lineCapStyle = .round
            color.setStroke(); path.stroke()
        }
        line({ $0.session }, seriesColors[0])
        line({ $0.weekly }, seriesColors[1])
        line({ $0.scoped }, seriesColors[2])

        // Span label, INSIDE the plot's top-right — drawn below the frame it was
        // clipped by the view's own bottom edge.
        let span = Int(end - start)
        let spanText = span < 3600 ? "\(max(1, span / 60))m"
            : (span < 86400 ? "\(span / 3600)h" : "\(span / 86400)d")
        drawCaption("last \(spanText)") { size in
            NSPoint(x: frame.maxX - size.width - 2, y: frame.maxY - 10)
        }
    }

    // A row label or number: left-aligned at x, or right-aligned to it,
    // vertically centred on its row.
    private func drawText(_ s: String, _ color: NSColor, x: CGFloat, centredOn y: CGFloat,
                          size: CGFloat = 11, weight: NSFont.Weight = .regular,
                          rightAligned: Bool = false) {
        let text = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
        text.draw(at: NSPoint(x: rightAligned ? x - text.size().width : x,
                              y: y - text.size().height / 2))
    }

    // The graph's small grey captions: the axis ticks and the span label, each
    // placed from its own measured size.
    private func drawCaption(_ s: String, at place: (NSSize) -> NSPoint) {
        let text = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        text.draw(at: place(text.size()))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var stats = Stats()
    // Sections for the other agentic CLIs, in the collector's order. Empty on
    // a Mac that has none, which is what makes the menu identical to what it
    // was before any of them were supported.
    private var tools: [ToolReading] = []
    private var haveStats = false
    private var collectorPath = ""
    private var lastError: String?
    private var lastGoodCollection: Date?   // when the collector last returned parseable JSON
    private var failStreak = 0
    private var collecting = false

    // Where the collector may live, in order. The environment wins so a checkout
    // can be tested without installing, then the two usual bin directories.
    private static var collectorCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let fromEnv = ProcessInfo.processInfo.environment["CLAUDE_METER_STATS"], !fromEnv.isEmpty {
            candidates.append(fromEnv)
        }
        candidates.append("\(home)/.local/bin/claude-meter-stats")
        candidates.append("/usr/local/bin/claude-meter-stats")
        candidates.append("/opt/homebrew/bin/claude-meter-stats")
        return candidates
    }

    // The meter's own health, distinct from the data's age. Three missed
    // 30s ticks means the collector itself is failing or wedged.
    private var collectorSick: Bool {
        if failStreak >= 3 { return true }
        guard let last = lastGoodCollection else { return false }
        return Date().timeIntervalSince(last) > 150
    }
    // Age of the DATA as of now: age at collection time plus time since then.
    private var dataAge: Int {
        guard haveStats, stats.ageS >= 0 else { return -1 }
        let sinceCollection = lastGoodCollection.map { Int(Date().timeIntervalSince($0)) } ?? 0
        return stats.ageS + max(0, sinceCollection)
    }
    // 45 min covers the collector's worst normal cadence (900s idle TTL plus a
    // failed attempt's backoff); older than that means refresh is broken.
    private var dataStale: Bool { dataAge >= 45 * 60 }

    func applicationDidFinishLaunching(_: Notification) {
        // SINGLE INSTANCE. A launchd agent owns this app, so any second copy —
        // an `open`, a double-click, a stale one left behind — puts a SECOND
        // status item in the menu bar and everything appears twice. Each
        // instance draws its own item, so this is not a rendering bug and
        // cannot be fixed by drawing; the duplicate process has to go.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.ayushsharma.claude-meter")
            .filter { $0.processIdentifier != me }
        for other in others { other.terminate() }

        collectorPath = Self.collectorCandidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? ""

        statusMenu.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = statusMenu
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.attributedTitle = barText("…", .secondaryLabelColor)
        }
        refresh()

        // .common mode, or the timer freezes exactly when someone is LOOKING at
        // the meter: menu tracking runs the run loop in event-tracking mode,
        // where a default-mode timer never fires.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)

        // Refresh immediately at wake instead of painting pre-sleep numbers
        // for up to a full tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    // MARK: Collect

    private func refresh() {
        guard !collectorPath.isEmpty else {
            lastError = "claude-meter-stats not found"
            failStreak += 1
            render()
            return
        }
        // One collection at a time: a wedged run must not pile new processes on
        // top of itself every tick. Liveness is preserved by the watchdog in
        // runCollector plus collectorSick surfacing the gap in the UI.
        guard !collecting else { return }
        collecting = true
        let script = collectorPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (parsed, error) = Self.runCollector(script)
            DispatchQueue.main.async {
                guard let self else { return }
                self.collecting = false
                if let parsed {
                    self.stats = parsed.claude; self.tools = parsed.tools; self.haveStats = true
                    self.lastError = nil; self.lastGoodCollection = Date(); self.failStreak = 0
                } else {
                    self.lastError = error; self.failStreak += 1
                }
                self.render()
            }
        }
    }

    // Runs the collector to completion and parses what it printed. Blocking:
    // callers are on a background queue.
    private static func runCollector(_ script: String) -> (Snapshot?, String?) {
        let collector = Process()
        collector.executableURL = URL(fileURLWithPath: "/bin/bash")
        collector.arguments = [script]
        let pipe = Pipe()
        collector.standardOutput = pipe
        collector.standardError = FileHandle.nullDevice
        do {
            try collector.run()
        } catch {
            return (nil, "collector failed to start")
        }
        // Watchdog. The collector's slow paths are its own: the Claude usage
        // endpoint (curl 15s), and, when codex is installed, one bounded
        // app-server read (10s) after it. 25s covered the first alone and would
        // now kill a merely-slow run that did both, reporting a timeout for
        // something that was working; 40s clears the realistic sum and still
        // sits well under the 150s with no good collection that marks the meter
        // sick. It is not a bound on the theoretical worst case -- adding up
        // every timeout the collector can impose exceeds it, as it exceeded 25s
        // before codex was ever read -- because those are the wedged cases this
        // exists to turn into a visible error state rather than a silent freeze.
        // The read below still returns because every child holding the pipe is
        // itself time-bounded.
        let killer = DispatchWorkItem { if collector.isRunning { collector.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: killer)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        collector.waitUntilExit()
        killer.cancel()
        guard let parsed = parse(output) else {
            return (nil, output.isEmpty ? "collector timed out" : "collector output unparseable")
        }
        return (parsed, nil)
    }

    // The tools this app knows how to name, in menu order. A key the collector
    // does not emit produces no section at all — presence gating lives in the
    // collector, and this table only decides the human-readable name and the
    // order. Adding a tool the collector learns to report is one row here.
    private static let toolNames: [(key: String, name: String)] = [("codex", "Codex")]

    private static func parse(_ data: Data) -> Snapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var snapshot = Snapshot()
        snapshot.tools = toolNames.compactMap { parseTool(root[$0.key], name: $0.name) }
        var s = Stats()
        if let c = root["claude"] as? [String: Any] {
            s.ok = c["ok"] as? Bool ?? false
            s.account = c["account"] as? String ?? ""
            s.email = c["email"] as? String ?? ""
            s.source = c["source"] as? String ?? ""
            s.ageS = c["age_s"] as? Int ?? Int(((c["stale_hours"] as? Double) ?? -1) * 3600)
            s.fetchErr = c["fetch_err"] as? String ?? ""
            s.retryIn = c["retry_in"] as? Int ?? 0
            if let label = c["scoped_label"] as? String, !label.isEmpty { s.scopedLabel = label }
            func limit(_ key: String) -> Limit {
                guard let d = c[key] as? [String: Any] else { return Limit() }
                return Limit(pct: d["pct"] as? Int ?? 0, resetIn: d["reset_in"] as? Int ?? 0,
                             severity: d["severity"] as? String ?? "normal")
            }
            s.session = limit("session"); s.weekly = limit("weekly"); s.scoped = limit("scoped")
        }
        snapshot.claude = s
        return snapshot
    }

    private static func parseTool(_ raw: Any?, name: String) -> ToolReading? {
        guard let t = raw as? [String: Any] else { return nil }
        var tool = ToolReading()
        tool.name = name
        tool.ok = t["ok"] as? Bool ?? false
        tool.source = t["source"] as? String ?? ""
        tool.ageS = t["age_s"] as? Int ?? -1
        tool.fetchErr = t["fetch_err"] as? String ?? ""
        tool.retryIn = t["retry_in"] as? Int ?? 0
        tool.note = t["note"] as? String ?? ""
        let account = [t["email"] as? String ?? "", t["plan"] as? String ?? ""]
            .filter { !$0.isEmpty }
        tool.headline = account.joined(separator: " · ")
        for entry in (t["limits"] as? [[String: Any]] ?? []) {
            tool.limits.append((entry["label"] as? String ?? "Limit",
                                Limit(pct: entry["pct"] as? Int ?? 0,
                                      resetIn: entry["reset_in"] as? Int ?? 0,
                                      severity: entry["severity"] as? String ?? "normal")))
        }
        // A section claiming ok with no window is the same lie as a reading with
        // no age: show the note instead of an empty gauge block.
        if tool.limits.isEmpty { tool.ok = false }
        return tool
    }

    // MARK: Bar rendering

    private func barText(_ s: String, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: c,
        ])
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let badge = badgeColor()
        guard haveStats, stats.ok else {
            // Before the first collection lands there is nothing to be sick
            // about yet, but the dash still has to say it is not a reading.
            button.image = barsGlyph([Limit(), Limit(), Limit()],
                                     badge: badge ?? (haveStats ? nil : muted(.systemYellow)))
            button.attributedTitle = barText("—", .secondaryLabelColor)
            return
        }
        button.image = barsGlyph([stats.session, stats.weekly, stats.scoped], badge: badge)
        let (text, color) = statusTitle()
        button.attributedTitle = barText(text, color)
    }

    // The meter's own health, never a limit — see barsGlyph.
    private func badgeColor() -> NSColor? {
        if collectorSick { return muted(.systemRed) }
        return dataStale ? muted(.systemYellow) : nil
    }

    // The number beside the glyph is the SESSION % — the value that moves while
    // working — unless another limit is hot, in which case the hot one takes
    // over with its label so the number stays self-describing ("wk 92%"). The
    // scoped limit brings the name the endpoint gave it, truncated because the
    // menu bar is not elastic and a model name is not bounded.
    private func statusTitle() -> (String, NSColor) {
        let named: [(String, Limit)] = [("5h", stats.session), ("wk", stats.weekly),
                                        (String(stats.scopedLabel.prefix(12)), stats.scoped)]
        let worst = named.enumerated().max {
            (alertLevel($0.element.1), $0.element.1.pct) < (alertLevel($1.element.1), $1.element.1.pct)
        }!
        guard alertLevel(worst.element.1) != .normal else {
            let dimmed = dataStale || collectorSick
            return ("\(stats.session.pct)%", dimmed ? .secondaryLabelColor : .labelColor)
        }
        let text = worst.offset == 0 ? "\(stats.session.pct)%"
                                     : "\(worst.element.0) \(worst.element.1.pct)%"
        return (text, gaugeColor(worst.element.1, worst.offset))
    }

    // MARK: Menu (rebuilt at open, so ages are computed when eyes are on them)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu { rebuildMenu(menu) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // An open is a moment the numbers are actually being read — collect in
        // the background so the NEXT look (and the bar, seconds later) is fresh.
        refresh()
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        addHeader(menu, stats.email.isEmpty ? "Claude usage"
                                            : "\(stats.email) · \(stats.account)")
        if haveStats, stats.ok {
            addFreshnessRows(menu)
            let usage = UsageView(frame: NSRect(x: 0, y: 0, width: 340,
                                                height: UsageView.height(rows: 3, history: true)))
            usage.limits = [("Session", stats.session), ("Week", stats.weekly),
                            (stats.scopedLabel, stats.scoped)]
            usage.history = loadHistory()
            let item = NSMenuItem(); item.view = usage; menu.addItem(item)
        } else if haveStats {
            addNote(menu, "No usage data yet — sign in to Claude Code once")
        } else {
            addNote(menu, lastError ?? "Collecting…")
        }
        addToolSections(menu)
        menu.addItem(.separator())
        addAction(menu, "Refresh Now", #selector(doRefresh), key: "r")
        menu.addItem(.separator())
        addAction(menu, "Quit Claude Meter", #selector(quit), key: "q")
    }

    // One section per other agentic CLI the collector reported on. Nothing is
    // drawn for a tool it did not name, so this loop runs zero times on a Mac
    // that has only Claude Code and the menu is unchanged.
    private func addToolSections(_ menu: NSMenu) {
        for tool in tools {
            menu.addItem(.separator())
            addHeader(menu, tool.headline.isEmpty ? "\(tool.name) usage"
                                                  : "\(tool.name) · \(tool.headline)")
            guard tool.ok else {
                addNote(menu, tool.note.isEmpty ? "No usage data yet" : tool.note)
                if !tool.fetchErr.isEmpty { addNote(menu, tool.fetchErr, color: .systemOrange) }
                continue
            }
            let age = toolDataAge(tool)
            let stale = age >= 45 * 60
            addNote(menu, "\(tool.source.isEmpty ? "Usage" : tool.source) · read \(formatAge(age))",
                    color: stale ? .systemOrange : .secondaryLabelColor)
            if !tool.fetchErr.isEmpty {
                let retry = tool.retryIn > 0 ? " · retry in \(max(1, tool.retryIn / 60))m" : ""
                addNote(menu, "Live read \(tool.fetchErr)\(retry)", color: .systemOrange)
            }
            // Rows only, no graph: no history is recorded for these tools, and
            // an empty plot under every one of them says nothing.
            let usage = UsageView(frame: NSRect(
                x: 0, y: 0, width: 340,
                height: UsageView.height(rows: tool.limits.count, history: false)))
            usage.limits = tool.limits
            usage.drawsHistory = false
            let item = NSMenuItem(); item.view = usage; menu.addItem(item)
        }
    }

    // Same rule as the Claude section: the age shown is the age at collection
    // plus the time since, so a number nobody has refreshed never reads current.
    private func toolDataAge(_ tool: ToolReading) -> Int {
        guard tool.ageS >= 0 else { return -1 }
        let sinceCollection = lastGoodCollection.map { Int(Date().timeIntervalSince($0)) } ?? 0
        return tool.ageS + max(0, sinceCollection)
    }

    private func addFreshnessRows(_ menu: NSMenu) {
        // Say where the numbers CAME FROM and how old they are — the age of the
        // data, not of the last poll, is what decides whether to trust them.
        if stats.source == "api" && !dataStale {
            addNote(menu, "Usage API · fetched \(formatAge(dataAge))")
        } else {
            let age = formatAge(dataAge).replacingOccurrences(of: " ago", with: "")
            addNote(menu, "Data \(age) old · from \(stats.source == "api" ? "usage API" : "claude's session cache")",
                    color: dataStale ? .systemOrange : .secondaryLabelColor)
        }
        // A down live path is stated with its reason and retry time — a silent
        // fallback is indistinguishable from freshness, which is the one lie a
        // meter must not tell. No "run claude" advice here: the live path does
        // not need claude, and the hint was wrong exactly when it showed.
        if !stats.fetchErr.isEmpty {
            let retry = stats.retryIn > 0 ? " · retry in \(max(1, stats.retryIn / 60))m" : ""
            addNote(menu, "Live fetch \(stats.fetchErr)\(retry)", color: .systemOrange)
        }
        if collectorSick {
            let lastSuccess = lastGoodCollection.map { formatAge(Int(Date().timeIntervalSince($0))) } ?? "never"
            addNote(menu, "Meter not refreshing — \(lastError ?? "collector silent") · last success \(lastSuccess)",
                    color: .systemRed)
        }
    }

    // Rows the app only prints. They carry their own attributed title because a
    // disabled item's plain title would be greyed out by AppKit.
    private func addTextRow(_ menu: NSMenu, _ text: String, font: NSFont, color: NSColor) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
        ])
        menu.addItem(item)
    }

    private func addHeader(_ menu: NSMenu, _ text: String) {
        addTextRow(menu, text, font: .systemFont(ofSize: 12.5, weight: .semibold), color: .labelColor)
    }

    private func addNote(_ menu: NSMenu, _ text: String, color: NSColor = .secondaryLabelColor) {
        addTextRow(menu, text, font: .systemFont(ofSize: 11.5), color: color)
    }

    // Text-only action rows, like the system's own status menus. (SF Symbol
    // images on these rows were tried and do not render in this status-menu
    // context; the custom-drawn glyph carries the iconography instead.)
    private func addAction(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func doRefresh() { refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
