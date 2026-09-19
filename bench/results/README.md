# Raw results behind the README and the RigPolice article

Every number quoted in the [README FAQ](../../README.md#does-enabling-msi-mode-reduce-input-lag-or-increase-fps) and in
[the RigPolice deep dive](https://rigpolice.com/system/articles/enable-msi-mode/?utm_source=github&utm_medium=readme&utm_campaign=msi-mode-utility)
comes from the files in this folder. They are the unedited output of [`../msi-bench.ps1`](../msi-bench.ps1), two
30 second runs (`-a`, `-b`) per state, recorded 2026-09-18 and 2026-09-19.

## Testbed and load

- Intel Core i9-14900F, AMD Radeon RX 7800 XT (driver 32.0.31041.1004), Windows 11 Pro 25H2 build 26200, Memory
  Integrity on, 180 Hz monitor.
- Load, identical in every run: the [WebGL Aquarium](https://webglsamples.org/aquarium/aquarium.html?numFish=10000)
  with 10,000 fish in Chrome (vsync-capped at 180 fps), plus a quiet 440 Hz tone played through the monitor's
  DisplayPort audio so the audio controller kept interrupting.
- USB runs: the same load plus a mouse moved in fast circles by hand for the whole run (about 7,500 USB interrupts
  per second; the hand is the least repeatable part of this data set).
- Command per run, from an elevated PowerShell: `.\msi-bench.ps1 -Phase <name> -Seconds 30 -Cpu 1`. CPU 1 is the
  core that serves the legacy interrupt lines on this board.

## States

| Files | GPU | USB xHCI | Two HD Audio controllers | Session |
|-------|-----|----------|--------------------------|---------|
| `stock-a/b` | MSI | MSI | shared legacy line, IRQ 17 | many hours of uptime |
| `stock-fresh-a/b` | MSI | MSI | shared legacy line, IRQ 17 | second boot, about 25 min of uptime |
| `audio-msi-a/b` | MSI | MSI | **MSI** | same session as `stock` |
| `gpu-line-a/b` | **legacy line, IRQ 16** | MSI | shared legacy line, IRQ 17 | first boot after the change, about 10 min of uptime |
| `usb-msi-a/b` | MSI | MSI | shared legacy line, IRQ 17 | same boot as `stock-fresh`, mouse circling |
| `usb-line-a/b` | MSI | **legacy line, IRQ 16** | shared legacy line, IRQ 17 | third boot, 5 min of uptime, mouse circling |

`msi-bench-*.json` is the script output (interrupt mode table, stall probe, per-driver ISR/DPC statistics).
`frames-*.json` is a frame-time summary computed from a PresentMon 2.5.1 capture of the same 30 seconds
(`MsBetweenPresents` of the busiest `chrome.exe` swap chain).

## Known gaps, stated up front

- **No frame data for `stock-fresh` and `usb-msi`.** In that boot session PresentMon lost every ETW event and wrote
  nothing, elevated or not. The kernel trace and the stall probe are unaffected. Stock frame times therefore come
  from the long-uptime `stock` session.
- **The GPU's mean ISR time is noisy between runs.** With the GPU in MSI mode it ranged from 18.9 to 25.9 microseconds
  across the ten runs here. The legacy-line result (25.3 to 25.5) sits inside that spread, so this data does not
  show a GPU difference.
- **`Wdf01000.sys` is the USB host controller here** (KMDF dispatches its interrupts). ETW logs KMDF interrupts as
  plain `ISR` events even in MSI mode, so `isrPlain` / `isrMessage` say how a driver connected its interrupt, not
  which mode the device is in. The `devices` table is the ground truth of the mode.
- **Key names were normalized.** The first runs were recorded before the script's `isrLine` / `isrMsi` fields were
  renamed to `isrPlain` / `isrMessage` for the reason above. The keys in these files were renamed to match the
  published script; no value was touched.
- One machine, one driver version, one load. Treat it as one careful data point, and run the script on your own PC.
