<#
    quick-checks
    ------------
    A modern PowerShell diagnostic tool for Windows laptops.

      * Live battery display with a smoothly animated, gradient-filled battery
        graphic drawn entirely with System.Drawing (no image assets).
      * Graphical keyboard tester running in its own STA runspace so it never
        blocks the main window.
      * System tray integration, dark theme, low idle CPU.

    Requirements : Windows 10/11, Windows PowerShell 5.1+ (built in).
    Dependencies : none - only built-in .NET (WinForms/System.Drawing) and WMI/CIM.
    License      : MIT

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\QuickChecks.ps1
#>

#Requires -Version 5.1

# --------------------------------------------------------------------------
# Environment setup
# --------------------------------------------------------------------------

# WinForms needs a single-threaded apartment. powershell.exe consoles are STA
# by default; if we were started MTA, relaunch ourselves correctly.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    if ($PSCommandPath) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', "`"$PSCommandPath`"")
        return
    }
    Write-Warning 'quick-checks needs an STA thread. Re-run with:  powershell -Sta -Command "irm <script url> | iex"'
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

# If we own our console window (launched via Win+R / double-click rather than
# from an interactive terminal), hide it so only the GUI shows.
try {
    Add-Type -Namespace QuickChecks -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] processList, uint processCount);
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
    $consoleHwnd = [QuickChecks.Native]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) {
        $procList = New-Object 'uint[]' 4
        if ([QuickChecks.Native]::GetConsoleProcessList($procList, 4) -eq 1) {
            [void][QuickChecks.Native]::ShowWindow($consoleHwnd, 0)   # SW_HIDE
        }
    }
} catch { }

# --------------------------------------------------------------------------
# Theme and shared state
# --------------------------------------------------------------------------

$script:Theme = @{
    Back    = [System.Drawing.Color]::FromArgb(30, 30, 36)
    Panel   = [System.Drawing.Color]::FromArgb(38, 38, 46)
    Text    = [System.Drawing.Color]::FromArgb(232, 232, 236)
    SubText = [System.Drawing.Color]::FromArgb(160, 160, 172)
    Accent  = [System.Drawing.Color]::FromArgb(79, 195, 247)
    Green   = [System.Drawing.Color]::FromArgb(63, 185, 80)
    Red     = [System.Drawing.Color]::FromArgb(231, 72, 60)
    Border  = [System.Drawing.Color]::FromArgb(96, 96, 106)
}

# Live state shared between the data timer, animation timer and paint handler.
$script:State = @{
    HasBattery     = $false
    Percent        = 0        # real charge (int)
    DisplayPercent = 0.0      # animated value the battery graphic shows
    OnAc           = $false
    Charging       = $false
    RemainingMins  = $null
    ShinePhase     = 0.0      # 0..1 position of the charging shine sweep
    PulsePhase     = 0.0      # radians, low-battery pulse
}

$script:CleanedUp   = $false
$script:HealthInfo  = $null
$script:HealthRetry = 0

# --------------------------------------------------------------------------
# Data collection (WMI/CIM + WinForms PowerStatus)
# --------------------------------------------------------------------------

