# overlay

A Night Shift style screen filter for Windows, driven from the command line.

```bash
overlay night
```

It paints a click-through, always-on-top layered window across every monitor.
Everything underneath gets darker and/or warmer. Nothing is installed, no
driver or gamma ramp is touched, and no registry key is written.

## Install

Put this folder on your `PATH` so `overlay` works from any prompt:

```bash
setx PATH "%PATH%;C:\programming\claude\overlay"
```

Open a new terminal afterwards. `overlay.cmd` works from cmd.exe, PowerShell,
Windows Terminal and the Run box; `overlay.ps1` can be called directly too.

## Usage

| Command | Effect |
| --- | --- |
| `overlay night [strength]` | slight dim + strong warmth — the iOS Night Shift feel |
| `overlay warm [strength]` | warmth only, no dimming |
| `overlay dark [strength]` | dimming only, no colour shift (`dim` is a synonym) |
| `overlay sunset [strength]` | stronger dim + full warmth |
| `overlay sleep [strength]` | heaviest dim + full warmth |
| `overlay custom -Dim N -Warm N` | exact control, each 0-92 |
| `overlay more` / `overlay less` | nudge the current strength by 10 |
| `overlay off` | remove the overlay |
| `overlay` / `overlay status` | show what is currently applied |
| `overlay help` | built-in help |

### Strength

Any number `0-100`, default `50`, positional or via `-s`. Named levels work
anywhere a number does:

| Level | Value |
| --- | --- |
| `faint`, `subtle` | 15 |
| `low`, `light` | 25 |
| `medium`, `med`, `mid` | 50 |
| `strong`, `high` | 75 |
| `max`, `full` | 100 |
| `off` | 0 |

```bash
overlay dark strong
```

A bare strength implies the `night` preset, so `overlay medium` and
`overlay 30` both work. `overlay more 25` steps by 25 instead of 10. Strength
`0` turns the overlay off.

Re-running any command replaces the current overlay, so `overlay sunset 80`
while `night` is active just swaps it — no `off` needed in between.

```bash
overlay warm 35 -Tint FF6A00
```

`-Tint` takes any 6-digit hex colour; the default is `FF9329` (candle amber).

## Claude skill

[`skill/SKILL.md`](skill/SKILL.md) teaches Claude Code to drive this, so "turn
dark on" or "the screen is too bright" in any session applies the right preset.
Install it at the user level so it works in every project:

```bash
robocopy skill "%USERPROFILE%\.claude\skills\screen-overlay" SKILL.md
```

## How it works

`Dim` and `Warm` are two conceptual layers — black at `d`, amber at `w` — that
get collapsed into the single colour + alpha one layered window can express:

```
alpha  = 1 - (1 - w)(1 - d)
colour = amber * (1 - d) * w / alpha
```

The window carries `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
WS_EX_NOACTIVATE`, so clicks pass straight through, it never takes focus and it
stays out of Alt+Tab. A 1 s timer re-asserts topmost (other windows can steal
the top of the z-order) and re-fits the bounds when a monitor or resolution
changes. The process is per-monitor DPI aware so it lands on real pixels across
mixed-scaling setups.

A single background `powershell.exe` holds the overlay. Instance tracking and
shutdown use a named mutex and a named event, so `overlay off` from any
terminal closes it cleanly. State lives in
`%LOCALAPPDATA%\ScreenOverlay\state.json`; worker crashes land in `error.log`
next to it.

## Limits worth knowing

- **Warmth lifts blacks.** A layered window composites source-over, not
  multiply, so an amber layer over a black screen makes it glow faintly amber
  rather than staying black. `dim` is unaffected. On dark themes, prefer a
  lower `warm` value, or a darker `-Tint` such as `8B4A00`, which warms whites
  while lifting blacks less. Windows' own Night light applies a colour
  transform in the display pipeline and does not have this problem — the two
  compose fine if you want Night light for colour and this for dimming.
- **Exclusive-fullscreen games and the secure desktop** (UAC prompts,
  Ctrl+Alt+Del, the lock screen) render outside the desktop compositor, so the
  overlay does not cover them.
- The overlay does not survive a reboot. For that, add
  `overlay.cmd night` to `shell:startup`.
