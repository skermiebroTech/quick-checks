# quick-checks

A modern, dark-themed PowerShell diagnostic tool for Windows laptops. One script, zero
dependencies — it shows live battery status with a smoothly animated battery graphic, plus a
graphical keyboard tester that runs on its own thread so it never blocks the main window.

![Main window](assets/screenshot-main.png)
*Main window — screenshot placeholder*

![Keyboard tester](assets/screenshot-keyboard.png)
*Keyboard tester — screenshot placeholder*

## Features

- **Live battery display** — a battery icon drawn entirely with System.Drawing (no images):
  - Fill level tracks the real charge, with a smooth fill animation
  - Continuous red → yellow → green colour gradient based on charge level
  - Animated lightning bolt + moving shine effect while on AC power (~30 FPS)
  - Slow pulse when the battery is at 0–20%, subtle green glow at 81–100%
  - "Fully Charged" indicator at 100%
- **System info at a glance** — model, manufacturer, serial number, computer name
- **Battery health** — `FullChargeCapacity / DesignedCapacity × 100`, read from WMI
  (`root\wmi`); shows `Health: Unknown` gracefully when the firmware doesn't report it
- **Keyboard tester** — a full visual QWERTY layout (function keys, number row, modifiers,
  arrows, navigation cluster). Keys light up while held and turn green once tested. Runs in a
  separate STA PowerShell runspace, so it stays responsive while the battery display updates
- **System tray support** — minimising sends the app to the tray; the tray menu offers
  Open / Open Keyboard Tester / Refresh / Exit, and double-click restores the window
- **Robust** — no crashes on desktops, machines without batteries, missing WMI classes,
  or limited permissions; friendly status messages instead of raw errors
- **Lightweight** — event-driven timers only run while something is actually animating;
  idle CPU usage is well under 1%

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- No third-party modules — only built-in .NET (WinForms, System.Drawing) and WMI/CIM

## Run it

### From PowerShell

```powershell
git clone https://github.com/joelskerman/quick-checks.git
cd quick-checks
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\QuickChecks.ps1
```

### From Win+R (no download needed)

Press <kbd>Win</kbd>+<kbd>R</kbd>, paste, and hit Enter:

```
powershell -NoProfile -ExecutionPolicy Bypass -Sta -Command "irm https://raw.githubusercontent.com/joelskerman/quick-checks/main/QuickChecks.ps1 | iex"
```

> If you fork this repository, replace `joelskerman` with your own GitHub username.

### Build a standalone EXE (optional)

Using the community [ps2exe](https://github.com/MScholtes/PS2EXE) tool (only needed for
building — the app itself has no module dependencies):

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe .\QuickChecks.ps1 .\QuickChecks.exe -noConsole -STA -title 'quick-checks' -product 'quick-checks'
```

## Privacy

The keyboard tester **does not log, save, or transmit keystrokes**. It uses ordinary WinForms
`KeyDown`/`KeyUp` events (no global keyboard hook), only reacts while its own window has focus,
and only changes the colour of on-screen keys. Nothing you type is stored anywhere, and key
state is discarded the moment the tester window closes.

## License

MIT — see [LICENSE](LICENSE).