function Get-SystemInformation {
    # Static machine identity + hardware inventory. Every query is fenced so a
    # missing WMI class or denied permission just leaves the field as 'Unknown'.
    $info = [ordered]@{
        Model        = 'Unknown'
        Manufacturer = 'Unknown'
        Serial       = 'Unknown'
        ComputerName = $env:COMPUTERNAME
        Cpu          = 'Unknown'
        Ram          = 'Unknown'
        Gpu          = 'Unknown'
        Screen       = 'Unknown'
    }
    $cs = $null
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs) {
            if ($cs.Model)        { $info.Model        = ([string]$cs.Model).Trim() }
            if ($cs.Manufacturer) { $info.Manufacturer = ([string]$cs.Manufacturer).Trim() }
        }
    } catch { }
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        if ($bios -and $bios.SerialNumber) { $info.Serial = ([string]$bios.SerialNumber).Trim() }
    } catch { }

    # CPU: cleaned-up name, core/thread count, rated clock.
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu -and $cpu.Name) {
            $name = ((([string]$cpu.Name) -replace '\(R\)|\(TM\)', '') -split '@')[0] -replace '\s+', ' '
            $clock = ''
            if ($cpu.MaxClockSpeed -gt 0) { $clock = ' @ {0:N1} GHz' -f ($cpu.MaxClockSpeed / 1000.0) }
            $info.Cpu = '{0} ({1}C/{2}T){3}' -f $name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors, $clock
        }
    } catch { }

    # RAM: total capacity, configured speed and module count. Falls back to
    # the OS-visible total when the DIMM class is unavailable.
    try {
        $dimms = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
        if ($dimms.Count -gt 0) {
            $totalGB = [math]::Round((($dimms | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
            $speed = $dimms | ForEach-Object {
                if ($_.ConfiguredClockSpeed -gt 0) { $_.ConfiguredClockSpeed }
                elseif ($_.Speed -gt 0)            { $_.Speed }
            } | Select-Object -First 1
            if ($speed) { $info.Ram = '{0} GB @ {1} MHz, {2} module(s)' -f $totalGB, $speed, $dimms.Count }
            else        { $info.Ram = '{0} GB, {1} module(s)' -f $totalGB, $dimms.Count }
        } elseif ($cs -and $cs.TotalPhysicalMemory) {
            $info.Ram = '{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB)
        }
    } catch {
        if ($cs -and $cs.TotalPhysicalMemory) { $info.Ram = '{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB) }
    }

    # GPUs: every video controller, plus the native resolution(s) they report.
    try {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name })
        if ($gpus.Count -gt 0) {
            $info.Gpu = ($gpus | ForEach-Object { ([string]$_.Name).Trim() }) -join '  +  '
            $res = @($gpus | Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
                ForEach-Object { '{0}x{1}' -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution } |
                Select-Object -Unique)
            if ($res.Count -gt 0) { $info.Screen = $res -join ', ' }
        }
    } catch { }

    # Fallback resolution from WinForms if the video driver didn't report one.
    if ($info.Screen -eq 'Unknown') {
        try {
            $info.Screen = ([System.Windows.Forms.Screen]::AllScreens |
                ForEach-Object { '{0}x{1}' -f $_.Bounds.Width, $_.Bounds.Height }) -join ', '
        } catch { }
    }

    [pscustomobject]$info
}

function Get-BatteryInformation {
    # Live charge/AC state. SystemInformation.PowerStatus is the cheap,
    # reliable primary source; Win32_Battery fills in the gaps.
    $result = [ordered]@{
        HasBattery    = $false
        Percent       = $null
        OnAc          = $false
        Charging      = $false
        RemainingMins = $null
    }

    try {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        $result.OnAc = ($power.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online)
        $noBattery = ($power.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) -ne 0
        $lifePct = $power.BatteryLifePercent
        if (-not $noBattery -and $lifePct -ge 0 -and $lifePct -le 1.0) {
            $result.HasBattery = $true
            $result.Percent    = [int][math]::Round($lifePct * 100)
            $result.Charging   = ($power.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::Charging) -ne 0
            if ($power.BatteryLifeRemaining -gt 0) {
                $result.RemainingMins = [int]($power.BatteryLifeRemaining / 60)
            }
        }
    } catch { }

    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($battery) {
            $result.HasBattery = $true
            if ($null -eq $result.Percent -and $null -ne $battery.EstimatedChargeRemaining) {
                $result.Percent = [int][math]::Min(100, [int]$battery.EstimatedChargeRemaining)
            }
            # BatteryStatus 6-9 are the 'charging' variants; 2 means on AC.
            if ($battery.BatteryStatus -in 6, 7, 8, 9) { $result.Charging = $true; $result.OnAc = $true }
            elseif ($battery.BatteryStatus -eq 2)      { $result.OnAc = $true }
            if ($null -eq $result.RemainingMins -and -not $result.OnAc -and
                $battery.EstimatedRunTime -gt 0 -and $battery.EstimatedRunTime -lt 71582788) {
                $result.RemainingMins = [int]$battery.EstimatedRunTime
            }
        }
    } catch { }

    [pscustomobject]$result
}

function Get-BatteryHealth {
    # Health = FullChargeCapacity / DesignedCapacity * 100.
    # Primary source: the root\wmi battery classes. Many machines don't expose
    # those, so fall back to parsing "powercfg /batteryreport /xml", which
    # reads the same firmware data and needs no admin rights.
    try {
        $full   = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
        $static = Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1
        if ($full -and $static -and $static.DesignedCapacity -gt 0 -and $full.FullChargedCapacity -gt 0) {
            $health = [math]::Round(($full.FullChargedCapacity / $static.DesignedCapacity) * 100)
            return [pscustomobject]@{
                DesignedCapacity   = [uint32]$static.DesignedCapacity
                FullChargeCapacity = [uint32]$full.FullChargedCapacity
                HealthPercent      = [int][math]::Min(100, $health)
            }
        }
    } catch { }

    # Fallback: powercfg battery report (exits non-zero on desktops, so this
    # is harmless on machines without a battery).
    try {
        $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) 'quick-checks-batteryreport.xml'
        $proc = Start-Process -FilePath 'powercfg.exe' `
            -ArgumentList '/batteryreport', '/xml', '/output', "`"$xmlPath`"" `
            -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $xmlPath)) {
            $raw = Get-Content -LiteralPath $xmlPath -Raw
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
            $report = [xml]$raw
            foreach ($bat in @($report.BatteryReport.Batteries.Battery)) {
                if (-not $bat) { continue }
                $design = 0.0; $fullCap = 0.0
                [void][double]::TryParse([string]$bat.DesignCapacity, [ref]$design)
                [void][double]::TryParse([string]$bat.FullChargeCapacity, [ref]$fullCap)
                if ($design -gt 0 -and $fullCap -gt 0) {
                    return [pscustomobject]@{
                        DesignedCapacity   = [uint32]$design
                        FullChargeCapacity = [uint32]$fullCap
                        HealthPercent      = [int][math]::Min(100, [math]::Round(($fullCap / $design) * 100))
                    }
                }
            }
        }
    } catch { }
    $null
}

# --------------------------------------------------------------------------
# Drawing helpers
# --------------------------------------------------------------------------

function Get-BatteryFillColor {
    # Continuous gradient: 0% red -> 50% yellow -> 100% green.
    param([double]$Percent)
    $p = [math]::Max(0.0, [math]::Min(100.0, $Percent))
    $red    = @(231, 72, 60)
    $yellow = @(243, 206, 60)
    $green  = @(72, 195, 88)
    if ($p -le 50) {
        $t = $p / 50.0; $a = $red; $b = $yellow
    } else {
        $t = ($p - 50.0) / 50.0; $a = $yellow; $b = $green
    }
    [System.Drawing.Color]::FromArgb(
        [int]($a[0] + ($b[0] - $a[0]) * $t),
        [int]($a[1] + ($b[1] - $a[1]) * $t),
        [int]($a[2] + ($b[2] - $a[2]) * $t))
}

