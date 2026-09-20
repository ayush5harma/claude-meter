// Draws "Usage Meter"'s app icon FROM CODE, at build time. No binary asset is
// checked in: build.sh compiles this file, runs it, and feeds what it writes to
// actool/iconutil. A .png in the repo would be a blob nobody can diff and that
// nothing regenerates; a hundred lines of CoreGraphics is reviewable and edits
// like source, which is the whole reason this app has no Xcode project either.
//
// Usage: icon <output-dir>
// Writes, into <output-dir>:
//   AppIcon.icon/            an Icon Composer package (icon.json + Assets/) —
//                            the ONLY format that carries light/dark appearance
//                            variants, compiled to Assets.car by actool
//   AppIcon.iconset/         the ten legacy tiles, for `iconutil -c icns` when
//                            actool is absent (it ships with Xcode, not with
//                            the Command Line Tools, which is all a fresh Mac
//                            has)
//
// The glyph is the meter's own subject: a 270-degree dial whose value arc is
// split into the three series the menu bar draws (session / week / premium
// week), in the SAME muted blue-purple-teal. A single thick stroke was chosen
// over three concentric rings because at 16 pt — the size Finder's list view and
// the Dock's recents actually use — concentric 1 px rings turn to mush.

import AppKit

// MARK: - Palette

// The three series colours, in sRGB, as `muted(.systemBlue/.systemPurple/
// .systemTeal)` from main.swift resolves under the Aqua appearance (measured
// 2026-09-07 by running that same blend through NSColor). They are literals
// rather than a live call because a headless render has no window and so no
// appearance to resolve a dynamic system colour against — the values would
// depend on whatever appearance the build happened to inherit.
let seriesColors: [NSColor] = [
    NSColor(srgbRed: 0.3114, green: 0.5741, blue: 0.8711, alpha: 1),   // muted systemBlue
    NSColor(srgbRed: 0.7418, green: 0.3340, blue: 0.7928, alpha: 1),   // muted systemPurple
    NSColor(srgbRed: 0.3313, green: 0.7195, blue: 0.7528, alpha: 1),   // muted systemTeal
]

struct Appearance {
    let name: String
    let tileTop: NSColor
    let tileBottom: NSColor
    let track: NSColor
    let lift: CGFloat        // how far the arcs are blended toward white
}

// Slate instrument in light, graphite in dark. The dark tile goes darker and
// the arcs get lifted toward white, which is what the appearance variant is
// FOR: the same artwork at the same contrast against two different desktops.
let light = Appearance(
    name: "light",
    tileTop: NSColor(srgbRed: 0.32, green: 0.36, blue: 0.47, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.28, alpha: 1),
    track: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20),
    lift: 0)
let dark = Appearance(
    name: "dark",
    tileTop: NSColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 1),
    tileBottom: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1),
    track: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
    lift: 0.22)

func lifted(_ c: NSColor, _ f: CGFloat) -> NSColor {
    f <= 0 ? c : (c.blended(withFraction: f, of: .white) ?? c)
}

// MARK: - Drawing primitives

// Apple's icon corner is a continuous curve, not a circular arc, and AppKit has
// no public API for one. A superellipse |x|^n + |y|^n = 1 at n = 5 tracks it
// closely enough that the difference is invisible below 512 pt, and it costs a
// loop instead of a dependency.
func squircle(in rect: NSRect, n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = rect.midY + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func renderPNG(_ pixels: Int, _ draw: (CGFloat) -> Void) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("cannot allocate a \(pixels)x\(pixels) bitmap") }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.shouldAntialias = true
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode a \(pixels)x\(pixels) PNG")
    }
    return png
}

// MARK: - The glyph

// One stroked arc segment of the dial, in degrees, drawn clockwise from `from`.
func arc(center: NSPoint, radius: CGFloat, from: CGFloat, sweep: CGFloat,
         width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius,
                   startAngle: from, endAngle: from - sweep, clockwise: true)
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

