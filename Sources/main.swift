// Usage Meter — one menu-bar item showing the Claude account's real rate-limit
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
// ONE METER, EVERY AGENT. The glyph shows Claude's three windows and then ONE
// BAR PER OTHER TOOL the meter has a number for, so a Codex window at 96% is
// visible without opening anything -- which is the whole point of a meter, and
// was not true when Codex lived only in the dropdown. The number is still
// Claude's session percentage until something is hot, and then the hottest
// window of any tool takes it over and brings its own tag.
//
// Claude keeps three bars rather than collapsing to one, because on the
// commonest Mac -- Claude alone -- one bar would throw away two limits that
// are legible today to solve a problem that Mac does not have. The stack is
// re-fitted to the menu bar's height instead of the item growing wider: the
// item is 16 pt at three bars and 16 pt at five, so adding a tool never moves
// anything else in the menu bar.
//
// ROTATING BETWEEN TOOLS WAS REJECTED and it was not close: a value that
// changes while nothing changed is noise, and a meter that is sometimes
// showing you the other tool is one you cannot read at a glance.
//
// In the dropdown every tool gets the SAME four parts in the same places --
// name and identity, where the number came from and how old it is, one bar per
// window, then the facts that are not percentages -- so the eye learns one
// layout. A tool that is not installed contributes NOTHING: no section, no
// empty row, no error. A tool that is installed but has no number to give
// contributes one line rather than a section that could only ever say "no
// data". The collector decides which; this file draws what it is given.
//
// IT COLLECTS NO DATA ITSELF. bin/usage-meter-stats emits the JSON.

import AppKit

// MARK: - CLI mode — run a command under this app's identity
//
// `UsageMeter --run <program> [args…]` runs the program as a CHILD of this
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
        FileHandle.standardError.write(Data("usage: UsageMeter --run <program> [args…]\n".utf8))
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
        FileHandle.standardError.write(Data("UsageMeter: cannot run \(program): \(error)\n".utf8))
        exit(126)
    }
    child.waitUntilExit()
    exit(child.terminationStatus)
}

// MARK: - CLI mode — render the glyph to a file
//
// `UsageMeter --glyph <out.png> [--bars 27,98,76,42] [--appearance light|dark]`
// draws the menu-bar glyph and exits. It exists because the images in the
// README and docs/ have to be regenerated whenever the design moves, and
// driving the real menu bar with AppleScript to photograph it is a worse way
// to get them: it can only ever produce the appearance the machine is
// currently in, so the LIGHT one could not be checked at all without changing
// a setting on somebody's Mac.
//
// The bars are given explicitly rather than collected, so an image in the
// documentation shows what it says it shows.
//
// Before any AppKit global, for the same reason as `--run`.
func renderGlyph(_ argv: [String]) -> Never {
    var out = "", bars = [27, 98, 76], appearanceName = "dark"
    var rest = argv[...]
    if let first = rest.first, !first.hasPrefix("--") { out = first; rest = rest.dropFirst() }
    while let flag = rest.first {
        rest = rest.dropFirst()
        guard let value = rest.first else { break }
        rest = rest.dropFirst()
        switch flag {
        case "--bars": bars = value.split(separator: ",").compactMap { Int($0) }
        case "--appearance": appearanceName = value
        case "--out": out = value
        default: break
        }
    }
    guard !out.isEmpty, !bars.isEmpty else {
        FileHandle.standardError.write(Data(
            "usage: UsageMeter --glyph <out.png> [--bars 27,98,76,42] [--appearance light|dark]\n".utf8))
        exit(64)
    }
    // AppKit needs its shared application before anything can be drawn into an
    // image: without it `lockFocus` fails with "size zero" on an image whose
    // size is plainly not zero (measured 2026-09-21). `.prohibited` keeps this
    // out of the Dock and out of the status bar -- a render is not a launch.
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSAppearance.current = NSAppearance(named: appearanceName == "light" ? .aqua : .darkAqua)
    let limits = bars.map { Limit(pct: $0) }
    let image = barsGlyph(limits, groupAfter: limits.count > 3 ? 3 : 0)
    guard let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("UsageMeter: could not encode the glyph\n".utf8))
        exit(70)
    }
    do { try png.write(to: URL(fileURLWithPath: out)) } catch {
        FileHandle.standardError.write(Data("UsageMeter: cannot write \(out): \(error)\n".utf8))
        exit(73)
    }
    exit(0)
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "--run" { runUnderThisIdentity(Array(cliArgs.dropFirst())) }