function New-RoundedRectanglePath {
    param([System.Drawing.RectangleF]$Rect, [float]$Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc($Rect.X, $Rect.Y, $d, $d, 180, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Y, $d, $d, 270, 90)
    $path.AddArc($Rect.Right - $d, $Rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function Draw-ChargingAnimation {
    # Moving shine sweep across the filled portion of the battery. The caller
    # has already clipped the Graphics to the battery interior.
    param(
        [System.Drawing.Graphics]$Graphics,
        [System.Drawing.RectangleF]$FillRect
    )
    if ($FillRect.Width -le 6) { return }
    $shineWidth = 70.0
    $span = $FillRect.Width + 2 * $shineWidth
    $sx = [float]($FillRect.X - $shineWidth + $span * $script:State.ShinePhase)
    $shineRect = New-Object System.Drawing.RectangleF($sx, $FillRect.Y, [float]$shineWidth, $FillRect.Height)
    $shine = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $shineRect,
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
        [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
        [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
    try {
        $blend = New-Object System.Drawing.Drawing2D.ColorBlend 3
        $blend.Colors = @(
            [System.Drawing.Color]::FromArgb(0, 255, 255, 255),
            [System.Drawing.Color]::FromArgb(85, 255, 255, 255),
            [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
        $blend.Positions = [float[]]@(0.0, 0.5, 1.0)
        $shine.InterpolationColors = $blend
        $Graphics.FillRectangle($shine, $shineRect)
    } finally {
        $shine.Dispose()
    }
}

function Draw-Battery {
    # Paints the whole battery graphic. Called from the panel's Paint event;
    # every GDI+ object created here is disposed before returning.
    param(
        [System.Drawing.Graphics]$Graphics,
        [int]$Width,
        [int]$Height
    )
    $s = $script:State
    $g = $Graphics
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $bodyW = 300.0; $bodyH = 118.0; $nubW = 14.0; $nubH = 48.0
    $bx = [float](($Width - ($bodyW + $nubW + 4)) / 2.0)
    $by = [float](($Height - $bodyH) / 2.0)
    $bodyRect = New-Object System.Drawing.RectangleF($bx, $by, [float]$bodyW, [float]$bodyH)

    $pct = 0.0
    if ($s.HasBattery) { $pct = [math]::Max(0.0, [math]::Min(100.0, [double]$s.DisplayPercent)) }
    $charging = $s.HasBattery -and $s.OnAc -and $s.Percent -lt 100

    # Subtle green glow when nearly full (81-100%).
    if ($s.HasBattery -and $s.Percent -ge 81) {
        for ($i = 1; $i -le 4; $i++) {
            $glowRect = New-Object System.Drawing.RectangleF(
                [float]($bx - 3 * $i), [float]($by - 3 * $i),
                [float]($bodyW + 6 * $i), [float]($bodyH + 6 * $i))
            $glowPath = New-RoundedRectanglePath -Rect $glowRect -Radius ([float](16 + 3 * $i))
            $glowPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb((38 - 8 * $i), 63, 185, 80), [float](2 + $i))
            try     { $g.DrawPath($glowPen, $glowPath) }
            finally { $glowPen.Dispose(); $glowPath.Dispose() }
        }
    }

    $bodyPath = New-RoundedRectanglePath -Rect $bodyRect -Radius 16
    try {
        # Battery cavity background.
        $bgBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(24, 24, 30))
        try { $g.FillPath($bgBrush, $bodyPath) } finally { $bgBrush.Dispose() }

        # Charge fill, clipped to the rounded interior.
        $inner = New-Object System.Drawing.RectangleF(
            [float]($bx + 8), [float]($by + 8), [float]($bodyW - 16), [float]($bodyH - 16))
        if ($s.HasBattery -and $pct -gt 0.5) {
            $fillColor = Get-BatteryFillColor -Percent $pct
            $alpha = 255
            if (-not $s.OnAc -and $s.Percent -le 20) {
                # Slow pulse when the battery is low.
                $alpha = [int][math]::Max(70, [math]::Min(255, 165 + 90 * [math]::Sin($s.PulsePhase)))
            }
            $fillTop    = [System.Drawing.Color]::FromArgb($alpha,
                [math]::Min(255, $fillColor.R + 45), [math]::Min(255, $fillColor.G + 45), [math]::Min(255, $fillColor.B + 45))
            $fillBottom = [System.Drawing.Color]::FromArgb($alpha, $fillColor)
            $fillRect = New-Object System.Drawing.RectangleF(
                $inner.X, $inner.Y, [float]($inner.Width * $pct / 100.0), $inner.Height)
            $innerPath = New-RoundedRectanglePath -Rect $inner -Radius 10
            try {
                $g.SetClip($innerPath)
                $fillBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                    $fillRect, $fillTop, $fillBottom, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
                try { $g.FillRectangle($fillBrush, $fillRect) } finally { $fillBrush.Dispose() }
                if ($charging) { Draw-ChargingAnimation -Graphics $g -FillRect $fillRect }
            } finally {
                $g.ResetClip()
                $innerPath.Dispose()
            }
        }

        # Outline and terminal nub.
        $outlinePen = New-Object System.Drawing.Pen($script:Theme.Border, 5)
        try { $g.DrawPath($outlinePen, $bodyPath) } finally { $outlinePen.Dispose() }
    } finally {
        $bodyPath.Dispose()
    }

    $nubRect = New-Object System.Drawing.RectangleF(
        [float]($bx + $bodyW + 4), [float]($by + ($bodyH - $nubH) / 2), [float]$nubW, [float]$nubH)
    $nubPath  = New-RoundedRectanglePath -Rect $nubRect -Radius 5
    $nubBrush = New-Object System.Drawing.SolidBrush $script:Theme.Border
    try     { $g.FillPath($nubBrush, $nubPath) }
    finally { $nubBrush.Dispose(); $nubPath.Dispose() }

    # Animated lightning bolt while charging (left of the percentage text).
    if ($charging) {
        $cx = $bx + 52.0; $cy = $by + $bodyH / 2.0
        $bolt = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF([float]($cx + 9),  [float]($cy - 34))),
            (New-Object System.Drawing.PointF([float]($cx - 15), [float]($cy + 6))),
            (New-Object System.Drawing.PointF([float]($cx - 2),  [float]($cy + 6))),
            (New-Object System.Drawing.PointF([float]($cx - 9),  [float]($cy + 34))),
            (New-Object System.Drawing.PointF([float]($cx + 15), [float]($cy - 6))),
            (New-Object System.Drawing.PointF([float]($cx + 2),  [float]($cy - 6)))
        )
        # Bolt brightness follows the shine sweep so it gently flickers.
        $boltAlpha = [int](200 + 55 * [math]::Sin($s.ShinePhase * 6.28318))
        $boltBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($boltAlpha, 255, 255, 255))
        $boltPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160, 25, 25, 30), 2)
        try {
            $g.FillPolygon($boltBrush, $bolt)
            $g.DrawPolygon($boltPen, $bolt)
        } finally {
            $boltBrush.Dispose(); $boltPen.Dispose()
        }
    }

    # Percentage text centred in the battery body.
    $text = 'N/A'
    if ($s.HasBattery) { $text = '{0}%' -f [int][math]::Round($pct) }
    $font   = New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold)
    $sf     = New-Object System.Drawing.StringFormat
    $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
    $white  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(245, 245, 250))
    try {
        $sf.Alignment     = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $shadowRect = New-Object System.Drawing.RectangleF([float]($bx + 2), [float]($by + 3), [float]$bodyW, [float]$bodyH)
        $g.DrawString($text, $font, $shadow, $shadowRect, $sf)
        $g.DrawString($text, $font, $white, $bodyRect, $sf)
    } finally {
        $font.Dispose(); $sf.Dispose(); $shadow.Dispose(); $white.Dispose()
    }
}

