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
// IT COLLECTS NO DATA ITSELF. bin/claude-meter-stats emits the JSON.

import AppKit

// MARK: CLI mode — run a command under this app's identity
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
    let p = Process()
    p.executableURL = URL(fileURLWithPath: program)
    p.arguments = Array(argv.dropFirst())
    p.standardInput = FileHandle.standardInput
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    cliChild = p
    // launchd stops a job with SIGTERM; pass it on so the child's own exit trap
    // runs instead of leaving its locks and temporary state behind.
    signal(SIGTERM) { _ in cliChild?.terminate() }
    signal(SIGINT) { _ in cliChild?.interrupt() }
    do { try p.run() } catch {
        FileHandle.standardError.write(Data("ClaudeMeter: cannot run \(program): \(error)\n".utf8))
        exit(126)
    }
    p.waitUntilExit()
    exit(p.terminationStatus)
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "--run" { runUnderThisIdentity(Array(cliArgs.dropFirst())) }


// MARK: - Paths

// Everything this app reads or writes outside the collector lives here. One
// directory, so uninstalling is a single `rm -rf`.
let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/claude-meter")

// MARK: - Model

struct Limit { var pct = 0; var reset = 0; var severity = "normal" }

struct Stats {
    var ok = false
    var account = ""
    var email = ""
    var source = ""          // "api" (live endpoint) or "session-cache"
    var ageS = -1            // seconds since the shown numbers left the API
    var fetchErr = ""        // why the live path is down ("rate-limited", ...)
    var retryIn = 0          // seconds until the collector tries the API again
    var session = Limit(), weekly = Limit(), scoped = Limit()
}

// MARK: - Formatting

func reset(_ s: Int) -> String {
    if s <= 0 { return "—" }
    if s < 3600 { return "\(max(1, s / 60))m" }
    if s < 86400 { let h = s / 3600, m = (s % 3600) / 60; return "\(h)h\(String(format: "%02d", m))" }
    let d = s / 86400, h = (s % 86400) / 3600
    return h > 0 ? "\(d)d\(h)h" : "\(d)d"
}

// Relative age for the dropdown, e.g. "8s ago" / "3m ago" / "2.4h ago".
func relAge(_ s: Int) -> String {
    if s < 0 { return "never" }
    if s < 5 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return String(format: "%.1fh ago", Double(s) / 3600) }
    return "\(s / 86400)d ago"
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

// 0 normal, 1 warning, 2 critical — one rule shared by every renderer so the
// glyph, the number and the dropdown can never disagree about "hot".
func alertLevel(_ l: Limit) -> Int {
    if l.severity == "critical" || l.pct >= 90 { return 2 }
    if l.severity == "warning"  || l.pct >= 75 { return 1 }
    return 0
}

func gaugeColor(_ l: Limit, _ series: Int = 0) -> NSColor {
    switch alertLevel(l) {
    case 2: return muted(.systemRed)
    case 1: return muted(.systemOrange)
    default: return seriesColors[series % seriesColors.count]
    }
}

// MARK: - Usage history (for the graph in the dropdown)

struct Point { var t: Double; var s: Double; var w: Double; var f: Double }

func loadHistory() -> [Point] {
    let p = cacheDir.appendingPathComponent("usage-history.csv")
    guard let txt = try? String(contentsOf: p, encoding: .utf8) else { return [] }
    var out: [Point] = []
    for line in txt.split(separator: "\n") {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count == 5, let t = Double(f[0]) else { continue }
        out.append(Point(t: t, s: Double(f[2]) ?? 0, w: Double(f[3]) ?? 0, f: Double(f[4]) ?? 0))
    }
    return out.suffix(400)
}

// MARK: - Bar drawing

// Match the real menu-bar height so drawn images fill it instead of being
// scaled down (a notched MacBook is ~24pt, a classic bar ~22). Floor at 18 for
// safety if the status bar reports something tiny.
let H: CGFloat = max(18, NSStatusBar.system.thickness)

