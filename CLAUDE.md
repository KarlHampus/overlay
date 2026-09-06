# CLAUDE.md

## What this is

`overlay` — a command-line screen dimmer / warm tint for Windows, in the spirit
of iOS Night Shift. See [README.md](README.md) for user-facing docs.

## Layout

| File | Role |
| --- | --- |
| `overlay.ps1` | Everything: CLI front end **and** the background worker (`-Worker`), plus the embedded C# `ScreenTint` (matrix engine) and `ScreenOverlay` (overlay engine) classes. |
| `overlay.cmd` | Thin wrapper so `overlay ...` works from cmd.exe / Run box. CRLF line endings — keep them. |
| `skill/SKILL.md` | Claude skill that drives the CLI. The installed copy lives at `~/.claude/skills/screen-overlay/SKILL.md`; keep the two in sync when the command surface changes. |
| `.gitattributes` | Pins `*.cmd` to CRLF on checkout. |

There is no build step and no dependency beyond Windows PowerShell 5.1, which
ships with Windows.

## Architecture

One script, two roles, selected by the `-Worker` switch:

- **Front end** (no `-Worker`): parses the command, resolves preset + strength
  into `dim`/`warm` percentages, stops any running overlay, spawns the worker
  detached via `Start-Process -WindowStyle Hidden`, waits for the mutex to
  appear, writes state.
- **Worker** (`-Worker`): takes the mutex, resets the stop event, then runs
  whichever engine `-Engine` selected.

The worker is always launched under **Windows PowerShell**
(`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`), never `pwsh`,
so the background process gets .NET Framework WinForms regardless of which
shell the user invoked from.

### IPC

| Name | Purpose |
| --- | --- |
| `Local\ScreenOverlay.Running.v1` (mutex) | Held by the worker for its lifetime. Presence = "overlay is on". |
| `Local\ScreenOverlay.Stop.v1` (manual-reset event) | Front end sets it; the worker's 1 s timer sees it and closes. |
| `%LOCALAPPDATA%\ScreenOverlay\state.json` | Last applied settings, for `status` and `more`/`less`. |
| `%LOCALAPPDATA%\ScreenOverlay\error.log` | Worker exceptions — the only way to see them, since it runs hidden. |

The worker resets the stop event on startup, so a stale set event cannot kill a
fresh instance.

### Engines

Two, selected by `-Engine`, defaulting to **matrix**.

**matrix** — `MagSetFullscreenColorEffect` (Magnification.dll) applies a 5x5
colour matrix to the whole desktop. A diagonal matrix is a per-channel gain,
which is what iOS Night Shift and Windows Night light do: a *multiply*, so
black stays black. `Get-TintGains` maps warm% onto 6500K..2700K via
`Get-KelvinRgb` (Tanner Helland blackbody approximation), normalises against
the 6500K white point so `warm 0` is exactly identity, then scales all three
channels by `1 - dim`. No window, no message loop — the worker calls
`MagInitialize`, applies, and blocks on `$stopEvent.WaitOne(2000)`, re-applying
each timeout because a resolution change or another magnifier client can drop
the effect.

`overlay off` calls `Reset-ScreenTint` unconditionally, from the *front end*.
This is the safety valve: a worker killed with the matrix applied would
otherwise leave the desktop stuck tinted with nothing running to undo it.

If `MagInitialize`/`Apply` fails, the worker logs and falls through to the
overlay engine rather than doing nothing.

The applied transform is `out = in * gain + translation`, diagonal and
translation row (indices 20-22) respectively. Three ways to move it:

| Knob | Pivot | Black | Matrix |
| --- | --- | --- | --- |
| `-Dim` negative (`light`) | black | stays black | gain > 1, translation 0 |
| `-Contrast` positive | `-Pivot` p, default 0.5 | stays black | gain `c`, translation `p(1-c)` |
| `-Lift` positive | - | raised | translation > 0 |

`light` is deliberately a **pure gain, no lift**. An earlier cut added lift so
dark UI would lighten too; it works but goes hazy and loses contrast, and the
user asked for contrast instead. Do not reintroduce lift into that preset.