# --------------------------------------------------------------------------
# Animation engine (~30 FPS, runs only while something is moving)
# --------------------------------------------------------------------------

function Step-Animation {
    $s = $script:State
    $active = $false
    if ($s.HasBattery) {
        # Ease the displayed fill level toward the real charge.
        $diff = [double]$s.Percent - $s.DisplayPercent
        if ([math]::Abs($diff) -gt 0.4) {
            $s.DisplayPercent += [math]::Max(-1.5, [math]::Min(1.5, $diff))
            $active = $true
        } else {
            $s.DisplayPercent = [double]$s.Percent
        }
        # Charging shine sweep.
        if ($s.OnAc -and $s.Percent -lt 100) {
            $s.ShinePhase += 0.02
            if ($s.ShinePhase -ge 1.0) { $s.ShinePhase = 0.0 }
            $active = $true
        }
        # Low-battery pulse.
        if (-not $s.OnAc -and $s.Percent -le 20) {
            $s.PulsePhase += 0.09
            if ($s.PulsePhase -ge 6.28318) { $s.PulsePhase -= 6.28318 }
            $active = $true
        }
    }
    if ($script:BatteryPanel) { $script:BatteryPanel.Invalidate() }
    # Nothing left to animate: stop the 30 FPS timer to keep idle CPU near zero.
    if (-not $active -and $script:AnimTimer) { $script:AnimTimer.Stop() }
}

# --------------------------------------------------------------------------
# Main UI refresh (data timer, every 2 seconds)
# --------------------------------------------------------------------------

