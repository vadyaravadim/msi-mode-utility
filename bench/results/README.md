# Raw results behind the README and the RigPolice article

Every number quoted in the [README FAQ](../../README.md#does-enabling-msi-mode-reduce-input-lag-or-increase-fps) and in
[the RigPolice deep dive](https://rigpolice.com/system/articles/enable-msi-mode/?utm_source=github&utm_medium=readme&utm_campaign=msi-mode-utility)
comes from the files in this folder. They are the unedited output of [`../msi-bench.ps1`](../msi-bench.ps1), 30 second
runs recorded on 2026-09-18, 2026-09-19 and 2026-09-20. Nothing was dropped: the runs that went wrong are here too,
and the section at the bottom says which ones and why.

## Testbed and load

- Intel Core i9-14900F, AMD Radeon RX 7800 XT (driver 32.0.31041.1004), Windows 11 Pro 25H2 build 26200, Memory
  Integrity on, 180 Hz monitor.
- Load, identical in every run: the [WebGL Aquarium](https://webglsamples.org/aquarium/aquarium.html?numFish=10000)
  with 10,000 fish in Chrome (vsync-capped at 180 fps), plus a quiet 440 Hz tone played through the monitor's
  DisplayPort audio so the audio controller kept interrupting.
- USB runs: the same load plus a mouse moved in fast circles by hand for the whole run (about 7,500 USB interrupts
  per second; the hand is the least repeatable part of this data set).
- Background apps were not controlled. This is a desktop in daily use: a VPN client, a hardware monitor and a
  peripheral updater were running in some sessions.
- Command per run, from an elevated PowerShell: `.\msi-bench.ps1 -Phase <name> -Seconds 30 -Cpu 1`. CPU 1 is the
  core that serves the legacy interrupt lines on this board.

## States

| Files | GPU | USB xHCI | Two HD Audio controllers | Session |
|-------|-----|----------|--------------------------|---------|
| `stock-a/b` | MSI | MSI | shared legacy line, IRQ 17 | 09-18, many hours of uptime |
| `audio-msi-a/b` | MSI | MSI | **MSI** | same session as `stock` |
| `gpu-line-a/b` | **legacy line, IRQ 16** | MSI | shared legacy line, IRQ 17 | 09-18, first boot after the change, about 10 min of uptime |
| `stock-fresh-a/b` | MSI | MSI | shared legacy line, IRQ 17 | 09-19, about 25 min of uptime, no frame data |
| `usb-msi-a/b` | MSI | MSI | shared legacy line, IRQ 17 | same boot as `stock-fresh`, mouse circling, no frame data |
| `usb-line-a/b` | MSI | **legacy line, IRQ 16** | shared legacy line, IRQ 17 | 09-19, next boot, 5 min of uptime, mouse circling |
| `stock-frames-a/b` | MSI | MSI | shared legacy line, IRQ 17 | 09-20, fresh boot, 5 to 7 min of uptime |
| `usb-msi-frames-nomouse` | MSI | MSI | shared legacy line, IRQ 17 | same boot, mouse idle (a control run) |
| `usb-msi-frames-a` … `-h` | MSI | MSI | shared legacy line, IRQ 17 | same boot, 8 to 24 min of uptime, mouse circling |

`msi-bench-*.json` is the script output (interrupt mode table, stall probe, per-driver ISR/DPC statistics).
`frames-*.json` is a frame-time summary computed from a PresentMon 2.5.1 capture of the same 30 seconds
(`MsBetweenPresents` of the busiest `chrome.exe` swap chain; `missed180Hz` counts frames longer than 8.33 ms).

Which files feed which published table:

- Audio pair: `stock-a/b` against `audio-msi-a/b`.
- GPU pair: `stock-frames-a/b` against `gpu-line-a/b` (both fresh boots, both with frame data).
- USB pair, interrupt cost: `usb-msi-a/b` against `usb-line-a/b`. The eight `usb-msi-frames` runs a day later repeat
  the MSI side: 0.20 to 0.23 microseconds per ISR, 5.7 to 5.9 per DPC.

## What went wrong, stated up front

- **`stock-fresh` and `usb-msi` have no frame data, and we found out why.** PresentMon lost every ETW event in that
  boot. The cause was an orphaned `HWiNFO64` real-time ETW session: HWiNFO64 had been closed and its trace session
  stayed behind. While it exists PresentMon captures nothing; `logman stop HWiNFO64 -ets` fixes it on the spot. We
  reproduced both directions on 09-20 (`usb-msi-frames-f` is a partial capture from that experiment). The kernel
  trace and the stall probe were never affected.
- **Frame times under a circling mouse are not a usable comparison.** In five of the eight `usb-msi-frames` runs
  (`a`, `b`, `c`, `e`, `h`) the scene hitched once a second for 50 to 100 ms: 36 to 40 missed frames per run. The
  desktop compositor froze in the same instants, the GPU sat idle, and the kernel trace holds no ISR or DPC longer than
  0.4 ms, so it is not interrupt handling. It did not depend on where the pointer was, on our on-screen prompt
  repainting, or on HWiNFO64 running. Runs `d`, `f`, `g` in the same boot were clean (0 or 1 missed frame), and so
  were both `usb-line` runs the day before. The interrupt numbers are identical in hitching and clean runs. We
  could not find the cause, so the article quotes no frame-time verdict for the USB pair.
- **The GPU's mean ISR time drifts between sessions more than between modes.** With the GPU in MSI mode it ranged
  from 18.9 to 27.6 microseconds across the 21 runs here. The same-conditions pair (`stock-frames` against
  `gpu-line`) came out at 25.3 against 25.4.
- **`Wdf01000.sys` is the USB host controller here** (KMDF dispatches its interrupts). ETW logs KMDF interrupts as
  plain `ISR` events even in MSI mode, so `isrPlain` / `isrMessage` say how a driver connected its interrupt, not
  which mode the device is in. The `devices` table is the ground truth of the mode.
- **Key names were normalized** in the files recorded before 09-20: the script's `isrLine` / `isrMsi` fields were
  renamed to `isrPlain` / `isrMessage` for the reason above. No value was touched.
- One machine, one driver version, one load. Treat it as one careful data point, and run the script on your own PC.