// The glyph: three stacked mini-bars, one per limit, colour-coded like the
// dropdown so the two views share one visual language. `badge` paints a small
// dot floating at the top-right — the meter's OWN health indicator (yellow =
// data old, red = collector failing), deliberately separate from the limit
// colours inside the bars so "the meter is sick" never masquerades as "a limit
// is hot".
func barsGlyph(_ limits: [Limit], badge: NSColor? = nil) -> NSImage {
    let w: CGFloat = 16, bh: CGFloat = 2.6, gap: CGFloat = 2.2
    let stackH = bh * 3 + gap * 2
    let img = NSImage(size: NSSize(width: w, height: H))
    img.lockFocus()
    NSGraphicsContext.current?.shouldAntialias = true
    let y0 = (H - stackH) / 2
    for (i, l) in limits.enumerated() {
        let y = y0 + CGFloat(limits.count - 1 - i) * (bh + gap)   // first limit on top
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: w, height: bh),
                     xRadius: bh / 2, yRadius: bh / 2).fill()
        // At 16px a strict proportional fill makes 1-9% invisible, so floor a
        // nonzero fill at one cap-width. The precise number is beside the glyph.
        var fw = CGFloat(min(100, l.pct)) / 100 * w
        if l.pct > 0 { fw = max(fw, bh) }
        if fw > 0 {
            let r = min(bh / 2, fw / 2)
            gaugeColor(l, i).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: fw, height: bh),
                         xRadius: r, yRadius: r).fill()
        }
    }
    if let bc = badge {
        let d: CGFloat = 4.5
        bc.setFill()
        NSBezierPath(ovalIn: NSRect(x: w - d, y: min(H - d, y0 + stackH + 0.5), width: d, height: d)).fill()
    }
    img.unlockFocus()
    img.isTemplate = false
    return img
}

// MARK: - Dropdown graph

// The click-through view: full-size colourful progress bars for the three
// limits, and underneath a multi-series graph of how they have moved over time.
// Drawn as a real NSView rather than menu text so it can use colour and shape —
// the text rows could show the numbers but never the shape of the usage.
final class UsageGraph: NSView {
    var limits: [(String, Limit)] = []
    var history: [Point] = []