function Update-MainUI {
    $s = $script:State
    $battery = Get-BatteryInformation

    $s.HasBattery = $battery.HasBattery
    $s.OnAc       = $battery.OnAc
    $s.Charging   = $battery.Charging
    if ($battery.HasBattery -and $null -ne $battery.Percent) { $s.Percent = [int]$battery.Percent }
    else { $s.Percent = 0; $s.DisplayPercent = 0.0 }
    $s.RemainingMins = $battery.RemainingMins

    # Battery health is effectively static; if it was unavailable at startup,
    # retry a few times (every ~30 s) in case the driver needed time to settle.
    # Capped because the powercfg fallback spawns a process per attempt.
    if (-not $script:HealthInfo -and $s.HasBattery -and $script:HealthAttempts -lt 4) {
        $script:HealthRetry--
        if ($script:HealthRetry -le 0) {
            $script:HealthInfo  = Get-BatteryHealth
            $script:HealthAttempts++
            $script:HealthRetry = 15
        }
    }

    $ui = $script:UI
    if ($ui) {
        if ($s.HasBattery) { $ui.Battery.Text = 'Battery: {0}%' -f $s.Percent }
        else               { $ui.Battery.Text = 'Battery: N/A' }

        if ($script:HealthInfo) {
            $ui.Health.Text = 'Health: {0}%  ({1:N0} / {2:N0} mWh)' -f `
                $script:HealthInfo.HealthPercent, $script:HealthInfo.FullChargeCapacity, $script:HealthInfo.DesignedCapacity
        } else {
            $ui.Health.Text = 'Health: Unknown'
        }

        # Status line under the battery graphic.
        if (-not $s.HasBattery) {
            $ui.Status.Text = 'No battery detected - this looks like a desktop PC'
            $ui.Status.ForeColor = $script:Theme.SubText
        } elseif ($s.OnAc -and $s.Percent -ge 100) {
            $ui.Status.Text = 'Fully Charged'
            $ui.Status.ForeColor = $script:Theme.Green
        } elseif ($s.OnAc) {
            $ui.Status.Text = 'Charging'
            $ui.Status.ForeColor = $script:Theme.Accent
        } else {
            $remaining = ''
            if ($s.RemainingMins -gt 0) {
                $remaining = ' - about {0} h {1:D2} m remaining' -f [int][math]::Floor($s.RemainingMins / 60), [int]($s.RemainingMins % 60)
            }
            if ($s.Percent -le 20) {
                $ui.Status.Text = "Low Battery$remaining"
                $ui.Status.ForeColor = $script:Theme.Red
            } else {
                $ui.Status.Text = "On Battery$remaining"
                $ui.Status.ForeColor = $script:Theme.SubText
            }
        }
    }

    # Tray tooltip (NotifyIcon.Text is limited to 63 characters).
    if ($script:TrayIcon) {
        $tip = 'quick-checks'
        if ($s.HasBattery) { $tip = 'quick-checks - {0}%  {1}' -f $s.Percent, $(if ($s.OnAc) { 'AC' } else { 'Battery' }) }
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:TrayIcon.Text = $tip
    }

    # Kick the animation timer only when something needs to move.
    $needsAnim = $s.HasBattery -and (
        ($s.OnAc -and $s.Percent -lt 100) -or
        (-not $s.OnAc -and $s.Percent -le 20) -or
        ([math]::Abs($s.DisplayPercent - $s.Percent) -gt 0.4))
    if ($needsAnim -and $script:AnimTimer -and -not $script:AnimTimer.Enabled) { $script:AnimTimer.Start() }
    if ($script:BatteryPanel) { $script:BatteryPanel.Invalidate() }
}

# --------------------------------------------------------------------------
# App icon (drawn in code - used for the window and the tray)
# --------------------------------------------------------------------------

function New-AppIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $fill   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(72, 195, 88))
        $border = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(235, 235, 240), 2)
        $nub    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 235, 240))
        try {
            $g.FillRectangle($fill, 4, 11, 20, 11)
            $g.DrawRectangle($border, 3, 10, 22, 13)
            $g.FillRectangle($nub, 26, 13, 3, 7)
        } finally {
            $fill.Dispose(); $border.Dispose(); $nub.Dispose()
        }
    } finally {
        $g.Dispose()
    }
    # The HICON lives for the process lifetime; Windows reclaims it on exit.
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

# --------------------------------------------------------------------------
# Keyboard tester
#
# New-KeyboardTesterForm and Update-KeyVisual execute INSIDE a dedicated STA
# runspace (see Start-KeyboardTester, which copies their definitions across),
# so the tester stays responsive no matter what the battery UI is doing.
# Privacy: keystrokes are never stored, logged or transmitted - key events
# only flip the colour of on-screen labels while the window is open.
# --------------------------------------------------------------------------

function Update-KeyVisual {
    # Recolours one on-screen key. States: Pressed (held), Released (tested OK).
    param(
        [System.Windows.Forms.Control]$Control,
        [ValidateSet('Pressed', 'Released', 'Default')][string]$State
    )
    switch ($State) {
        'Pressed' {
            $Control.BackColor = [System.Drawing.Color]::FromArgb(79, 195, 247)
            $Control.ForeColor = [System.Drawing.Color]::FromArgb(18, 18, 22)
        }
        'Released' {
            $Control.BackColor = [System.Drawing.Color]::FromArgb(63, 185, 80)
            $Control.ForeColor = [System.Drawing.Color]::White
        }
        'Default' {
            $Control.BackColor = [System.Drawing.Color]::FromArgb(46, 46, 54)
            $Control.ForeColor = [System.Drawing.Color]::FromArgb(205, 205, 215)
        }
    }
}

function New-KeyboardTesterForm {
    # Builds the tester window. Runs inside the tester runspace, where $Sync is
    # a synchronized hashtable shared with the main app (Close/Activate flags).
    $unit = 46; $keyH = 42; $gap = 4; $ox = 14; $oy = 66

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'quick-checks Keyboard Tester'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox     = $false
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 36)
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.KeyPreview      = $true
    $form.ClientSize      = New-Object System.Drawing.Size([int]($ox * 2 + 18.4 * $unit), [int]($oy + 6 * $unit + 34))
    try {
        [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
    } catch { }

    $header = New-Object System.Windows.Forms.Label
    $header.Text      = 'Press any key: blue while held, green once tested. Nothing is logged or saved.'
    $header.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 172)
    $header.SetBounds($ox, 10, $form.ClientSize.Width - 2 * $ox, 20)
    $form.Controls.Add($header)

    $script:LastKeyLabel = New-Object System.Windows.Forms.Label
    $script:LastKeyLabel.Text      = 'Last key pressed: (none)'
    $script:LastKeyLabel.ForeColor = [System.Drawing.Color]::FromArgb(79, 195, 247)
    $script:LastKeyLabel.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $script:LastKeyLabel.SetBounds($ox, 32, $form.ClientSize.Width - 2 * $ox, 24)
    $form.Controls.Add($script:LastKeyLabel)

    $script:FocusLabel = New-Object System.Windows.Forms.Label
    $script:FocusLabel.Text      = 'Click inside this window to test keys'
    $script:FocusLabel.ForeColor = [System.Drawing.Color]::FromArgb(240, 180, 70)
    $script:FocusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $script:FocusLabel.SetBounds($ox, [int]($oy + 6 * $unit + 4), $form.ClientSize.Width - 2 * $ox, 24)
    $form.Controls.Add($script:FocusLabel)

    $script:KeyMap       = @{}   # [int]Keys value -> ArrayList of key labels
    $script:KeyFont      = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:KeyFontSmall = New-Object System.Drawing.Font('Segoe UI', 7.5)

    function AddKey([string]$Label, [string]$KeyName, [double]$X, [double]$Y, [double]$W) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.SetBounds([int]$X, [int]$Y, [int]($W * $unit - $gap), $keyH)
        $lbl.Text        = $Label
        $lbl.TextAlign   = [System.Drawing.ContentAlignment]::MiddleCenter
        $lbl.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $lbl.Font        = if ($Label.Length -gt 3) { $script:KeyFontSmall } else { $script:KeyFont }
        Update-KeyVisual -Control $lbl -State Default
        $form.Controls.Add($lbl)
        $keyValue = [int][System.Windows.Forms.Keys]::$KeyName
        if (-not $script:KeyMap.ContainsKey($keyValue)) {
            $script:KeyMap[$keyValue] = New-Object System.Collections.ArrayList
        }
        [void]$script:KeyMap[$keyValue].Add($lbl)
    }

    # Main block: rows of (label, Keys-enum name, width-in-units) triples.
    # An empty key name is a spacer.
    $rows = @(
        ,@('Esc','Escape',1, '','',0.5, 'F1','F1',1,'F2','F2',1,'F3','F3',1,'F4','F4',1, '','',0.5,
           'F5','F5',1,'F6','F6',1,'F7','F7',1,'F8','F8',1, '','',0.5, 'F9','F9',1,'F10','F10',1,'F11','F11',1,'F12','F12',1)
        ,@('`','Oemtilde',1, '1','D1',1,'2','D2',1,'3','D3',1,'4','D4',1,'5','D5',1,'6','D6',1,'7','D7',1,
           '8','D8',1,'9','D9',1,'0','D0',1,'-','OemMinus',1,'=','Oemplus',1,'Backspace','Back',2)
        ,@('Tab','Tab',1.5, 'Q','Q',1,'W','W',1,'E','E',1,'R','R',1,'T','T',1,'Y','Y',1,'U','U',1,'I','I',1,
           'O','O',1,'P','P',1,'[','OemOpenBrackets',1,']','OemCloseBrackets',1,'\','Oem5',1.5)
        ,@('Caps','CapsLock',1.75, 'A','A',1,'S','S',1,'D','D',1,'F','F',1,'G','G',1,'H','H',1,'J','J',1,
           'K','K',1,'L','L',1,';','OemSemicolon',1,"'",'OemQuotes',1,'Enter','Return',2.25)
        ,@('Shift','ShiftKey',2.25, 'Z','Z',1,'X','X',1,'C','C',1,'V','V',1,'B','B',1,'N','N',1,'M','M',1,
           ',','Oemcomma',1,'.','OemPeriod',1,'/','OemQuestion',1,'Shift','ShiftKey',2.75)
        ,@('Ctrl','ControlKey',1.5, 'Win','LWin',1.25, 'Alt','Menu',1.5, 'Space','Space',6.5,
           'Alt','Menu',1.5, 'Win','RWin',1.25, 'Ctrl','ControlKey',1.5)
    )
    $y = [double]$oy
    foreach ($row in $rows) {
        $x = [double]$ox
        for ($i = 0; $i -lt $row.Count; $i += 3) {
            if ($row[$i + 1]) { AddKey $row[$i] $row[$i + 1] $x $y ([double]$row[$i + 2]) }
            $x += [double]$row[$i + 2] * $unit
        }
        $y += $unit
    }

    # Navigation cluster + arrow keys, right of the main block.
    $nx = $ox + 15.4 * $unit
    AddKey 'Ins'  'Insert'   $nx               ($oy + 1 * $unit) 1
    AddKey 'Home' 'Home'     ($nx + $unit)     ($oy + 1 * $unit) 1
    AddKey 'PgUp' 'PageUp'   ($nx + 2 * $unit) ($oy + 1 * $unit) 1
    AddKey 'Del'  'Delete'   $nx               ($oy + 2 * $unit) 1
    AddKey 'End'  'End'      ($nx + $unit)     ($oy + 2 * $unit) 1
    AddKey 'PgDn' 'PageDown' ($nx + 2 * $unit) ($oy + 2 * $unit) 1
    AddKey ([char]0x2191) 'Up'    ($nx + $unit)     ($oy + 4 * $unit) 1
    AddKey ([char]0x2190) 'Left'  $nx               ($oy + 5 * $unit) 1
    AddKey ([char]0x2193) 'Down'  ($nx + $unit)     ($oy + 5 * $unit) 1
    AddKey ([char]0x2192) 'Right' ($nx + 2 * $unit) ($oy + 5 * $unit) 1

    $form.Add_KeyDown({
        param($sender, $e)
        # Let Alt+F4 close the window normally.
        if ($e.Alt -and $e.KeyCode -eq [System.Windows.Forms.Keys]::F4) { return }
        $e.Handled = $true
        $e.SuppressKeyPress = $true
        $keyValue = [int]$e.KeyCode
        if ($script:KeyMap.ContainsKey($keyValue)) {
            foreach ($k in $script:KeyMap[$keyValue]) { Update-KeyVisual -Control $k -State Pressed }
        }
        $script:LastKeyLabel.Text = 'Last key pressed: ' + $e.KeyCode.ToString()
    })
    $form.Add_KeyUp({
        param($sender, $e)
        $keyValue = [int]$e.KeyCode
        if ($script:KeyMap.ContainsKey($keyValue)) {
            foreach ($k in $script:KeyMap[$keyValue]) { Update-KeyVisual -Control $k -State Released }
        }
    })

    # Focus hint.
    $form.Add_Activated({  $script:FocusLabel.Text = 'Press keys to test them' })
    $form.Add_Deactivate({ $script:FocusLabel.Text = 'Click inside this window to test keys' })

    # Lightweight watcher: lets the main app ask this window to close or come
    # to the front (via the shared synchronized hashtable), without the main
    # thread ever touching controls owned by this thread.
    $watch = New-Object System.Windows.Forms.Timer
    $watch.Interval = 250
    $watch.Add_Tick({
        try {
            if ($Sync.Close) { $script:TesterForm.Close(); return }
            if ($Sync.Activate) { $Sync.Activate = $false; $script:TesterForm.Activate() }
        } catch { }
    })
    $watch.Start()
    $script:TesterWatch = $watch
    $form.Add_FormClosed({
        try { $script:TesterWatch.Stop(); $script:TesterWatch.Dispose() } catch { }
        try { $script:KeyFont.Dispose(); $script:KeyFontSmall.Dispose() } catch { }
    })

    $script:TesterForm = $form
    $form
}

function Start-KeyboardTester {
    # Launches (or refocuses) the tester in its own STA runspace so the main
    # battery UI thread is never blocked.
    if ($script:TesterPS -and $script:TesterHandle -and -not $script:TesterHandle.IsCompleted) {
        try { $script:TesterSync.Activate = $true } catch { }
        return
    }
    Stop-KeyboardTester   # dispose any finished/crashed previous instance

    $script:TesterSync = [hashtable]::Synchronized(@{ Close = $false; Activate = $false })
    try {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('Sync', $script:TesterSync)

        # Copy the tester functions into the runspace, then run the form there.
        $bootstrap = @(
            "function New-KeyboardTesterForm { $(${function:New-KeyboardTesterForm}) }",
            "function Update-KeyVisual { $(${function:Update-KeyVisual}) }",
            @'
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-KeyboardTesterForm
    [System.Windows.Forms.Application]::Run($form)
} catch { }
'@
        ) -join "`n"

        $ps = [powershell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript($bootstrap)
        $script:TesterRunspace = $runspace
        $script:TesterPS       = $ps
        $script:TesterHandle   = $ps.BeginInvoke()
    } catch {
        try {
            [void][System.Windows.Forms.MessageBox]::Show(
                "Could not start the keyboard tester.`n$($_.Exception.Message)",
                'quick-checks', 'OK', 'Warning')
        } catch { }
    }
}

function Stop-KeyboardTester {
    # Signals the tester window to close and releases its runspace.
    param([switch]$Wait)
    try { if ($script:TesterSync) { $script:TesterSync.Close = $true } } catch { }
    if ($Wait -and $script:TesterHandle) {
        for ($i = 0; $i -lt 15 -and -not $script:TesterHandle.IsCompleted; $i++) {
            Start-Sleep -Milliseconds 100
        }
    }
    try { if ($script:TesterPS)       { $script:TesterPS.Dispose() } }       catch { }
    try { if ($script:TesterRunspace) { $script:TesterRunspace.Dispose() } } catch { }
    $script:TesterPS = $null; $script:TesterRunspace = $null; $script:TesterHandle = $null
}

# --------------------------------------------------------------------------
# System tray
# --------------------------------------------------------------------------

function Restore-MainWindow {
    try {
        $script:MainForm.Show()
        $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:MainForm.ShowInTaskbar = $true
        $script:MainForm.Activate()
    } catch { }
}

function Initialize-TrayIcon {
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:TrayIcon.Icon = $script:AppIcon
    $script:TrayIcon.Text = 'quick-checks'

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('Open', $null, { Restore-MainWindow })
    [void]$menu.Items.Add('Open Keyboard Tester', $null, { Start-KeyboardTester })
    [void]$menu.Items.Add('Refresh', $null, { Update-MainUI })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add('Exit', $null, { $script:MainForm.Close() })
    $script:TrayIcon.ContextMenuStrip = $menu

    $script:TrayIcon.Add_DoubleClick({ Restore-MainWindow })
    $script:TrayIcon.Visible = $true
}

# --------------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------------

function Cleanup-App {
    # Idempotent teardown: timers, tray icon, tester runspace, GDI handles.
    if ($script:CleanedUp) { return }
    $script:CleanedUp = $true
    foreach ($timer in @($script:DataTimer, $script:AnimTimer)) {
        try { if ($timer) { $timer.Stop(); $timer.Dispose() } } catch { }
    }
    try {
        if ($script:TrayIcon) {
            $script:TrayIcon.Visible = $false
            $script:TrayIcon.Dispose()
        }
    } catch { }
    Stop-KeyboardTester -Wait
    try { if ($script:AppIcon) { $script:AppIcon.Dispose() } } catch { }
}

# --------------------------------------------------------------------------
# Main window
# --------------------------------------------------------------------------

function New-InfoLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.SetBounds($X, $Y, $W, 20)
    $lbl.ForeColor    = $script:Theme.Text
    $lbl.AutoEllipsis = $true
    $lbl
}

