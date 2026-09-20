# Contrast, measured

Every colour Usage Meter **draws** — the gauge fills, the menu-bar glyph's
bars, the health badge — is a graphical object, whose WCAG 2.1 floor is
**3:1**. The palette is muted on purpose (a meter is furniture, not an alert
box), and muting and legibility pull in opposite directions, so the floor is
enforced rather than hoped for: `muted()` blends toward the neutral that is
away from the background and then keeps going until the result clears 3:1
against the gauge track.

Reproduce with `swift test/contrast/contrast.swift`; it exits non-zero if
anything falls below the floor.

Measured 2026-09-21, macOS 27.2, from the values the app itself resolves.


## The dark appearance   (menu bar taken as #1F1F1F)

    gauge track      #353535  vs bar   1.34:1

    fill                       vs track   vs bar
    series 1 blue    #5098DE    4.05:1    5.43:1
    series 2 purple  #C757D6    3.39:1    4.55:1
    series 3 teal    #55C1CA    5.80:1    7.78:1
    series 4 indigo  #838BDE    3.95:1    5.30:1
    series 5 green   #64C077    5.50:1    7.38:1
    warning orange   #DE9962    5.19:1    6.96:1
    critical red     #DE686C    3.72:1    4.99:1
    health yellow    #DEC34E    7.08:1    9.50:1

## The light appearance   (menu bar taken as #F2F2F2)

    gauge track      #DBDBDB  vs bar   1.25:1

    fill                       vs track   vs bar
    series 1 blue    #337CCB    3.08:1    3.84:1
    series 2 purple  #A83DB6    3.76:1    4.68:1
    series 3 teal    #2E888F    3.02:1    3.76:1
    series 4 indigo  #645BC4    3.92:1    4.89:1
    series 5 green   #3E8A4F    3.06:1    3.81:1
    warning orange   #A96A37    3.14:1    3.92:1
    critical red     #CB494E    3.29:1    4.09:1
    health yellow    #8F7620    3.16:1    3.93:1

worst fill-on-track 3.02:1, worst track-on-bar 1.25:1

## What this found

Against the fixed 0.58 blend the app shipped with until this change, the
**light** appearance failed everywhere: every fill sat between 1.25:1 and
2.62:1 against the track, and the health badge — the mark that says the meter
itself is broken — reached **1.25:1**, which is not a badge. The dark
appearance, which is the one the author runs, was fine throughout, which is
exactly why it went unnoticed.

Two fixes, both in `muted()`:

1. It returns a **dynamic** colour, resolved when it is drawn. `seriesColors`
   is a `let` at file scope, so the old blend froze whatever appearance the app
   launched into and never followed a switch.
2. The blend target follows the appearance, and the result is pushed further
   from the track until it clears the floor.

One number here is deliberately below its neighbours: the **track against the
menu bar** is 1.25–1.34:1. That is not a failure — the track is a recess, not
an object to be read, and its job is to be barely there. What has to be legible
is the fill inside it, which is the `vs track` column.

## Not measured here

The menu bar is a translucent material over whatever is behind it, so the two
backgrounds above are the extremes it tends toward rather than exact values. A
colour that clears the floor at both extremes clears it in between, which is
why the extremes are what this checks.
