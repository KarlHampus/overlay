<#
.SYNOPSIS
    Screen tint / dimmer overlay for Windows - a Night Shift style filter driven from the command line.

.DESCRIPTION
    Paints a click-through, always-on-top layered window over every monitor. The window is a
    solid colour at partial opacity, so it darkens and/or warms everything underneath without
    touching display drivers, gamma ramps or the registry.

    Two independent knobs are blended into that single layer:
      Dim   - how much black is mixed in (0-92)
      Warm  - how much amber tint is mixed in (0-92)

.EXAMPLE
    overlay night           # balanced warm + slight dim (default strength 50)
.EXAMPLE
    overlay sunset 80       # heavy evening filter
.EXAMPLE
    overlay custom -Dim 25 -Warm 60
.EXAMPLE
    overlay off
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mode = 'status',

    [Parameter(Position = 1)]
    [Alias('s', 'Level')]
    [string]$Strength = '',

    [int]$Dim = -1,
    [int]$Warm = -1,
    [string]$Tint = 'FF9329',
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'

$MutexName = 'Local\ScreenOverlay.Running.v1'
$StopName  = 'Local\ScreenOverlay.Stop.v1'
$StateDir  = Join-Path $env:LOCALAPPDATA 'ScreenOverlay'
$StateFile = Join-Path $StateDir 'state.json'
$LogFile   = Join-Path $StateDir 'error.log'

# preset = @(dim factor, warm factor), each multiplied by Strength (0-100)
$Presets = @{
    'night'  = @(0.30, 0.90)
    'warm'   = @(0.00, 0.90)
    'dim'    = @(0.85, 0.00)
    'dark'   = @(0.85, 0.00)
    'sunset' = @(0.55, 1.00)
    'sleep'  = @(0.70, 1.00)
}

# Named strength levels, usable anywhere a 0-100 number is.
$StrengthWords = [ordered]@{
    'off'    = 0
    'faint'  = 15
    'subtle' = 15
    'low'    = 25
    'light'  = 25
    'medium' = 50
    'med'    = 50
    'mid'    = 50
    'strong' = 75
    'high'   = 75
    'max'    = 100
    'full'   = 100
}

# ---------------------------------------------------------------- helpers ---

function Clamp([double]$v, [double]$lo, [double]$hi) {
    if ($v -lt $lo) { return $lo }
    if ($v -gt $hi) { return $hi }
    return $v
}

# Accepts "0".."100" or a named level such as low / medium / strong.
function Resolve-Strength([string]$value, [int]$fallback) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $fallback }
    $v = $value.Trim().ToLowerInvariant()
    if ($StrengthWords.Contains($v)) { return [int]$StrengthWords[$v] }
    $n = 0
    if ([int]::TryParse($v, [ref]$n)) { return [int](Clamp $n 0 100) }
    throw "Strength must be 0-100 or one of: $(($StrengthWords.Keys) -join ', ') (got '$value')."
}

function Test-StrengthToken([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    $v = $value.Trim().ToLowerInvariant()
    if ($StrengthWords.Contains($v)) { return $true }
    $n = 0
    return [int]::TryParse($v, [ref]$n)
}

function ConvertFrom-HexColour([string]$hex) {
    $h = $hex.TrimStart('#')
    if ($h -notmatch '^[0-9A-Fa-f]{6}$') {
        throw "Tint must be a 6-digit hex colour such as FF9329 (got '$hex')."
    }
    return @(
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16)
    )
}

# Collapse a black layer (dim) and an amber layer (warm) into the single
# colour + alpha that one layered window can express:
#   screen -> amber at w -> black at d
#   alpha  = 1 - (1-w)(1-d)
#   colour = amber * (1-d) * w / alpha
function Get-BlendedLayer([double]$dimPct, [double]$warmPct, [int[]]$tintRgb) {
    $d = (Clamp $dimPct 0 92) / 100.0
    $w = (Clamp $warmPct 0 92) / 100.0
    $a = 1.0 - (1.0 - $w) * (1.0 - $d)
    if ($a -lt 0.005) { return $null }
    $k = (1.0 - $d) * $w / $a
    return [pscustomobject]@{
        R       = [int][Math]::Round($tintRgb[0] * $k)
        G       = [int][Math]::Round($tintRgb[1] * $k)
        B       = [int][Math]::Round($tintRgb[2] * $k)
        Opacity = [Math]::Round($a, 4)
    }
}

