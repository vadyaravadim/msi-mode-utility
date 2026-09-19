<div align="center">

# MSI Mode Utility

**Check MSI mode in 10 seconds. Enable it in one click. We measured what it fixes, and what it doesn't.**

An open-source PowerShell script to view and toggle **MSI (Message Signaled Interrupts) mode** for PCI devices on Windows 10/11 — a transparent alternative to the closed-source "MSI Util v3" `.exe` from forum threads.
Zero install. Zero dependencies. Built-in undo.

[![lint](https://img.shields.io/github/actions/workflow/status/vadyaravadim/msi-mode-utility/lint.yml?label=lint&logo=powershell)](https://github.com/vadyaravadim/msi-mode-utility/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows)](https://www.microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://docs.microsoft.com/en-us/powershell/)
[![Latest release](https://img.shields.io/github/v/release/vadyaravadim/msi-mode-utility)](https://github.com/vadyaravadim/msi-mode-utility/releases)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/msi-mode-utility?logo=powershell&label=PS%20Gallery)](https://www.powershellgallery.com/packages/msi-mode-utility)
![GitHub Stars](https://img.shields.io/github/stars/vadyaravadim/msi-mode-utility?style=social)

**[Read the deep dive with measured before/after traces →](https://rigpolice.com/system/articles/enable-msi-mode/?utm_source=github&utm_medium=readme&utm_campaign=msi-mode-utility)**

**Part of [RigPolice](https://rigpolice.com/?utm_source=github&utm_medium=readme&utm_campaign=msi-mode-utility) — check your mouse's real polling rate after the change with the free [Polling Rate Test](https://rigpolice.com/mouse/tests/polling-rate-test/?utm_source=github&utm_medium=readme&utm_campaign=msi-mode-utility)**

</div>

---

![Out-GridView device picker showing PCI devices (GPU, NIC, USB, audio) and their current MSI mode status](assets/screenshot.png)

## Quick Start

**Easiest — from the PowerShell Gallery:**

```powershell
Install-Script msi-mode-utility
msi-mode-utility                     # then run it by name (open a NEW PowerShell window first, so the Scripts folder is on PATH)
msi-mode-utility -ShowAll            # switches work directly: -ShowAll, -Disable
```

The script self-elevates. Update later with `Update-Script msi-mode-utility`.

**One-liner** instead (in any PowerShell — it self-elevates):

```powershell
irm https://github.com/vadyaravadim/msi-mode-utility/releases/latest/download/msi-mode-utility.ps1 | iex
```

The script downloads itself to `%USERPROFILE%\msi-mode-utility.ps1` (not a temp folder) on purpose: the `msi_undo_*.reg` rollback file is written next to it and must survive automatic temp cleanup. An existing copy at that path that differs is kept as `.bak`. The `irm | iex` pipe itself takes no switches - run the saved copy instead, see [Optional switches](#optional-switches).

**Or clone:**

```powershell
git clone https://github.com/vadyaravadim/msi-mode-utility.git
cd msi-mode-utility
.\Run.bat
```

**Or download the ZIP** (no PowerShell needed): click **Code ▸ Download ZIP** at the top of this page, unzip, then double-click **`Run.bat`**.

### Using the picker

However you launch it:

1. Click **Yes** on the UAC prompt (the script requests admin rights on its own).
2. In the grid window, `Ctrl`-click the devices you want, then click **OK**.
3. **Reboot.**

### Optional switches

| Switch | Effect |
| --- | --- |
| `-ShowAll` | Show every MSI-capable PCI device, including bridges/controllers hidden by default |
| `-Disable` | Turn MSI **off** for the selected devices |

How to pass a switch depends on how you got the script:

| Installed via | Command |
|---------------|---------|
| PowerShell Gallery | `msi-mode-utility -ShowAll` |
| ZIP or clone | `.\Run.bat -ShowAll` from the script's folder |
| One-liner | `powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\msi-mode-utility.ps1" -ShowAll` |

Calling `.\msi-mode-utility.ps1` directly only works if your execution policy allows scripts — Windows blocks them by default, which is what `Run.bat` and `-ExecutionPolicy Bypass` get around.

## What It Does

1. **Scans** PCI devices and shows the latency-critical ones (GPU, network, USB, audio) in a grid with their current MSI status
2. **Backs up** the previous state of every selected device to a timestamped `msi_undo_*.reg` file next to the script (in `%USERPROFILE%` when run via the one-liner) — **before** changing anything
3. **Enables MSI mode** for the devices you selected (sets the documented `MSISupported` registry value)

Rollback = double-click the undo file, then reboot. No System Restore needed — works from Safe Mode too.

## The Problem: Line-Based (IRQ) vs Message Signaled Interrupts

Legacy line-based (IRQ) interrupts share physical lines, so a device can be forced to wait or collide with others. MSI lets a device signal the CPU by writing to a memory address instead — every device gets its own vector and nothing is shared. Windows still leaves some devices in legacy mode even when their driver supports MSI: on our Windows 11 testbed it was both audio controllers, stacked on one line.

**When it actually helps** (what we measured is in the [FAQ](#does-enabling-msi-mode-reduce-input-lag-or-increase-fps)):

- A device sharing a legacy IRQ line with a busy neighbor. Audio popping / crackling under GPU or USB load is the classic case: on a shared line every interrupt runs the routine of every driver on it
- DPC latency spikes that trace back to a driver on a shared line (msinfo32 shows who shares with whom, see [Verify](#verify-check-if-msi-mode-is-enabled))
- Older platforms and add-in cards (sound, USB, capture) that Windows left in line-based mode

**What it won't do:** raise average FPS, or shave input lag on a PC whose GPU and USB controller already run MSI. Forcing our USB controller back onto a legacy line cost 0.9 µs per mouse report. That is why the first thing this script does is show you the current state: on a modern PC the honest answer is often "already on".

## Requirements

| | |
|---|---|
| **Windows** | 10, 11 |
| **PowerShell** | Windows PowerShell 5.1 (ships with Windows 10/11); PowerShell 7 works too. Uses `Out-GridView`, which both have on Windows editions with a desktop and which is **not** available on Server Core. The script detects a missing `Out-GridView` and tells you what to do |
| **Rights** | Administrator (the script self-elevates via UAC) |

## How It Works

The MSI flag lives at:

```
HKLM\SYSTEM\CurrentControlSet\Enum\PCI\<class>\<instance>\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties
    Value: MSISupported  (DWORD)   1 = MSI on, 0 = off
```

MSI-capable devices always have the `Interrupt Management` key, but the `MessageSignaledInterruptProperties` subkey and `MSISupported` value **often don't exist until you enable MSI** — so the script creates them as needed rather than only flipping existing values.

When the value is absent, the grid shows **Default** (not "Disabled"): it means no explicit override is set and the driver default applies — an MSI-X-capable device may already be running in MSI-X mode regardless of this key.

## Verify: Check If MSI Mode Is Enabled

After the reboot, confirm the device actually runs in MSI mode:

- **Device Manager** → device → **Properties ▸ Resources**: a **negative IRQ number** (e.g. `-3145728`) means message-signaled interrupts are active; a small positive number means legacy line-based mode.
- **msinfo32** → Hardware Resources ▸ IRQs: legacy devices sit at the top on small numbers (two devices on the same number share that line); MSI/MSI-X devices sit at the bottom, where msinfo32 prints the negative IRQ as a ten-digit number such as `IRQ 4294967255`.
- Or just run the script again — the grid shows the current `MSISupported` state of every device.

## Reverting

Two options:

1. Double-click the `msi_undo_*.reg` file created before your change, then reboot (restores the previous `MSISupported` state, works from Safe Mode). If you ran the script several times against the same device, apply the undo files newest-to-oldest — each one is a snapshot of the state before *that* run, so only the oldest holds the original state.
2. Run the script again with `-Disable` (`.\Run.bat -Disable` from a ZIP or clone; [other install methods](#optional-switches) pass the switch differently) and select the same devices. Note: this writes an explicit `MSISupported = 0`; if the device originally had no `MSISupported` value at all (shown as **Default** in the grid), only the undo file restores that exact state.

Prefer a System Restore point anyway? Create one yourself before running: `Checkpoint-Computer -Description "Before MSI"` (note: Windows silently skips it if a point was made within the last 24 hours).

## FAQ

### What is MSI mode?

MSI (Message Signaled Interrupts) is a way for a PCI/PCIe device to deliver interrupts by writing to a memory address instead of asserting a shared physical IRQ line. Every device gets its own vector, so the extra interrupt-routine calls a shared line causes go away.

### Does enabling MSI mode reduce input lag or increase FPS?

Not average FPS, and on a healthy modern PC not input lag either. We traced it on an i9-14900F / RX 7800 XT desktop (Windows 11 25H2), two 30 s runs per state under the same 180 fps load:

| Device, change | What moved | What did not |
|----------------|-----------|--------------|
| Two audio controllers, shared IRQ 17 → MSI | ISR calls per interrupt **1.9 → 1.0** (6,480 → 3,470 calls for ~3,450 real interrupts) | Frame times (p99 5.8 ms both ways, 0 missed frames) |
| GPU, MSI → forced legacy line | Nothing we would bet on: mean ISR 19.2 → 25.4 µs in the fresh-boot pair, but MSI-mode runs alone ranged 18.9–25.9 µs | ISR + DPC per interrupt (38 vs 42 µs), 0 missed frames |
| USB xHCI with a fast mouse (~7,500 interrupts/s), MSI → forced legacy line | Mean ISR 0.2 → 1.1 µs | Mean DPC 5.6 µs both ways; **+0.9 µs per mouse report** in total |

MSI mode removes one specific cost: devices stacked on a shared interrupt line, each running its routine for the other's interrupts. Windows 11 drivers had already put the GPU, USB, NVMe and network devices in MSI/MSI-X on that machine; the only legacy devices were the two audio controllers. The cost becomes audible or visible when a shared line carries something heavy (the classic case is a sound card sharing a line with a busy GPU). Full methodology, screenshots and the "check your own PC in 30 seconds" guide: **[the RigPolice deep dive](https://rigpolice.com/system/articles/enable-msi-mode/?utm_source=github&utm_medium=readme&utm_campaign=msi-mode-utility)**. Reproduce it yourself with [`bench/msi-bench.ps1`](bench/msi-bench.ps1): built-in Windows tools only (NT Kernel Logger + `tracerpt`), nothing to install. The raw output of every run behind these numbers, with the known gaps listed, is in [`bench/results/`](bench/results/).

### Is it safe to enable MSI mode?

`MSISupported` is a documented, reversible registry value. Before every change the script saves a `.reg` undo file with the previous state of the values it changes. Worst case, a device that misbehaves with MSI reverts as soon as you apply the undo file and reboot (works from Safe Mode too).

### Should I enable MSI mode for my NVIDIA or AMD GPU?

GPUs are the most common target for this tweak. Some NVIDIA and AMD driver/board combinations leave the card in legacy line-based mode — the grid shows the current state, so you don't have to guess. If your GPU shows **Default** or **Disabled** and you see DPC latency spikes or frame-time stutters, enabling MSI is a cheap, reversible first step. If it already shows **Enabled**, there is nothing to change: our RX 7800 XT was on out of the box, and forcing it off changed nothing we could measure.

### What is the difference between MSI and MSI-X?

MSI-X is the newer extension of MSI with more interrupt vectors and better CPU distribution. Devices already running in MSI-X mode don't need this tweak. NVMe drives are hidden by default for that reason; GPUs are still shown because whether they use MSI/MSI-X depends on the driver.

### How is this different from MSI Util v3 (MSI Mode Utility)?

MSI Util v3 is a closed-source `.exe` passed around via forum threads. This is a readable, open-source PowerShell script that flips the same documented registry value — but it also filters the list down to latency-critical devices, writes a `.reg` undo file before every change, and leaves no binary on your system. Use whichever you prefer — this is the transparent, scriptable option.

### Where are my NVMe drives?

Hidden by the default filter on purpose: NVMe uses MSI-X out of the box, so there is nothing to gain. Use `-ShowAll` if you want to see them anyway.

### How do I re-enable the old interrupt mode?

Double-click the `msi_undo_*.reg` file saved next to the script (or in `%USERPROFILE%` if you used the one-liner) — see [Reverting](#reverting).

### Does disabling MPO (Multiplane Overlay) help with flickering and stutters?

MPO is a DWM display feature, not an interrupt setting, but it shows up in the same troubleshooting threads: on some GPU/driver combinations it causes flickering, black screens, or stutter in windowed games. The classic fix — DWORD `OverlayTestMode = 5` under `HKLM\SOFTWARE\Microsoft\Windows\Dwm` — is being phased out by Microsoft: it works up to Windows 11 23H2, is unreliable on 24H2, and is ignored on 25H2. That's why there is no "MPO disabler" in this series: a tweak that dies with every Windows release isn't worth a utility. On 23H2 or older, try the registry value (delete it to revert); on newer builds, update your GPU driver instead — NVIDIA, AMD, and Microsoft have been shipping MPO fixes on their side.

## Related

- [Interrupt Affinity Utility](https://github.com/vadyaravadim/interrupt-affinity-utility) — pin GPU, network, USB & audio interrupts to specific CPU cores (P/E-core aware) — the natural next step after enabling MSI mode
- [CPU Parking Disabler](https://github.com/vadyaravadim/cpu-parking-disabler) — disable CPU core parking on Windows 10/11 to fix micro-stutters and input lag
- [Timer Resolution Utility](https://github.com/vadyaravadim/timer-resolution-utility) — set 0.5 ms timer resolution, disable dynamic tick, un-force HPET — with a built-in Sleep(1) benchmark
- [GameDVR & FSO Disabler](https://github.com/vadyaravadim/gamedvr-fso-disabler) — disable Game DVR / Xbox Game Bar capture and Fullscreen Optimizations on Windows 10/11 to fix capture stutters and frame drops
- [Remove Hidden Devices](https://github.com/vadyaravadim/remove-hidden-devices) — remove ghost / hidden devices left behind by unplugged USB sticks, headsets & dongles cluttering Device Manager

Same idea across the series: one transparent PowerShell script, no binaries, you see exactly what changes.

## Disclaimer

Editing interrupt settings can, in rare cases, cause a device to fail to start. A reboot and reverting the value fixes it. Use at your own risk.

## License

[MIT](LICENSE) — use at your own risk.

---

<div align="center">

If this helped, consider giving it a ⭐

[Report Issues](https://github.com/vadyaravadim/msi-mode-utility/issues)

</div>
