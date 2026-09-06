---
name: screen-overlay
description: >
  Dim or warm the Windows screen with a Night Shift style overlay, from the
  command line. Use when the user asks to make the screen darker, dimmer,
  warmer, less blue, or easier on the eyes; says "turn dark on", "night mode",
  "night shift", "dim the screen", "warm the screen", "too bright",
  "screen is burning my eyes"; asks to turn that back off or brighten up; or
  asks to nudge it ("a bit darker", "less warm"). Windows only.
---

# Screen overlay

`overlay` shifts the display white point across the whole desktop, the way iOS
Night Shift does — a per-channel multiply, so blacks stay black and dark themes
look right. It is installed at `C:\programming\claude\overlay\overlay.cmd`.

Run it with the PowerShell tool. If the folder is on PATH, plain `overlay ...`
works; otherwise call the full path.

```
C:\programming\claude\overlay\overlay.cmd <preset> [strength]
```

## Presets

| Preset | Effect |
| --- | --- |
| `night` | slight dim + strong warmth — the default "night shift" feel |
| `warm` | warmth only, no dimming |
| `dark` (or `dim`) | dimming only, no colour shift |
| `sunset` | stronger dim + full warmth |
| `sleep` | heaviest dim + full warmth |
| `light` (or `bright`) | the opposite — brightens the screen |

## Strength

`0-100`, default `50`. Pass it positionally or as `-s`. Named levels also work
anywhere a number does:

`faint`/`subtle` 15 · `low`/`light` 25 · `medium`/`med`/`mid` 50 ·
`strong`/`high` 75 · `max`/`full` 100 · `off` 0

## Commands

```
overlay night              # default preset at strength 50
overlay dark strong        # dimming only, 75
overlay night -s 65        # explicit strength flag
overlay medium             # bare strength => night preset
overlay 30                 # bare number => night preset
overlay light strong       # brighten
overlay custom -Dim -20 -Contrast 25   # brighter and punchier
overlay custom -Dim 40 -Warm 55    # dim -60..85, warm 0-100, contrast -80..100
overlay more               # +10 strength (or 'overlay more 25')
overlay less               # -10 strength
overlay off                # remove it
overlay status             # what is currently applied
```

Warmth is a real colour temperature: strength `0` = 6500K (neutral), `100` =
2700K (iOS's warmest). `dark` is a pure neutral multiply with no colour shift.

`light` goes the other way: a pure gain above 1, pivoted at black, so black
stays black and only lit pixels come up.

`-Contrast N` (-80..100) pivots about mid-grey instead — darks hold, brights
push up, black still stays black. `-Lift N` raises black off zero, which does
lighten a dark UI but goes hazy; prefer `-Contrast`. Both need the matrix
engine.

`-Engine overlay` switches to the legacy translucent-window approach, which
lifts blacks. Only use it if the default visibly fails. `-Tint <hex>` applies
to that engine only.

## Choosing for the user

- "too bright" / "darker" / "turn dark on" → `dark` (dimming only)
- "too dark" / "brighter" / "lighter" / "I can't read this" → `light`
- "washed out" / "more punch" / "more contrast" → `custom -Contrast 25`
- "night mode" / "warmer" / "less blue" → `night`
- "way too bright, it's late" → `sunset` or `sleep`
- "a bit more/less" → `more` / `less`, not a fresh preset

Re-running any command replaces the current overlay, so switching presets needs
no `off` first. Report the line the command prints — it states the resolved dim
and warm percentages.

## Limits to mention if relevant

- Windows' Colour filters (Settings → Accessibility) and Magnifier use the same
  system-wide colour-effect slot and will override the tint, and vice versa.
  Windows Night light is separate and composes fine on top.
- Exclusive-fullscreen games may bypass it; the secure desktop (UAC prompts,
  Ctrl+Alt+Del, lock screen) is never affected.
- Does not survive a reboot; a shortcut in `shell:startup` fixes that.
- Takes ~3 s from command to visible change (two PowerShell cold starts).
- If the screen is ever left tinted unexpectedly, `overlay off` resets the
  colour matrix directly and always recovers it.