try {
    $script:SystemInfo     = Get-SystemInformation
    $script:HealthInfo     = Get-BatteryHealth
    $script:HealthAttempts = 1
    $script:HealthRetry    = 15
    $script:AppIcon     = New-AppIcon

    $form = New-Object System.Windows.Forms.Form
    $form.Text            = 'quick-checks'
    $form.Size            = New-Object System.Drawing.Size(600, 470)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox     = $false
    $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor       = $script:Theme.Back
    $form.ForeColor       = $script:Theme.Text
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Icon            = $script:AppIcon
    $script:MainForm = $form

    # Battery drawing surface (double-buffered to avoid flicker at 30 FPS).
    $panel = New-Object System.Windows.Forms.Panel
    $panel.SetBounds(0, 0, $form.ClientSize.Width, 208)
    $panel.BackColor = $script:Theme.Back
    try {
        [System.Windows.Forms.Control].GetProperty('DoubleBuffered',
            [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($panel, $true, $null)
    } catch { }
    $panel.Add_Paint({
        param($sender, $e)
        try { Draw-Battery -Graphics $e.Graphics -Width $sender.ClientSize.Width -Height $sender.ClientSize.Height } catch { }
    })
    $form.Controls.Add($panel)
    $script:BatteryPanel = $panel

    # Charging status line under the battery.
    $status = New-Object System.Windows.Forms.Label
    $status.SetBounds(0, 210, $form.ClientSize.Width, 26)
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $status.Font      = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $status.ForeColor = $script:Theme.SubText
    $status.Text      = 'Reading battery information...'
    $form.Controls.Add($status)

    # System / battery info, two columns of five rows.
    $colW = 262
    $lblModel        = New-InfoLabel ('Model: '        + $script:SystemInfo.Model)        24 246 $colW
    $lblManufacturer = New-InfoLabel ('Manufacturer: ' + $script:SystemInfo.Manufacturer) 24 270 $colW
    $lblSerial       = New-InfoLabel ('Serial: '       + $script:SystemInfo.Serial)       24 294 $colW
    $lblComputer     = New-InfoLabel ('Computer: '     + $script:SystemInfo.ComputerName) 24 318 $colW
    $lblScreen       = New-InfoLabel ('Screen: '       + $script:SystemInfo.Screen)       24 342 $colW
    $lblCpu          = New-InfoLabel ('CPU: '          + $script:SystemInfo.Cpu)          306 246 $colW
    $lblRam          = New-InfoLabel ('RAM: '          + $script:SystemInfo.Ram)          306 270 $colW
    $lblGpu          = New-InfoLabel ('GPU: '          + $script:SystemInfo.Gpu)          306 294 $colW
    $lblBattery      = New-InfoLabel 'Battery: --'  306 318 $colW
    $lblHealth       = New-InfoLabel 'Health: --'   306 342 $colW
    foreach ($lbl in @($lblModel, $lblManufacturer, $lblSerial, $lblComputer, $lblScreen,
                       $lblCpu, $lblRam, $lblGpu, $lblBattery, $lblHealth)) {
        $form.Controls.Add($lbl)
    }
    # Long values (CPU/GPU names, multi-monitor lists) get ellipsised by the
    # labels; the full text stays readable via a hover tooltip.
    $tips = New-Object System.Windows.Forms.ToolTip
    foreach ($lbl in @($lblModel, $lblCpu, $lblRam, $lblGpu, $lblScreen)) {
        $tips.SetToolTip($lbl, $lbl.Text)
    }
    $script:UI = @{
        Battery = $lblBattery
        Health  = $lblHealth
        Status  = $status
    }

    # Keyboard tester launcher.
    $button = New-Object System.Windows.Forms.Button
    $button.Text = 'Open Keyboard Tester'
    $button.SetBounds([int](($form.ClientSize.Width - 190) / 2), 378, 190, 34)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderColor = $script:Theme.Accent
    $button.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 54)
    $button.ForeColor = $script:Theme.Text
    $button.Add_Click({ Start-KeyboardTester })
    $form.Controls.Add($button)

    # Minimise -> system tray.
    $form.Add_Resize({
        if ($script:MainForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
            $script:MainForm.Hide()
            $script:MainForm.ShowInTaskbar = $false
        }
    })
    $form.Add_FormClosing({ Cleanup-App })

    Initialize-TrayIcon

    # Data refresh every 2 seconds; the 30 FPS animation timer is started on
    # demand by Update-MainUI and stops itself when nothing is animating.
    $script:DataTimer = New-Object System.Windows.Forms.Timer
    $script:DataTimer.Interval = 2000
    $script:DataTimer.Add_Tick({ Update-MainUI })
    $script:DataTimer.Start()

    $script:AnimTimer = New-Object System.Windows.Forms.Timer
    $script:AnimTimer.Interval = 33   # ~30 FPS
    $script:AnimTimer.Add_Tick({ Step-Animation })

    Update-MainUI
    [System.Windows.Forms.Application]::Run($form)
} catch {
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            "quick-checks hit an unexpected error and has to close.`n`n$($_.Exception.Message)",
            'quick-checks', 'OK', 'Error')
    } catch { }
} finally {
    Cleanup-App
}
