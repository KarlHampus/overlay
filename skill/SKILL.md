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

`overlay` paints a click-through, always-on-top tinted window across every
monitor. It is installed at `C:\programming\claude\overlay\overlay.cmd`.

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
overlay custom -Dim 40 -Warm 55    # exact control, each 0-92
overlay more               # +10 strength (or 'overlay more 25')
overlay less               # -10 strength
overlay off                # remove it
overlay status             # what is currently applied
```

`-Tint <hex>` changes the tint colour (default `FF9329`, candle amber).

## Choosing for the user

- "too bright" / "darker" / "turn dark on" → `dark` (dimming only)
- "night mode" / "warmer" / "less blue" → `night`
- "way too bright, it's late" → `sunset` or `sleep`
- "a bit more/less" → `more` / `less`, not a fresh preset

Re-running any command replaces the current overlay, so switching presets needs
no `off` first. Report the line the command prints — it states the resolved dim
and warm percentages.

## Limits to mention if relevant

- Warm tint lifts blacks: a layered window composites source-over, not
  multiply, so amber over a black screen makes it glow faintly. `dark` has no
  such effect. On dark themes prefer a lower warm value or a darker
  `-Tint` such as `8B4A00`.
- It cannot cover exclusive-fullscreen games or the secure desktop (UAC
  prompts, Ctrl+Alt+Del, lock screen).
- It does not survive a reboot; a shortcut in `shell:startup` fixes that.
- Takes ~3 s from command to visible change (two PowerShell cold starts).
