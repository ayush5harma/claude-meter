// Resolve every colour the meter DRAWS under both appearances and report the
// contrast between the pairs that have to be told apart, so "does the glyph
// survive a light menu bar" is answered with numbers instead of with a
// screenshot of the one appearance the author happens to run.
//
// It duplicates `muted()` and the colour choices from Sources/main.swift on
// purpose: this is a measurement of those choices, and a measurement that
// imports the thing it measures cannot disagree with it. If the two ever
// drift, this file is wrong and the drift is the finding.
//
// Run: swift test/contrast/contrast.swift

import AppKit

func muted(_ c: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        let neutral = NSColor(calibratedWhite: isDark ? 0.58 : 0.34, alpha: 1)
        let away = NSColor(calibratedWhite: isDark ? 1 : 0, alpha: 1)
        let grey: CGFloat = isDark ? 0.208 : 0.859
        let track = NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
        let base = c.blended(withFraction: 0.38, of: neutral) ?? c
        var result = base
        var extra: CGFloat = 0
        while contrast(result, track) < 3, extra < 0.7 {
            extra += 0.05
            result = base.blended(withFraction: extra, of: away) ?? base
        }
        return result
    }
}

// Relative luminance and contrast ratio, WCAG 2.1.
func luminance(_ c: NSColor) -> CGFloat {
    guard let rgb = c.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ v: CGFloat) -> CGFloat {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent)
        + 0.7152 * channel(rgb.greenComponent)
        + 0.0722 * channel(rgb.blueComponent)
}

func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

// A translucent colour over a background is what the eye actually sees, so the
// track -- which is quaternaryLabelColor, and mostly alpha -- is composited
// before it is measured. Comparing its raw value would flatter it.
func over(_ top: NSColor, _ bottom: NSColor) -> NSColor {
    guard let t = top.usingColorSpace(.sRGB), let b = bottom.usingColorSpace(.sRGB) else { return top }
    let a = t.alphaComponent
    return NSColor(srgbRed: t.redComponent * a + b.redComponent * (1 - a),
                   green: t.greenComponent * a + b.greenComponent * (1 - a),
                   blue: t.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
}

func hex(_ c: NSColor) -> String {
    guard let r = c.usingColorSpace(.sRGB) else { return "?" }
    return String(format: "#%02X%02X%02X", Int(r.redComponent * 255 + 0.5),
                  Int(r.greenComponent * 255 + 0.5), Int(r.blueComponent * 255 + 0.5))
}

let series: [(String, NSColor)] = [
    ("series 1 blue", muted(.systemBlue)), ("series 2 purple", muted(.systemPurple)),
    ("series 3 teal", muted(.systemTeal)), ("series 4 indigo", muted(.systemIndigo)),
    ("series 5 green", muted(.systemGreen)),
    ("warning orange", muted(.systemOrange)), ("critical red", muted(.systemRed)),
    ("health yellow", muted(.systemYellow)),
]

// The two appearances, and the background the menu bar actually presents in
// each: a light bar is near-white, a dark one near-black. The menu bar is a
// translucent material over the desktop, so these are the extremes it tends
// toward rather than exact values -- which is the point, since a colour that
// works at both extremes works between them.
let cases: [(String, NSAppearance.Name, NSColor)] = [
    ("dark", .darkAqua, NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)),
    ("light", .aqua, NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1)),
]

var worstFillOnTrack = CGFloat.greatestFiniteMagnitude
var worstTrackOnBar = CGFloat.greatestFiniteMagnitude

for (name, appearanceName, bar) in cases {
    guard let appearance = NSAppearance(named: appearanceName) else { continue }
    print("\n## \(name) appearance   (menu bar taken as \(hex(bar)))\n")
    // performAsCurrent is unavailable on this toolchain's NSAppearance, so the
    // current appearance is swapped and restored by hand -- the same thing it
    // does, and what every dynamic NSColor resolves against.
    let previous = NSAppearance.current
    NSAppearance.current = appearance
    do {
        let track = over(.quaternaryLabelColor, bar)
        let trackOnBar = contrast(track, bar)
        worstTrackOnBar = min(worstTrackOnBar, trackOnBar)
        print(String(format: "  gauge track      %@  vs bar   %.2f:1", hex(track), trackOnBar))
        print("")
        print("  fill                       vs track   vs bar")
        for (label, colour) in series {
            let solid = over(colour, track)
            let onTrack = contrast(solid, track)
            let onBar = contrast(solid, bar)
            worstFillOnTrack = min(worstFillOnTrack, onTrack)
            let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
            print(String(format: "  %@ %@   %5.2f:1   %5.2f:1",
                         padded, hex(solid), onTrack, onBar))
        }
    }
    NSAppearance.current = previous
}

print(String(format: "\nworst fill-on-track %.2f:1, worst track-on-bar %.2f:1", worstFillOnTrack, worstTrackOnBar))
// 3:1 is WCAG's floor for a non-text graphical object, which is what every one
// of these is. Anything under it is a defect, not a preference.
exit(worstFillOnTrack >= 3.0 && worstTrackOnBar >= 1.2 ? 0 : 1)