function Test-OverlayRunning {
    try {
        $m = [System.Threading.Mutex]::OpenExisting($MutexName)
        $m.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Stop-Overlay {
    if (-not (Test-OverlayRunning)) { return $false }
    $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $StopName)
    [void]$ev.Set()
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    while ((Test-OverlayRunning) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    $ev.Dispose()
    return $true
}

function Save-State($state) {
    if (-not (Test-Path $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir -Force) }
    $state | ConvertTo-Json -Compress | Set-Content -Path $StateFile -Encoding UTF8
}

function Get-State {
    if (Test-Path $StateFile) {
        try { return Get-Content $StateFile -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Start-OverlayWorker([double]$dimPct, [double]$warmPct, [string]$tintHex) {
    # Always run the worker under Windows PowerShell: WinForms on .NET Framework
    # is present on every Windows box, so the background process never depends on
    # which shell the user launched from.
    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $hostExe)) { $hostExe = 'powershell.exe' }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"' + $PSCommandPath + '"'),
        '-Worker',
        '-Dim', ([int][Math]::Round($dimPct)),
        '-Warm', ([int][Math]::Round($warmPct)),
        '-Tint', $tintHex
    )
    Start-Process -FilePath $hostExe -ArgumentList $argList -WindowStyle Hidden | Out-Null
}

function Show-Status {
    $running = Test-OverlayRunning
    $state = Get-State
    if ($running -and $state) {
        Write-Host 'overlay: ON' -ForegroundColor Green -NoNewline
        Write-Host ("  preset={0} strength={1} dim={2}% warm={3}% tint=#{4}" -f `
            $state.Mode, $state.Strength, $state.Dim, $state.Warm, $state.Tint)
    } elseif ($running) {
        Write-Host 'overlay: ON' -ForegroundColor Green
    } else {
        Write-Host 'overlay: off' -ForegroundColor DarkGray
    }
}

function Show-Help {
    $text = @"
overlay - screen dimmer / warm tint for Windows

USAGE
  overlay <preset> [strength]     apply a preset
  overlay <preset> -s <strength>  same thing, named flag
  overlay <strength>              night preset at that strength
  overlay custom -Dim N -Warm N   exact control, each 0-92
  overlay more | less [step]      nudge the current strength (default step 10)
  overlay off                     remove the overlay
  overlay status                  show current state (also the bare 'overlay')
  overlay help                    this text

PRESETS
  night     slight dim + strong warmth   (the iOS Night Shift feel)
  warm      warmth only, no dimming
  dim/dark  dimming only, no colour shift
  sunset    stronger dim + full warmth
  sleep     heaviest dim + full warmth

STRENGTH
  Any number 0-100 (default 50), or a named level:
    faint/subtle 15   low/light 25   medium/med/mid 50
    strong/high  75   max/full 100   off 0

OPTIONS
  -s, -Strength <n|level>   strength, as above
  -Tint <hex>               tint colour, default FF9329 (candle amber).
                            FF6A00 is a deeper orange, FFB870 a subtler one.

EXAMPLES
  overlay night
  overlay night -s 65
  overlay dark strong
  overlay medium
  overlay sunset 80
  overlay warm 35 -Tint FF6A00
  overlay custom -Dim 40 -Warm 55
  overlay off

NOTES
  The overlay is click-through and covers every monitor, taskbar included.
  It cannot paint over exclusive-fullscreen games or the secure desktop
  (UAC prompts, Ctrl+Alt+Del) - those are drawn outside the desktop compositor.
"@
    Write-Host $text
}

# ----------------------------------------------------------- worker branch ---

if ($Worker) {
    try {
        $createdNew = $false
        $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
        if (-not $createdNew) { exit 0 }   # another overlay already owns the screen

        $stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $StopName)
        [void]$stopEvent.Reset()

        $rgb = ConvertFrom-HexColour $Tint
        $layer = Get-BlendedLayer ([double]$Dim) ([double]$Warm) $rgb
        if ($null -eq $layer) { exit 0 }

        $source = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class ScreenOverlay : Form
{
    const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77;
    const int SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

    const int WS_EX_LAYERED     = 0x00080000;
    const int WS_EX_TRANSPARENT = 0x00000020;   // click-through
    const int WS_EX_TOOLWINDOW  = 0x00000080;   // keep out of Alt+Tab
    const int WS_EX_NOACTIVATE  = 0x08000000;

    static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010;

    [DllImport("user32.dll")] static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    readonly EventWaitHandle _stop;
    readonly System.Windows.Forms.Timer _tick = new System.Windows.Forms.Timer();
    Rectangle _lastBounds;

    public static void Run(int r, int g, int b, double opacity, EventWaitHandle stop)
    {
        // Per-monitor DPI awareness keeps the window on real pixels across
        // mixed-scaling multi-monitor setups; fall back on older builds.
        try { if (!SetProcessDpiAwarenessContext(new IntPtr(-4))) SetProcessDPIAware(); }
        catch { try { SetProcessDPIAware(); } catch { } }
        Application.Run(new ScreenOverlay(Color.FromArgb(r, g, b), opacity, stop));
    }

    ScreenOverlay(Color colour, double opacity, EventWaitHandle stop)
    {
        _stop = stop;
        AutoScaleMode = AutoScaleMode.None;      // do not let WinForms rescale our bounds
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = colour;
        Opacity = opacity;
        Text = "ScreenOverlay";
        ApplyBounds();

        _tick.Interval = 250;   // keeps 'off' feeling instant
        _tick.Tick += OnTick;
        _tick.Start();
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    static Rectangle VirtualScreen()
    {
        return new Rectangle(
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN));
    }

    void ApplyBounds()
    {
        _lastBounds = VirtualScreen();
        Bounds = _lastBounds;
    }

    void OnTick(object sender, EventArgs e)
    {
        if (_stop != null && _stop.WaitOne(0))
        {
            _tick.Stop();
            Close();
            return;
        }

        // Monitor added/removed, or resolution changed.
        Rectangle now = VirtualScreen();
        if (now != _lastBounds) { ApplyBounds(); }

        // Other windows can claim the top of the z-order; take it back.
        SetWindowPos(Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}
'@

        # Measured: caching this as a prebuilt DLL saves nothing - the ~2.8 s
        # from keypress to paint is two powershell.exe cold starts, not csc.
        Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing'

        [ScreenOverlay]::Run($layer.R, $layer.G, $layer.B, [double]$layer.Opacity, $stopEvent)

        [void]$stopEvent.Reset()
        $stopEvent.Dispose()
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    } catch {
        if (-not (Test-Path $StateDir)) { [void](New-Item -ItemType Directory -Path $StateDir -Force) }
        $entry = '[{0}] {1}{2}{3}' -f (Get-Date -Format s), $_.Exception.Message, [Environment]::NewLine, $_.ScriptStackTrace
        Add-Content -Path $LogFile -Value $entry -Encoding UTF8
        exit 1
    }
    exit 0
}

# --------------------------------------------------------------- dispatch ---

$requested = $Mode.ToLowerInvariant()
switch ($requested) {
    'on'     { $requested = 'night' }
    'stop'   { $requested = 'off' }
    'none'   { $requested = 'off' }
    '-h'     { $requested = 'help' }
    '--help' { $requested = 'help' }
    '/?'     { $requested = 'help' }
}

if ($requested -eq 'help')   { Show-Help;   exit 0 }
if ($requested -eq 'status') { Show-Status; exit 0 }

if ($requested -eq 'off') {
    if (Stop-Overlay) { Write-Host 'overlay: off' -ForegroundColor DarkGray }
    else              { Write-Host 'overlay: already off' -ForegroundColor DarkGray }
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    exit 0
}

# "overlay 40" / "overlay medium" - a bare strength implies the night preset.
if (Test-StrengthToken $requested) {
    if ([string]::IsNullOrWhiteSpace($Strength)) { $Strength = $requested }
    $requested = 'night'
}

$strengthNum = 0

if ($requested -eq 'more' -or $requested -eq 'less') {
    $state = Get-State
    $baseMode = 'night'
    $baseStrength = 50
    if ($state -and (Test-OverlayRunning)) {
        $baseMode = $state.Mode
        $baseStrength = [int]$state.Strength
        $Tint = $state.Tint
    }
    # "overlay more 25" steps by 25 instead of the default 10.
    $step = Resolve-Strength $Strength 10
    if ($requested -eq 'less') { $step = -$step }

    $requested = $baseMode
    $strengthNum = [int](Clamp ($baseStrength + $step) 0 100)

    # A custom setting has no preset curve to re-evaluate, so scale the two
    # knobs it was built from by the same ratio the strength moved.
    if ($requested -eq 'custom' -and $strengthNum -gt 0) {
        if ($state -and $baseStrength -gt 0) {
            $ratio = $strengthNum / [double]$baseStrength
            $Dim  = [int][Math]::Round(([double]$state.Dim) * $ratio)
            $Warm = [int][Math]::Round(([double]$state.Warm) * $ratio)
        } else {
            $requested = 'night'
        }
    }

    $Strength = [string]$strengthNum
}

# Resolve dim / warm ----------------------------------------------------------
$dimPct  = 0.0
$warmPct = 0.0

if ($requested -eq 'custom') {
    if ($Dim -lt 0 -and $Warm -lt 0) {
        Write-Host 'custom needs -Dim and/or -Warm, e.g. overlay custom -Dim 25 -Warm 60' -ForegroundColor Yellow
        exit 1
    }
    if ($Dim  -lt 0) { $dimPct  = 0.0 } else { $dimPct  = [double]$Dim }
    if ($Warm -lt 0) { $warmPct = 0.0 } else { $warmPct = [double]$Warm }
    $strengthNum = [int][Math]::Round([Math]::Max($dimPct, $warmPct))
} elseif ($Presets.ContainsKey($requested)) {
    try {
        $strengthNum = Resolve-Strength $Strength 50
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        exit 1
    }
    if ($strengthNum -le 0) {
        [void](Stop-Overlay)
        if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
        Write-Host 'overlay: off' -ForegroundColor DarkGray
        exit 0
    }
    $factors = $Presets[$requested]
    $dimPct  = $factors[0] * $strengthNum
    $warmPct = $factors[1] * $strengthNum
} else {
    Write-Host "Unknown command '$Mode'. Try: overlay help" -ForegroundColor Yellow
    exit 1
}

$dimPct  = Clamp $dimPct 0 92
$warmPct = Clamp $warmPct 0 92

$rgb = ConvertFrom-HexColour $Tint
$layer = Get-BlendedLayer $dimPct $warmPct $rgb
if ($null -eq $layer) {
    [void](Stop-Overlay)
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    Write-Host 'overlay: off (nothing to apply)' -ForegroundColor DarkGray
    exit 0
}

[void](Stop-Overlay)
Start-OverlayWorker $dimPct $warmPct ($Tint.TrimStart('#').ToUpperInvariant())

$deadline = [DateTime]::UtcNow.AddSeconds(15)
while (-not (Test-OverlayRunning) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
}

if (Test-OverlayRunning) {
    Save-State ([pscustomobject]@{
        Mode     = $requested
        Strength = $strengthNum
        Dim      = [int][Math]::Round($dimPct)
        Warm     = [int][Math]::Round($warmPct)
        Tint     = $Tint.TrimStart('#').ToUpperInvariant()
        Opacity  = $layer.Opacity
        Started  = (Get-Date).ToString('s')
    })
    Write-Host ('overlay: {0} @ {1}  (dim {2}%, warm {3}%)' -f $requested, $strengthNum, [int]$dimPct, [int]$warmPct) -ForegroundColor Green
} else {
    Write-Host "overlay failed to start. See $LogFile" -ForegroundColor Red
    exit 1
}
