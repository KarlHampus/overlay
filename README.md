# overlay

A Night Shift style screen filter for Windows, driven from the command line.

```bash
overlay night
```

It shifts the display white point across the whole desktop, the way iOS Night
Shift and Windows Night light do. Nothing is installed, no driver or gamma ramp
is touched, and no registry key is written.

## Install

Nothing to install — `overlay.cmd` runs from wherever you cloned it. To call it
by name from any prompt, append the folder to your **user** `PATH`, in
PowerShell:

```powershell
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';C:\programming\claude\overlay', 'User')
```

Open a new terminal afterwards.

> Don't use `setx PATH "%PATH%;..."` for this. `%PATH%` is the *combined*
> machine + user path, `setx` writes it to the user path, and the result both
> duplicates every machine entry into your user path and silently truncates at
> 1024 characters. The line above only ever touches the user portion.

`overlay.cmd` works from cmd.exe, PowerShell, Windows Terminal and the Win+R
Run box; `overlay.ps1` can be called directly too.

## Usage

| Command | Effect |
| --- | --- |
| `overlay night [strength]` | slight dim + strong warmth — the iOS Night Shift feel |
| `overlay warm [strength]` | warmth only, no dimming |
| `overlay dark [strength]` | dimming only, no colour shift (`dim` is a synonym) |
| `overlay sunset [strength]` | stronger dim + full warmth |
| `overlay sleep [strength]` | heaviest dim + full warmth |
| `overlay custom -Dim N -Warm N` | exact control: dim 0-85, warm 0-100 |
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

### Engines

`-Engine matrix` (default) shifts the display white point — the Night Shift
approach, described below. `-Engine overlay` uses the older translucent-window
approach, which lifts blacks; it exists as a fallback and for the `-Tint`
option, which only applies there:

```bash
overlay warm 35 -Engine overlay -Tint FF6A00
```

## Claude skill

[`skill/SKILL.md`](skill/SKILL.md) teaches Claude Code to drive this, so "turn
dark on" or "the screen is too bright" in any session applies the right preset.
Install it at the user level so it works in every project:

```bash
robocopy skill "%USERPROFILE%\.claude\skills\screen-overlay" SKILL.md
```

## How it works

Night Shift is not an overlay. It adjusts the display's **white point** — a
per-channel gain applied in the display pipeline, shifting the correlated colour
temperature from roughly 6500K down to about 2700K at its warmest. The key
property is that it *multiplies*: a black pixel times any gain is still black,
so only the lit parts of the screen warm up.

`overlay` does the same thing through the Win32 Magnification API.
`MagSetFullscreenColorEffect` applies a 5x5 colour matrix to the entire desktop;
a diagonal matrix is exactly a per-channel gain:

```
[ r 0 0 0 0 ]      r,g,b  = white point for the target temperature,
[ 0 g 0 0 0 ]               normalised so 6500K is exactly 1,1,1
[ 0 0 b 0 0 ]               then scaled by (1 - dim)
[ 0 0 0 1 0 ]
[ 0 0 0 0 1 ]
```

Temperature comes from Tanner Helland's blackbody approximation, normalised
against the neutral white point so `warm 0` is a true identity — no cast on an
untinted screen. `dim` is a straight multiply on all three channels, so it is
real dimming rather than a grey veil over the top.

Strength maps linearly onto temperature: `0` = 6500K, `100` = 2700K.

### The overlay engine (`-Engine overlay`)

The original approach, kept as a fallback: a click-through, always-on-top
layered window carrying `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
WS_EX_NOACTIVATE`. `dim` and `warm` collapse into the single colour + alpha one
layered window can express:

```
alpha  = 1 - (1 - w)(1 - d)
colour = amber * (1 - d) * w / alpha
```

It composites **source-over, not multiply**, so amber over a black screen makes
it glow faintly amber. That is why a dark desktop looks muddy under it, and why
it is no longer the default. The worker falls back to it automatically if the
magnification API is unavailable.

A single background `powershell.exe` holds whichever engine is active. Instance
tracking and shutdown use a named mutex and a named event, so `overlay off` from
any terminal closes it cleanly. `off` also resets the colour matrix directly,
so a crashed worker can never leave the screen stuck tinted. State lives in
`%LOCALAPPDATA%\ScreenOverlay\state.json`; worker errors land in `error.log`
next to it.

## Limits worth knowing

- **Windows' own Color filters and Magnifier use the same slot.** The fullscreen
  colour effect is one system-wide matrix, so turning on Settings →
  Accessibility → Colour filters, or running Magnifier, will override the tint
  (and vice versa). Windows Night light is a separate mechanism and composes
  fine on top.
- **Exclusive-fullscreen games** may bypass the effect, and the secure desktop
  (UAC prompts, Ctrl+Alt+Del, lock screen) is never affected.
- **HDR displays** apply colour transforms differently; results vary.
- Requires Windows 8+ and a WDDM display driver — i.e. anything modern. Older
  or unusual setups fall back to the overlay engine automatically.
- The tint does not survive a reboot. For that, put a shortcut to
  `overlay.cmd night` in `shell:startup`.
- Takes ~3 s from command to visible change, which is two PowerShell cold
  starts, not the tinting itself.

## Why not gamma ramps?

`SetDeviceGammaRamp` is the other classic approach (f.lux, Redshift). Windows
rejects ramps that deviate too far from linear unless
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM\GdiIcmGammaRange` is
set to 256 — a machine-wide registry write needing admin, which f.lux does at
install time. It also stops working when HDR is enabled. The magnification
matrix gets the same multiply semantics with no registry change and no
elevation, so that is what this uses.
