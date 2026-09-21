# Usage Meter — the design

One menu-bar item for every agentic CLI on the Mac. Written before the code, so
the code can be checked against it.

## What the menu-bar item promises

**How close is each provider to being stopped.** Each provider's tightest
window has its own labelled gauge, so a hot quota is visible before you click
without obscuring the other providers.

Everything else is the dropdown. The item is read in a saccade; the dropdown is
read deliberately.

## The glyph

Three 48 pt columns use the full `Claude`, `Codex`, and `agy` labels at 10 pt,
above a 43 pt horizontal gauge. The status item is 150 pt wide. Each label and
bar form a centred 17.5 pt stack, so the group stays together on both a 22 pt
menu bar and a taller notched bar. The track is outlined with a dash when that
provider has not reported a quota. Exact percentages, ages, and reset times
belong in the hover tooltip and dropdown.

A stale provider dims only its own label and gauge and gains a tiny clock. A
red corner warning is for a collector failure, never a quota level or one
provider's stale reading.

## The grid

| | |
|---|---|
| Content width | 340 pt |
| Side gutter | 16 pt |
| Window row | 28 pt tall, 12 pt bar |
| Single-window block | 56 pt tall, 14 pt bar |
| Percentage column | 46 pt, right-aligned |
| Countdown column | 58 pt, right-aligned |
| Label column | the section's own widest label, clamped 60–120 pt |
| Gap above an identity line | 6 pt (a separator carries the rest) |
| Gap below the last row of a section | 6 pt |

One row anatomy for every window bar, in every tool's section: **label ·
gauge · percentage · countdown**, in those columns, in that order. A Codex
5-hour window and a Claude session window are the same row with different words
in it. That is the point.

## The type scale

Four sizes, derived from one constant so a change is one number.

| Role | Size | Weight | Colour |
|---|---|---|---|
| Identity line | 12.5 | semibold | label |
| Window label | 12 | medium | secondary label |
| Figure (the percentage) | 13 | semibold, monospaced digits | label, or the level colour when hot |
| Body (source·age, details, footnotes) | 11.5 | regular | secondary label |
| Caption (countdown, axis ticks) | 11 / 8 | regular | secondary / tertiary label |

Monospaced digits on every number, so a percentage ticking from 9% to 10% does
not shift the column.

## Colour — three meanings, and no more

1. **Series** — muted blue, purple, teal, indigo, green. Identity only: *which*
   bar this is, so two windows at similar percentages are still told apart. It
   says nothing about level.
2. **Level** — muted orange at ≥75% or a `warning` severity, muted red at ≥90%
   or `critical`. It overrides the series colour, because danger is never
   traded for prettiness.
3. **Meter health** — each provider's gauge dims and gains a tiny clock when
   its own data is over 45 minutes old; a red corner warning is reserved for a
   collector failure affecting the meter itself.

Everything *drawn* is muted (blended 38% toward mid-grey): full-saturation
system colours shout beside the bar's monochrome template icons, and a meter is
furniture. Menu **text** keeps the stock system label colours, because those
rows are standard UI.

**The alarm is carried by marks, not by hue.** A hot window changes the bar's
colour *and* prints its percentage in that colour *and*, when it is the worst
thing on the machine, takes over the menu-bar number with its own label. The
health dot is a different shape from everything else in the glyph, so "the
meter is sick" can never be mistaken for "a limit is hot". Colour names the
alarm; it is never the only thing carrying it.

## A section

Four parts, same order, same places, for every tool:

```
Codex · you@example.com · pro          ← identity line
codex app-server · read 2m ago         ← where the number came from, how old
5h    [======        ]  42%   3h07     ← one row per window
Week  [==            ]   7%   2d4h
Credits: 1,250                         ← facts that are not percentages
```

- The **identity line** always names the tool. This is a meter for several, and
  a section that is unambiguous only by accident is not a design.
- The **source-and-age line** reads as a sentence: where the number came from,
  then how old it is. It turns orange past 45 minutes. A live fetch that is
  down gets its own line, with the reason and the retry, because a silent
  fallback to an old cache is indistinguishable from freshness — the one lie a
  meter must not tell.
- **Details** are sentences the collector wrote, not fields this app formats.
  The collector owns the words; the app owns the drawing.
- The **history graph** belongs to a tool that *has* history. Today only Claude
  records any. An empty plot under a tool that will never fill it is a promise
  the meter is not keeping.

## One window is not three windows

A plan with a single usage window must not look like a plan with three, minus
two. A free Codex account has exactly one fact worth having — **when it
resets** — and one number that will read 0% for most of a month.

So a section with exactly one window is composed differently:

```
30-day                                  0%
[==========================================]
resets in 29d 23h
```

Full-width bar, the percentage promoted to its own line beside the window name,
and the countdown promoted from a right-aligned caption to a **stated fact**
underneath. Nothing is invented and nothing is padded; the one thing there is
to say is said properly.

Two or more windows use the row grid above, where a compact, scannable column
layout is what the comparison needs.

## A tool with no number

One dim line after the last section, at body size in tertiary label colour,
saying that the tool is installed and exposes no usage locally. Not a section:
a section that can only ever say "no data" is a permanent empty chair. The
collector marks it, so the day the tool exposes a number the flag comes off and
it becomes an ordinary section with no UI change at all.

## Appearance and accessibility

- Every colour is a **dynamic** system colour or a blend of one, resolved when
  it is drawn rather than when this file's globals are initialised, so light and
  dark each get their own value instead of both getting whichever appearance the
  app launched into. The gauge track is `quaternaryLabelColor`, which inverts
  with the appearance.
- **The palette enforces its own contrast floor.** Muting and legibility pull in
  opposite directions and legibility wins: `muted()` blends toward the neutral
  that is away from the background and then keeps going until the result clears
  WCAG's 3:1 for a graphical object against the track. Writing this note was
  what prompted measuring it, and measuring it found the light appearance
  failing everywhere — the health badge at 1.25:1. `docs/contrast.md` has the
  table and `swift test/contrast/contrast.swift` fails the build's conscience if
  it slips again.
- **Increase contrast** drops the muting entirely. That setting is the user
  saying they do not want de-emphasis, and muting is exactly that.
- **The type scale is relative to `NSFont.systemFontSize`**, not absolute, so a
  Mac with a larger system font gets a proportionally larger dropdown.
- **It does not follow the Accessibility text size.** Measured 2026-09-21:
  `NSFont.systemFont(ofSize:)` returns the size it is asked for whatever that
  setting is; `NSFont.preferredFont(forTextStyle:)` is the API that follows it,
  and adopting it means re-deriving every metric in the grid above from what it
  returns. A known gap. Naming the scale in one place is what makes it a day's
  work rather than an archaeology project.