// The dial, drawn into a square canvas. Every measurement is a fraction of the
// canvas, so the same code renders the 1024 pt layer and a 16 pt tile.
func drawGlyph(_ size: CGFloat, _ appearance: Appearance) {
    let center = NSPoint(x: size / 2, y: size * 0.485)   // nudged down: the open gap is at the bottom
    let radius = size * 0.312
    let strokeWidth = size * 0.116

    // A 270-degree sweep open at the bottom is what makes this read as a gauge
    // rather than a generic ring, and the gap survives being 4 px wide.
    let start: CGFloat = 225, span: CGFloat = 270
    arc(center: center, radius: radius, from: start, sweep: span,
        width: strokeWidth, color: appearance.track)

    // Three consecutive value segments, one per limit, in series order. The
    // fractions are illustrative, not live data — an app icon is a portrait of
    // the app, not a readout.
    let fractions: [CGFloat] = [0.40, 0.24, 0.14]
    let gap: CGFloat = 5
    var angle = start
    for (i, fraction) in fractions.enumerated() {
        let sweep = span * fraction
        arc(center: center, radius: radius, from: angle, sweep: sweep,
            width: strokeWidth, color: lifted(seriesColors[i], appearance.lift))
        angle -= sweep + gap
    }
}

func drawTile(_ size: CGFloat, _ appearance: Appearance) {
    let inset = size * 0.008
    let tile = squircle(in: NSRect(x: inset, y: inset,
                                   width: size - 2 * inset, height: size - 2 * inset))
    NSGradient(starting: appearance.tileTop, ending: appearance.tileBottom)?.draw(in: tile, angle: -90)
    drawGlyph(size, appearance)
}

// MARK: - Output

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : { FileHandle.standardError.write(Data("usage: icon <output-dir>\n".utf8)); exit(2) }()

let files = FileManager.default
let iconPackage = outputDir.appendingPathComponent("AppIcon.icon")
let assets = iconPackage.appendingPathComponent("Assets")
let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
for dir in [assets, iconset] {
    try? files.removeItem(at: dir)
    try! files.createDirectory(at: dir, withIntermediateDirectories: true)
}

// The Icon Composer layers: the tile is the package's `fill`, so the layer PNG
// carries only the glyph on transparency and the system masks, shadows and
// glazes it. One PNG per appearance, swapped by `image-name-specializations`.
for appearance in [light, dark] {
    let png = renderPNG(1024) { size in drawGlyph(size, appearance) }
    try! png.write(to: assets.appendingPathComponent("glyph-\(appearance.name).png"))
}

func tileGradientJSON(_ appearance: Appearance) -> String {
    func srgb(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB)!
        return String(format: "srgb:%.5f,%.5f,%.5f,%.5f",
                      c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }
    return "{ \"linear-gradient\" : [ \"\(srgb(appearance.tileTop))\", \"\(srgb(appearance.tileBottom))\" ] }"
}

// Hand-written rather than JSONSerialization so the file reads like the ones
// Icon Composer saves. Schema notes, both learned by compiling and reading the
// result back with assetutil (2026-09-07):
//   - a `*-specializations` array must carry the BASE value as an entry with no
//     `appearance` key. A top-level `fill` plus a dark-only specialization
//     compiles without a word of complaint and silently drops the dark colour.
//   - `shadow`/`translucency` are pinned here rather than left to actool's
//     defaults, so the look cannot drift with the toolchain.
let json = """
{
  "fill-specializations" : [
    { "value" : \(tileGradientJSON(light)) },
    { "appearance" : "dark", "value" : \(tileGradientJSON(dark)) }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "name" : "Dial",
          "image-name-specializations" : [
            { "value" : "glyph-light.png" },
            { "appearance" : "dark", "value" : "glyph-dark.png" }
          ]
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}

"""
try! Data(json.utf8).write(to: iconPackage.appendingPathComponent("icon.json"))

// The legacy set. Each tile is drawn at its own pixel size rather than
// downsampled from 1024, so the 16 pt one keeps its stroke instead of blurring.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = renderPNG(points * scale) { size in drawTile(size, light) }
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