    override func draw(_ dirty: NSRect) {
        let W = bounds.width, pad: CGFloat = 14
        let innerW = W - pad * 2
        NSGraphicsContext.current?.shouldAntialias = true

        // ── Progress bars ────────────────────────────────────────────────
        // Sized to be read instantly: a 12pt track with a full-height rounded
        // fill, 13pt percentages. The first cut used 7pt bars, whose fill at
        // 20-30% was a barely-visible stub.
        let rowH: CGFloat = 30, barH: CGFloat = 12
        let labelW: CGFloat = 60, rightW: CGFloat = 104
        let barW = innerW - labelW - rightW
        var y = bounds.height - 10
        for (i, item) in limits.enumerated() {
            let (name, l) = item
            y -= rowH
            let yc = y + rowH / 2
            func put(_ s: String, _ c: NSColor, _ x: CGFloat, _ sz: CGFloat = 11, _ w: NSFont.Weight = .regular, right: Bool = false) {
                let a = NSAttributedString(string: s, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: sz, weight: w), .foregroundColor: c])
                a.draw(at: NSPoint(x: right ? x - a.size().width : x, y: yc - a.size().height / 2))
            }
            put(name, .secondaryLabelColor, pad, 12, .medium)
            let bx = pad + labelW, by = yc - barH / 2
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: barW, height: barH), xRadius: barH / 2, yRadius: barH / 2).fill()
            // Floor a nonzero fill at one cap-width so low single digits stay
            // visible; the number beside the bar carries the precise value.
            var fw = CGFloat(min(100, l.pct)) / 100 * barW
            if l.pct > 0 { fw = max(fw, barH) }
            if fw > 0.5 {
                let r = min(barH / 2, fw / 2)
                gaugeColor(l, i).setFill()
                NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: fw, height: barH), xRadius: r, yRadius: r).fill()
            }
            put("\(l.pct)%", alertLevel(l) > 0 ? gaugeColor(l, i) : .labelColor, bx + barW + 44, 13, .semibold, right: true)
            put(reset(l.reset), .secondaryLabelColor, W - pad, 11, .regular, right: true)
        }

        // ── History graph ────────────────────────────────────────────────
        y -= 8
        let gh: CGFloat = 60
        let gy = y - gh
        guard gy > 4 else { return }
        let frame = NSRect(x: pad + labelW, y: gy, width: innerW - labelW, height: gh)

        // AUTO-SCALE the y axis. These limits sit in single digits most of the
        // time, and on a fixed 0-100 axis every series flatlines along the
        // bottom — technically honest, visually useless. Scale to the peak
        // instead and LABEL the top tick, so the axis still says exactly what it
        // means. Floor of 20 keeps a near-zero graph from magnifying noise.
        let peak = history.reduce(0.0) { max($0, max($1.s, max($1.w, $1.f))) }
        let yMax = min(100.0, max(20.0, (peak * 1.35 / 10).rounded(.up) * 10))
        NSColor.quaternaryLabelColor.setStroke()
        for frac in [0.0, 0.5, 1.0] {
            let gp = NSBezierPath()
            gp.move(to: NSPoint(x: frame.minX, y: frame.minY + CGFloat(frac) * gh))
            gp.line(to: NSPoint(x: frame.maxX, y: frame.minY + CGFloat(frac) * gh))
            gp.lineWidth = 0.5; gp.stroke()
        }
        func tick(_ s: String, _ yy: CGFloat) {
            let a = NSAttributedString(string: s, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            a.draw(at: NSPoint(x: frame.minX - 6 - a.size().width, y: yy - 5))
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
        let t0 = history.first!.t, t1 = max(history.last!.t, t0 + 1)
        func line(_ pick: (Point) -> Double, _ color: NSColor) {
            let p = NSBezierPath()
            for (i, pt) in history.enumerated() {
                let x = frame.minX + CGFloat((pt.t - t0) / (t1 - t0)) * frame.width
                let yy = frame.minY + CGFloat(min(yMax, max(0, pick(pt))) / yMax) * gh
                i == 0 ? p.move(to: NSPoint(x: x, y: yy)) : p.line(to: NSPoint(x: x, y: yy))
            }
            p.lineWidth = 1.6; p.lineJoinStyle = .round; p.lineCapStyle = .round
            color.setStroke(); p.stroke()
        }
        line({ $0.s }, seriesColors[0])
        line({ $0.w }, seriesColors[1])
        line({ $0.f }, seriesColors[2])

        // Span label, INSIDE the plot's top-right — drawn below the frame it was
        // clipped by the view's own bottom edge.
        let span = Int(t1 - t0)
        let spanTxt = span < 3600 ? "\(max(1, span / 60))m" : (span < 86400 ? "\(span / 3600)h" : "\(span / 86400)d")
        let sa = NSAttributedString(string: "last \(spanTxt)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        sa.draw(at: NSPoint(x: frame.maxX - sa.size().width - 2, y: frame.maxY - 10))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var claudeItem: NSStatusItem!
    private let claudeMenu = NSMenu()
    private var timer: Timer?
    private var stats = Stats()
    private var haveStats = false
    private var statsScript = ""
    private var lastError: String?
    private var lastGood: Date?          // when the collector last returned parseable JSON
    private var failStreak = 0
    private var collecting = false

    // Where the collector may live, in order. The environment wins so a checkout
    // can be tested without installing, then the two usual bin directories.
    private static var statsCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["CLAUDE_METER_STATS"], !e.isEmpty { c.append(e) }
        c.append("\(home)/.local/bin/claude-meter-stats")
        c.append("/usr/local/bin/claude-meter-stats")
        c.append("/opt/homebrew/bin/claude-meter-stats")
        return c
    }

    // The meter's own health, distinct from the data's age. Three missed
    // 30s ticks means the collector itself is failing or wedged.
    private var collectorSick: Bool {
        if failStreak >= 3 { return true }
        guard let g = lastGood else { return false }
        return Date().timeIntervalSince(g) > 150
    }
    // Age of the DATA as of now: age at collection time plus time since then.
    private var dataAge: Int {
        guard haveStats, stats.ageS >= 0 else { return -1 }
        let since = lastGood.map { Int(Date().timeIntervalSince($0)) } ?? 0
        return stats.ageS + max(0, since)
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
        for a in others { a.terminate() }

        for c in Self.statsCandidates where FileManager.default.isExecutableFile(atPath: c) {
            statsScript = c
            break
        }

        claudeMenu.delegate = self
        claudeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        claudeItem.menu = claudeMenu
        if let b = claudeItem.button {
            b.imagePosition = .imageLeading
            b.attributedTitle = barText("…", .secondaryLabelColor)
        }
        refresh()

        // .common mode, or the timer freezes exactly when someone is LOOKING at
        // the meter: menu tracking runs the run loop in event-tracking mode,
        // where a default-mode timer never fires.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Refresh immediately at wake instead of painting pre-sleep numbers
        // for up to a full tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    // MARK: Collect

    private func refresh() {
        guard !statsScript.isEmpty else { lastError = "claude-meter-stats not found"; failStreak += 1; render(); return }
        // One collection at a time: a wedged run must not pile new processes on
        // top of itself every tick. Liveness is preserved by the watchdog below
        // plus collectorSick surfacing the gap in the UI.
        guard !collecting else { return }
        collecting = true
        let script = statsScript
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            var parsed: Stats?; var err: String?
            do {
                try p.run()
                // Watchdog. The script bounds its own slow path (curl 15s), so
                // 25s only trips when something is genuinely wedged; killing it
                // turns a silent freeze into a visible error state. The read
                // below still returns because every child holding the pipe is
                // itself time-bounded.
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: killer)
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                parsed = Self.parse(d)
                if parsed == nil { err = d.isEmpty ? "collector timed out" : "collector output unparseable" }
            } catch { err = "collector failed to start" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.collecting = false
                if let s = parsed {
                    self.stats = s; self.haveStats = true
                    self.lastError = nil; self.lastGood = Date(); self.failStreak = 0
                } else {
                    self.lastError = err; self.failStreak += 1
                }
                self.render()
            }
        }
    }

    private static func parse(_ data: Data) -> Stats? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var s = Stats()
        if let c = root["claude"] as? [String: Any] {
            s.ok = c["ok"] as? Bool ?? false
            s.account = c["account"] as? String ?? ""
            s.email = c["email"] as? String ?? ""
            s.source = c["source"] as? String ?? ""
            s.ageS = c["age_s"] as? Int ?? Int(((c["stale_hours"] as? Double) ?? -1) * 3600)
            s.fetchErr = c["fetch_err"] as? String ?? ""
            s.retryIn = c["retry_in"] as? Int ?? 0
            func lim(_ k: String) -> Limit {
                guard let d = c[k] as? [String: Any] else { return Limit() }
                return Limit(pct: d["pct"] as? Int ?? 0, reset: d["reset_in"] as? Int ?? 0,
                             severity: d["severity"] as? String ?? "normal")
            }
            s.session = lim("session"); s.weekly = lim("weekly"); s.scoped = lim("scoped")
        }
        return s
    }

    // MARK: Bar rendering

    private func barText(_ s: String, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: c,
        ])
    }

    private func render() {
        guard let b = claudeItem.button else { return }
        let badge: NSColor? = collectorSick ? muted(.systemRed) : (dataStale ? muted(.systemYellow) : nil)
        guard haveStats, stats.ok else {
            b.image = barsGlyph([Limit(), Limit(), Limit()], badge: badge ?? (haveStats ? nil : muted(.systemYellow)))
            b.attributedTitle = barText("—", .secondaryLabelColor)
            return
        }
        let limits = [stats.session, stats.weekly, stats.scoped]
        b.image = barsGlyph(limits, badge: badge)
        // The number is the SESSION % — the value that moves while working —
        // unless another limit is hot, in which case the hot one takes over
        // with its label so the number stays self-describing ("wk 92%").
        let named: [(String, Limit)] = [("5h", stats.session), ("wk", stats.weekly), ("pm", stats.scoped)]
        let worst = named.enumerated().max {
            (alertLevel($0.element.1), $0.element.1.pct) < (alertLevel($1.element.1), $1.element.1.pct)
        }!
        var text = "\(stats.session.pct)%"
        var color: NSColor = dataStale || collectorSick ? .secondaryLabelColor : .labelColor
        if alertLevel(worst.element.1) > 0 {
            color = gaugeColor(worst.element.1, worst.offset)
            if worst.offset != 0 { text = "\(worst.element.0) \(worst.element.1.pct)%" }
        }
        b.attributedTitle = barText(text, color)
    }

    // MARK: Menu (rebuilt at open, so ages are computed when eyes are on them)

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === claudeMenu { buildClaudeMenu(menu) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // An open is a moment the numbers are actually being read — collect in
        // the background so the NEXT look (and the bar, seconds later) is fresh.
        refresh()
    }

    private func header(_ m: NSMenu, _ s: String) {
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        m.addItem(x)
    }

    private func note(_ m: NSMenu, _ s: String, color: NSColor = .secondaryLabelColor) {
        let x = NSMenuItem(title: s, action: nil, keyEquivalent: ""); x.isEnabled = false
        x.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: color,
        ])
        m.addItem(x)
    }

    // Text-only action rows, like the system's own status menus. (SF Symbol
    // images on these rows were tried and do not render in this status-menu
    // context; the custom-drawn glyph carries the iconography instead.)
    private func action(_ m: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let x = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        x.target = self
        m.addItem(x)
    }

    private func freshnessLine(_ m: NSMenu) {
        let upd = lastGood.map { relAge(Int(Date().timeIntervalSince($0))) } ?? "never"
        // Say where the numbers CAME FROM and how old they are — the age of the
        // data, not of the last poll, is what decides whether to trust them.
        if stats.source == "api" && !dataStale {
            note(m, "Usage API · fetched \(relAge(dataAge))")
        } else {
            let age = relAge(dataAge).replacingOccurrences(of: " ago", with: "")
            note(m, "Data \(age) old · from \(stats.source == "api" ? "usage API" : "claude's session cache")",
                 color: dataStale ? .systemOrange : .secondaryLabelColor)
        }
        // A down live path is stated with its reason and retry time — a silent
        // fallback is indistinguishable from freshness, which is the one lie a
        // meter must not tell. No "run claude" advice here: the live path does
        // not need claude, and the hint was wrong exactly when it showed.
        if !stats.fetchErr.isEmpty {
            let retry = stats.retryIn > 0 ? " · retry in \(max(1, stats.retryIn / 60))m" : ""
            note(m, "Live fetch \(stats.fetchErr)\(retry)", color: .systemOrange)
        }
        if collectorSick {
            note(m, "Meter not refreshing — \(lastError ?? "collector silent") · last success \(upd)", color: .systemRed)
        }
    }

    private func buildClaudeMenu(_ m: NSMenu) {
        m.removeAllItems()
        header(m, stats.email.isEmpty ? "Claude usage"
                                      : "\(stats.email) · \(stats.account)")
        if haveStats, stats.ok {
            freshnessLine(m)
            let g = UsageGraph(frame: NSRect(x: 0, y: 0, width: 340, height: 176))
            g.limits = [("Session", stats.session), ("Week", stats.weekly), ("Premium", stats.scoped)]
            g.history = loadHistory()
            let gi = NSMenuItem(); gi.view = g; m.addItem(gi)
        } else if haveStats {
            note(m, "No usage data yet — sign in to Claude Code once")
        } else {
            note(m, lastError ?? "Collecting…")
        }
        m.addItem(.separator())
        action(m, "Refresh Now", #selector(doRefresh), key: "r")
        m.addItem(.separator())
        action(m, "Quit Claude Meter", #selector(quit), key: "q")
    }

    @objc private func doRefresh() { refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
