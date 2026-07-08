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
- **Full system info at a glance** — model, manufacturer, serial number, computer name,
  CPU (name, cores/threads, clock), RAM capacity and speed, every GPU, and screen resolution(s)
- **Battery health** — `FullChargeCapacity / DesignedCapacity × 100`, read from WMI
  (`root\wmi`) with an automatic `powercfg /batteryreport` fallback for machines whose
  drivers don't expose the WMI battery classes; shows `Health: Unknown` only when neither
  source reports capacity data
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
git clone https://github.com/skermiebrotech/quick-checks.git
cd quick-checks
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\QuickChecks.ps1
```

### From Win+R (no download needed)

Press <kbd>Win</kbd>+<kbd>R</kbd>, paste, and hit Enter:

```
powershell -NoProfile -ExecutionPolicy Bypass -Sta -Command "irm https://raw.githubusercontent.com/skermiebrotech/quick-checks/main/QuickChecks.ps1 | iex"
```

> If you fork this repository, replace `skermiebrotech` with your own GitHub username.

### Build a standalone EXE (optional)

Using the community [ps2exe](https://github.com/MScholtes/PS2EXE) tool (only needed for
building — the app itself has no module dependencies):

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe .\QuickChecks.ps1 .\QuickChecks.exe -noConsole -STA -title 'quick-checks' -product 'quick-checks'
```

### Launch during Windows OOBE (refurb/repair techs)

[`payloads/oobe-launch.txt`](payloads/oobe-launch.txt) is a [DuckyScript](https://docs.hak5.org/hak5-usb-rubber-ducky)
payload for a USB Rubber Ducky / Flipper Zero. When run at the Windows 10/11 out-of-box-experience
setup screens, it opens the hidden command prompt with <kbd>Shift</kbd>+<kbd>F10</kbd> and streams
quick-checks from GitHub — handy for testing a machine's battery and keyboard before finishing setup.

Encode it with the Hak5 Duck Encoder (or drop it on a Flipper Zero as BadUSB). It assumes a US
keyboard layout and a working internet connection, and is meant for hardware **you own or are
authorised to service**.

## Privacy

The keyboard tester **does not log, save, or transmit keystrokes**. It uses ordinary WinForms
`KeyDown`/`KeyUp` events (no global keyboard hook), only reacts while its own window has focus,
and only changes the colour of on-screen keys. Nothing you type is stored anywhere, and key
state is discarded the moment the tester window closes.

## License

MIT — see [LICENSE](LICENSE).