`-Pivot` is a position on the tone curve, not an amount, so `more`/`less` must
*not* scale it - only Dim/Warm/Contrast/Lift scale with strength. It is also a
no-op without `-Contrast` (translation is `p(1-c)`, which is 0 when c = 1), and
the front end says so rather than silently doing nothing.

Verified by reading the live matrix back with `MagGetFullscreenColorEffect` and
solving `in * gain + translation = in` for the fixed point:
`light medium` -> 1.22 / 0; `-Contrast 30` -> 1.3 / -0.15, fixed at 50%;
`-Pivot 10` -> 1.3 / -0.03, fixed at 10%; `-Pivot 90` -> 1.3 / -0.27, fixed
at 90%.

**overlay** — the original layered window. Kept because it is the fallback, and
because `-Tint` only means anything there. It cannot brighten at all, so the
front end rejects a negative dim or any lift on that engine.

### The blend (overlay engine only)

`dim` (black layer) and `warm` (amber layer) are collapsed into the one colour +
alpha a layered window can express, in `Get-BlendedLayer`:

```
alpha  = 1 - (1 - w)(1 - d)
colour = tint * (1 - d) * w / alpha
```

Verified against a real screen capture: `night 40` over a black desktop
predicted and measured `(81, 47, 13)`.

### Strength

`$Strength` is a **string** parameter (aliased `-s`) so it can take either a
number or a named level from `$StrengthWords`; `Resolve-Strength` normalises it
to an int, and `$strengthNum` is the only value used after that point. Do not
reintroduce `[int]$Strength` — the named levels depend on the string type.

Measuring the effect by screen capture is unreliable on a live desktop: content
repainting between the on and off captures will masquerade as an effect. Bracket
every reading with an OFF reading and discard the result unless the two OFF
readings agree, or just read the matrix back instead.

`Test-StrengthToken` is what lets a bare `overlay 30` / `overlay medium` fall
through to the `night` preset. **Presets are checked first**, so a name that is
both never resolves to the level - `light` used to be a strength word (25) and
silently swallowed `overlay light`, which is why it is no longer one.

`$Dim`, `$Warm` and `$Lift` use `[int]::MinValue` as their "not supplied"
sentinel, not `-1`, because a negative `-Dim` is a real value meaning brighten.
Do not go back to `-lt 0` checks on them.

## Gotchas

- **`Timer` is ambiguous** in the embedded C# — `System.Threading` and
  `System.Windows.Forms` are both imported. Always write
  `System.Windows.Forms.Timer` in full.
- **`AutoScaleMode = None`** is required. The process is per-monitor DPI aware
  (`SetProcessDpiAwarenessContext(-4)`), and without this WinForms rescales the
  bounds out from under us.
- Bounds come from `GetSystemMetrics(SM_*VIRTUALSCREEN)` and are re-checked on
  the timer rather than via `SystemEvents.DisplaySettingsChanged`, which keeps
  the worker free of a `Microsoft.Win32.SystemEvents` dependency.
- Topmost must be **re-asserted on a timer**; other windows take the top of the
  z-order otherwise.
- Warm tint lifts blacks **in the overlay engine** — layered windows composite
  source-over, not multiply. This is inherent to that approach and is why the
  matrix engine is now the default. Do not "fix" it in the overlay path.
- The magnification colour effect is a single system-wide slot. Windows'
  Colour filters (Settings → Accessibility) and Magnifier use the same one and
  will clobber it, and vice versa. Night light is separate and composes.
- Gamma ramps (`SetDeviceGammaRamp`) were the other candidate and were
  rejected: Windows clamps ramps unless `GdiIcmGammaRange` is set to 256 in
  HKLM, which needs admin and a machine-wide registry write, and it breaks
  under HDR.
- Heredoc-writing `overlay.ps1` from bash fails on the nested quoting (`@'...'@`
  around C#). Use the Write/Edit tools for that file.
- **Do not bother caching the compiled C# as a DLL.** Tried and measured: cold
  vs cached time-to-paint was 2.8 s both ways. The latency is two
  `powershell.exe` cold starts (front end + worker), not `csc`. A cache only
  adds a stale-assembly failure mode.
- The front end returns as soon as the worker takes the mutex, which happens
  *before* `Add-Type`. So timing the command does not measure time-to-paint —
  poll a screen pixel for that.