// MARK: - Paths

// The collector's cache directory, the only place outside the collector this
// app reads. It does NOT follow USAGE_METER_CACHE_DIR, which the collector
// does: point that elsewhere and the dropdown's history graph goes empty.
// The collector migrates ~/.cache/claude-meter to this path on its first run
// after the rename, so the app only ever needs to know the new one.
let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/usage-meter")

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
    var tag = ""             // the short form the menu bar has room for, "cdx"
    var ok = false
    // A tool the collector says has no number to give: drawn as ONE LINE after
    // the sections, never as a section. A section that can only ever say "no
    // data" is a permanent empty chair; the fact worth carrying is that the
    // meter knows the tool is there and knows why it has nothing.
    var footnote = false
    var headline = ""        // account line beside the name, e.g. "you@example.com · free"
    var source = ""
    var ageS = -1
    var fetchErr = ""
    var retryIn = 0
    var note = ""            // why there is nothing to show, in words
    var limits: [(String, Limit)] = []
    // Facts that are not a percentage — the model in use, credits, a ceiling
    // the backend says has been reached — already worded by the collector and
    // printed under the bars. The collector owns the words and this file owns
    // the drawing, so a new fact is one line there and none here.
    var details: [String] = []

    // The one window that decides this tool's bar in the glyph and its claim on
    // the number: hottest first, then highest, the same comparison the Claude
    // limits are ranked by so one rule orders every window on the machine.
    var worst: Limit? {
        limits.map { $0.1 }.max { (alertLevel($0), $0.pct) < (alertLevel($1), $1.pct) }
    }
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

// The same span written out for a SENTENCE rather than for a column. "29d23h"
// is right where it has to line up under another countdown and wrong where it
// is read as prose, which is where the single-window block puts it.
func formatSpan(_ seconds: Int) -> String {
    if seconds <= 0 { return "" }
    if seconds < 3600 { return "\(max(1, seconds / 60)) min" }
    if seconds < 86400 {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
    let d = seconds / 86400, h = (seconds % 86400) / 3600
    return h > 0 ? "\(d)d \(h)h" : "\(d)d"
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

// MARK: - The scale
//
// Four type sizes and one set of metrics, named once so a change is one number
// and so the code can be checked against docs/design.md rather than against
// itself. Monospaced digits everywhere a number is drawn: a percentage ticking
// from 9% to 10% must not shift the column it sits in.
enum Type {
    // Relative to the system font size rather than absolute, so a Mac
    // configured with a larger one gets a proportionally larger dropdown.
    //
    // Measured 2026-09-21: NSFont.systemFontSize is 13 by default here, and
    // AppKit does NOT scale systemFont(ofSize:) with the Accessibility text
    // size -- NSFont.preferredFont(forTextStyle:) is the API that does, and
    // adopting it would mean re-deriving every metric below from what it
    // returns. So this closes the half that is free, and the other half is a
    // known gap rather than an unknown one.
    static let scale = NSFont.systemFontSize / 13
    static let identity: CGFloat = 12.5 * scale   // "Codex · you@example.com · pro"
    static let figure: CGFloat = 13 * scale       // the percentage, one number per row
    static let label: CGFloat = 12 * scale        // the window's name
    static let body: CGFloat = 11.5 * scale       // source and age, details, footnotes
    static let caption: CGFloat = 11 * scale      // the countdown
    static let tick: CGFloat = 8 * scale          // the graph's axis
}

enum Metric {
    static let contentWidth: CGFloat = 340
    static let gutter: CGFloat = 16
    static let row: CGFloat = 28            // one window row
    static let bar: CGFloat = 12            // its gauge
    static let soloBlock: CGFloat = 56      // a section with exactly one window
    static let soloBar: CGFloat = 14
    static let percentColumn: CGFloat = 40
    static let countdownColumn: CGFloat = 52
    static let graph: CGFloat = 60
}

// MARK: - Colour

// WCAG 2.1 relative luminance, so the palette can check itself rather than be
// trusted. Every drawn thing here is a graphical object, whose floor is 3:1.
func relativeLuminance(_ c: NSColor) -> CGFloat {
    guard let rgb = c.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ v: CGFloat) -> CGFloat {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
        + 0.0722 * channel(rgb.blueComponent)
}

func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let (x, y) = (relativeLuminance(a), relativeLuminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

// The gauge track as it is actually seen: quaternaryLabelColor is mostly alpha,
// so what a fill sits on is that colour composited over the bar. Measured with
// test/contrast on 2026-09-21: #353535 on a dark bar, #DBDBDB on a light one.
// Named here as the surface the mute below has to clear.
let trackSurface: [Bool: CGFloat] = [true: 0.208, false: 0.859]

// MUTED, AND IT CHECKS ITSELF.
//
// Everything DRAWN uses a muted variant of a system colour: full-saturation
// system colours shout next to the bar's monochrome template icons, and a meter
// is furniture, not an alert box. Menu TEXT keeps the stock system colours,
// because those rows are standard UI.
//
// Three things make this dynamic rather than a constant:
//
//  1. It resolves when it is DRAWN. `seriesColors` is a `let` at file scope, so
//     a colour blended once would freeze whatever appearance the app launched
//     into and never follow a switch to the other one.
//  2. The blend TARGET follows the appearance. Muting toward a light grey pulls
//     a shouting colour back toward the furniture on a DARK bar; on a light one
//     it lightens an already-light colour until it vanishes into the track.
//  3. It then keeps going until it clears 3:1 against that track, because
//     muting and legibility pull in opposite directions and legibility wins.
//     Measured 2026-09-21 against a fixed 0.58 blend: in the light appearance
//     every fill fell under 3:1 and the health badge reached 1.25:1, which is
//     not a badge. The cap at 0.7 stops a colour that cannot get there from
//     going to pure black or white; nothing in the current palette hits it.
func muted(_ c: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        // "Increase contrast" is the user saying, in the system's own words,
        // that they do not want de-emphasis. Muting is exactly that, so it is
        // dropped and the full-strength system colour is used instead.
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { return c }
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        let neutral = NSColor(calibratedWhite: isDark ? 0.58 : 0.34, alpha: 1)
        let away = NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 1)
        // sRGB, not calibratedWhite: the two grey spaces differ by enough
        // gamma that the same number resolves to a different luminance, and
        // the loop was clearing its own optimistic copy of the track while the
        // real one measured 2.80:1 (2026-09-21).
        let grey = trackSurface[isDark] ?? 0.5
        let track = NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
        let base = c.blended(withFraction: 0.38, of: neutral) ?? c
        var result = base
        var extra: CGFloat = 0
        while contrastRatio(result, track) < 3, extra < 0.7 {
            extra += 0.05
            result = base.blended(withFraction: extra, of: away) ?? base
        }
        return result
    }
}

// Per-limit ACCENT colour, Little Snitch style: the colour identifies which
// series a bar belongs to, so three meters at similar low percentages are still
// told apart at a glance (all-green bars were indistinguishable). Severity still
// wins when a limit is actually hot — danger must never be traded for prettiness.
// Five, not three: three named Claude's three windows, and the glyph now also
// carries a bar per other tool while a multi-bucket Codex account can report
// four windows in one section. Running out meant two different series wearing
// one colour, which is the one thing per-series colour exists to prevent.
let seriesColors: [NSColor] = [muted(.systemBlue), muted(.systemPurple), muted(.systemTeal),
                               muted(.systemIndigo), muted(.systemGreen)]

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
func barsGlyph(_ limits: [Limit], groupAfter: Int = 0, badge: NSColor? = nil) -> NSImage {
    let width: CGFloat = 16
    let count = max(1, limits.count)
    // A wider gap after Claude's block, so five lines read as two groups rather
    // than as a run of five.
    let groupGap: CGFloat = (groupAfter > 0 && groupAfter < count) ? 1.6 : 0
    // The item never gets wider; the stack gets denser. Measured on this Mac,
    // whose menu bar reports 22 pt: three bars are EXACTLY the geometry this
    // meter has always drawn (2.600 pt bars, 2.200 pt gaps, a 12.2 pt stack,
    // unscaled); a fourth costs 3.5% of the bar's thickness (2.508 pt) and a
    // fifth costs a quarter of it (1.956 pt), which at 2x is still four solid
    // pixels of colour. The first draft of this comment said "four at full
    // thickness, five shrinks by a tenth" and both figures were wrong -- they
    // were reasoned from a 24 pt bar that this Mac does not have.
    var barHeight: CGFloat = 2.6, gap: CGFloat = 2.2
    let bars = barHeight * CGFloat(count) + gap * CGFloat(count - 1)
    let maxStack = max(12.2, menuBarHeight - 4)
    if bars + groupGap > maxStack {
        let scale = (maxStack - groupGap) / bars
        barHeight *= scale
        gap *= scale
    }
    let stackHeight = barHeight * CGFloat(count) + gap * CGFloat(count - 1) + groupGap
    let image = NSImage(size: NSSize(width: width, height: menuBarHeight))
    image.lockFocus()
    NSGraphicsContext.current?.shouldAntialias = true
    let bottom = (menuBarHeight - stackHeight) / 2
    for (i, limit) in limits.enumerated() {
        // First limit on top; everything above the group break is lifted by the
        // extra gap.
        let y = bottom + CGFloat(count - 1 - i) * (barHeight + gap)
            + (i < groupAfter ? groupGap : 0)
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

    private let pad = Metric.gutter

    // The label column is as wide as this section's own widest label, and that
    // is not polish. It was 60 pt for everyone, which fits "Session", "Week"
    // and a model name — and a multi-bucket codex account labels its rows by
    // the metered bucket they belong to, so "Agents 30-day" and "Codex Weekly"
    // were drawn straight THROUGH the gauge beside them (seen in the running
    // app against the multi-bucket fixture, 2026-09-21; the JSON was correct
    // and the menu was not, which is the whole argument for looking at it).
    // Clamped at both ends: 60 keeps the tight layout every section had before
    // this, and 120 stops one long label from leaving no room for the bar.
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: Type.label,
                                                                    weight: .medium)
    private var labelColumn: CGFloat {
        let widest = limits.reduce(CGFloat(0)) {
            max($0, NSAttributedString(string: $1.0, attributes: [.font: UsageView.labelFont])
                .size().width)
        }
        return min(120, max(60, widest.rounded(.up) + 10))
    }

    // ONE WINDOW IS NOT THREE WINDOWS. A plan with a single usage window must
    // not read as a plan with three minus two: a free Codex account has exactly
    // one fact worth having -- when it resets -- and one number that will say
    // 0% for most of a month. So it gets its own composition (see
    // `drawSoloWindow`) rather than one lonely row in a grid built for
    // comparing several.
    private var isSolo: Bool { limits.count == 1 && !drawsHistory }

    // The exact height this view needs, so a section is sized from its own
    // content instead of from a constant re-guessed every time a tool with a
    // different number of windows appears.
    static func height(rows: Int, history: Bool) -> CGFloat {
        if rows == 1 && !history { return 6 + Metric.soloBlock + 6 }
        let rowsHeight = 6 + CGFloat(rows) * Metric.row
        return history ? rowsHeight + 8 + Metric.graph + 8 : rowsHeight + 6
    }

    override func draw(_ dirty: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        guard !isSolo else {
            drawSoloWindow(top: bounds.height - 6)
            return
        }
        let belowRows = drawLimitRows(top: bounds.height - 6)
        guard drawsHistory else { return }
        let graphY = belowRows - 8 - Metric.graph
        guard graphY > 4 else { return }
        drawHistory(in: NSRect(x: pad + labelColumn, y: graphY,
                               width: bounds.width - pad * 2 - labelColumn, height: Metric.graph))
    }

    // The single-window composition: the window's name and its percentage on
    // one line, a full-width bar under them, and the countdown spelled out as a
    // sentence rather than abbreviated into a column that has nothing to line
    // up with.
    private func drawSoloWindow(top: CGFloat) {
        guard let (name, limit) = limits.first else { return }
        let width = bounds.width - pad * 2
        var y = top - 14
        drawText(name, .secondaryLabelColor, x: pad, centredOn: y,
                 size: Type.label, weight: .medium, maxWidth: width - 70)
        drawText("\(limit.pct)%",
                 alertLevel(limit) != .normal ? gaugeColor(limit, 0) : .labelColor,
                 x: bounds.width - pad, centredOn: y, size: Type.figure, weight: .semibold,
                 rightAligned: true)
        y -= 18
        drawGauge(NSRect(x: pad, y: y - Metric.soloBar / 2, width: width, height: Metric.soloBar),
                  pct: limit.pct, color: gaugeColor(limit, 0))
        y -= 18
        let resets = limit.resetIn > 0 ? "resets in \(formatSpan(limit.resetIn))"
                                       : "no reset time reported"
        drawText(resets, .secondaryLabelColor, x: pad, centredOn: y, size: Type.body)
    }

    // One row per limit: name, gauge, percentage, time to reset. Sized to be
    // read instantly — a 12pt track with a full-height rounded fill and 13pt
    // percentages. The first cut used 7pt bars, whose fill at 20-30% was a
    // barely-visible stub. Returns the y the rows end at.
    private func drawLimitRows(top: CGFloat) -> CGFloat {
        let labelColumn = self.labelColumn
        let numbers = Metric.percentColumn + Metric.countdownColumn
        let gaugeWidth = bounds.width - pad * 2 - labelColumn - numbers - 10
        var y = top
        for (i, item) in limits.enumerated() {
            let (name, limit) = item
            y -= Metric.row
            let middle = y + Metric.row / 2
            drawText(name, .secondaryLabelColor, x: pad, centredOn: middle,
                     size: Type.label, weight: .medium, maxWidth: labelColumn - 6)
            drawGauge(NSRect(x: pad + labelColumn, y: middle - Metric.bar / 2,
                             width: gaugeWidth, height: Metric.bar),
                      pct: limit.pct, color: gaugeColor(limit, i))
            drawText("\(limit.pct)%",
                     alertLevel(limit) != .normal ? gaugeColor(limit, i) : .labelColor,
                     x: pad + labelColumn + gaugeWidth + 10 + Metric.percentColumn,
                     centredOn: middle, size: Type.figure, weight: .semibold, rightAligned: true)
            drawText(formatCountdown(limit.resetIn), .secondaryLabelColor,
                     x: bounds.width - pad, centredOn: middle, size: Type.caption,
                     rightAligned: true)
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
                          size: CGFloat = Type.caption, weight: NSFont.Weight = .regular,
                          rightAligned: Bool = false, maxWidth: CGFloat? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        // With a width given, the string is CLIPPED to it with an ellipsis
        // rather than allowed to run on: a label the collector supplies is as
        // long as the server's own words for a metered bucket, and a menu that
        // paints one over the gauge beside it is worse than one that shortens
        // it. Without a width, the old behaviour exactly.
        if maxWidth != nil {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            // A width makes this a BOX, and a box needs to know which edge the
            // text sits against: without this, `rightAligned` with a width
            // would draw left-aligned inside a right-anchored box, which is
            // neither alignment. Nothing passes both today; the combination is
            // reachable, so it is right rather than absent.
            paragraph.alignment = rightAligned ? .right : .left
            attributes[.paragraphStyle] = paragraph
        }
        let text = NSAttributedString(string: s, attributes: attributes)
        let drawn = text.size()          // not `size`: that is this function's font size
        guard let maxWidth else {
            text.draw(at: NSPoint(x: rightAligned ? x - drawn.width : x, y: y - drawn.height / 2))
            return
        }
        text.draw(in: NSRect(x: rightAligned ? x - maxWidth : x, y: y - drawn.height / 2,
                             width: maxWidth, height: drawn.height))
    }

    // The graph's small grey captions: the axis ticks and the span label, each
    // placed from its own measured size.
    private func drawCaption(_ s: String, at place: (NSSize) -> NSPoint) {
        let text = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Type.tick, weight: .regular),
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
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        // Both spellings, new first, for one release: a config-management run
        // pins a commit and deploys the OLD path, so the app has to find it
        // there until that run moves. Same reason bin/ still carries a shim.
        for name in ["USAGE_METER_STATS", "CLAUDE_METER_STATS"] {
            if let fromEnv = environment[name], !fromEnv.isEmpty { candidates.append(fromEnv) }
        }
        for directory in ["\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            candidates.append("\(directory)/usage-meter-stats")
            candidates.append("\(directory)/claude-meter-stats")
        }
        return candidates
    }

    // The tools that contribute a bar to the glyph and can claim the number:
    // installed, not a footnote, and actually holding a reading. A tool that is
    // installed but signed out still gets its section — it just has nothing to
    // put in the menu bar.
    private var numericTools: [ToolReading] { tools.filter { !$0.footnote && $0.ok } }

    // The bars the glyph draws, and where Claude's block ends.
    private var glyphBars: (limits: [Limit], groupAfter: Int) {
        var bars = [stats.session, stats.weekly, stats.scoped]
        let claudeBars = bars.count
        for tool in numericTools {
            if let worst = tool.worst { bars.append(worst) }
        }
        return (bars, bars.count > claudeBars ? claudeBars : 0)
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
        // The OLD bundle id is swept too, and that is the rename's own hazard
        // rather than tidiness: the previous app is a DIFFERENT application to
        // LaunchServices, so without this a Mac mid-upgrade shows two menu-bar
        // items, each convinced it is the only one.
        let me = ProcessInfo.processInfo.processIdentifier
        let identities = [Bundle.main.bundleIdentifier ?? "local.ayushsharma.usage-meter",
                          "local.ayushsharma.claude-meter"]
        for identity in Set(identities) {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: identity)
            where other.processIdentifier != me {
                other.terminate()
            }
        }

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
            lastError = "usage-meter-stats not found"
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
    private static let toolNames: [(key: String, name: String)] = [
        ("codex", "Codex"), ("agy", "Antigravity"),
    ]

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
        tool.tag = (t["tag"] as? String ?? "").isEmpty
            ? String(name.prefix(3)).lowercased() : (t["tag"] as? String ?? "")
        tool.ok = t["ok"] as? Bool ?? false
        tool.footnote = t["footnote"] as? Bool ?? false
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
        tool.details = (t["details"] as? [String] ?? []).compactMap {
            let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        if tool.limits.isEmpty { tool.ok = false }
        return tool
    }

    // MARK: Bar rendering

    private func barText(_ s: String, _ c: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Type.label, weight: .medium),
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
        let glyph = glyphBars
        button.image = barsGlyph(glyph.limits, groupAfter: glyph.groupAfter, badge: badge)
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
        // Every window on the machine, ranked by one rule. A tool's claim is
        // its own worst window, and it brings the tool's tag rather than the
        // window's name: in the menu bar, which tool is hot is the thing you
        // need, and the dropdown has the rest.
        var named: [(String, Limit)] = [("5h", stats.session), ("wk", stats.weekly),
                                        (String(stats.scopedLabel.prefix(12)), stats.scoped)]
        for tool in numericTools {
            if let worst = tool.worst { named.append((tool.tag, worst)) }
        }
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
        // EVERY section names its tool, including this one. This is a meter for
        // several agents now, and a section that is unambiguous only by
        // accident is not a design -- it was unnamed while Claude was the only
        // thing here, and the rename is exactly when that stops being true.
        addHeader(menu, ["Claude", stats.email.isEmpty ? "" : stats.email,
                         stats.email.isEmpty ? "" : stats.account]
            .filter { !$0.isEmpty }.joined(separator: " · "))
        if haveStats, stats.ok {
            addFreshnessRows(menu)
            addUsageView(menu, limits: [("Session", stats.session), ("Week", stats.weekly),
                                        (stats.scopedLabel, stats.scoped)],
                         history: loadHistory(), drawsHistory: true)
        } else if haveStats {
            addNote(menu, "No usage data yet — sign in to Claude Code once")
        } else {
            addNote(menu, lastError ?? "Collecting…")
        }
        addToolSections(menu)
        menu.addItem(.separator())
        addAction(menu, "Refresh Now", #selector(doRefresh), key: "r")
        menu.addItem(.separator())
        addAction(menu, "Quit Usage Meter", #selector(quit), key: "q")
    }

    // One section per other agentic CLI the collector reported on. Nothing is
    // drawn for a tool it did not name, so this loop runs zero times on a Mac
    // that has only Claude Code and the menu is unchanged.
    private func addToolSections(_ menu: NSMenu) {
        for tool in tools where !tool.footnote {
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
            addUsageView(menu, limits: tool.limits, history: [])
            // Under the bars, not above: the percentages are what the section
            // is for, and the model it is spending on is context for them.
            for detail in tool.details { addNote(menu, detail) }
        }
        // Then the tools that have no number to give, one dim line each, after
        // every section rather than inside one — the fact belongs to the
        // machine, not to whichever tool happens to be drawn above it.
        let footnotes = tools.filter { $0.footnote && !$0.note.isEmpty }
        if !footnotes.isEmpty {
            menu.addItem(.separator())
            for tool in footnotes { addNote(menu, tool.note, color: .tertiaryLabelColor) }
        }
    }

    // The one place a section's bars are added, so every tool is drawn by the
    // same view at the same width with the same anatomy. An empty `history`
    // means no graph -- a tool that records none must not be given an empty
    // plot that promises one.
    private func addUsageView(_ menu: NSMenu, limits: [(String, Limit)],
                              history: [HistoryPoint] = [], drawsHistory: Bool = false) {
        guard !limits.isEmpty else { return }
        let view = UsageView(frame: NSRect(
            x: 0, y: 0, width: Metric.contentWidth,
            height: UsageView.height(rows: limits.count, history: drawsHistory)))
        view.limits = limits
        view.history = history
        view.drawsHistory = drawsHistory
        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
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
        addTextRow(menu, text, font: .systemFont(ofSize: Type.identity, weight: .semibold),
                   color: .labelColor)
    }

    private func addNote(_ menu: NSMenu, _ text: String, color: NSColor = .secondaryLabelColor) {
        addTextRow(menu, text, font: .systemFont(ofSize: Type.body), color: color)
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

// AFTER every global, unlike `--run`, and the difference is the reason both
// comments exist. This is main.swift, so globals are initialised in FILE ORDER
// as top-level code runs, not lazily: dispatching a render from up beside
// `--run` read `menuBarHeight` and `seriesColors` before their declarations had
// been reached and drew into an image whose size really was zero (measured
// 2026-09-21). `--run` must be first because it must NOT touch them; this must
// be last because it must.
if cliArgs.first == "--glyph" { renderGlyph(Array(cliArgs.dropFirst())) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
