# Raw results behind the MSI mode numbers

Every MSI mode number we publish comes from the files in [`msi-retest/`](msi-retest/). They are the unedited output
of [`../msi-bench.ps1`](../msi-bench.ps1), 32 runs recorded across 32 boots between 2026-11-06 18:31 and 23:15. The
per-frame PresentMon logs are in the release
[`bench-data-msi-retest`](https://github.com/vadyaravadim/msi-mode-utility/releases/tag/bench-data-msi-retest) as
`msi-retest-presentmon.zip`, SHA256 `9cc32fbd91c40af9d6eeafc9b50ccf3bc0809fc9ac495bca805e4910d1e611ba`.

## Testbed

- Intel Core i9-14900F (8 P-cores, 16 E-cores, 32 logical CPUs), MSI MAG B760M MORTAR II (BIOS 1.C0), AMD Radeon
  RX 7800 XT (driver 32.0.32015.7029), 180 Hz monitor.
- Windows 11 Pro 26H2, build 26300.9818, Memory Integrity on, power plan High performance (no core parking). Every
  result file records the full environment.
- The devices that change state: the GPU, the USB 3.2 xHCI host controller (mouse, keyboard and a Samsung T7 SSD
  hang off it), the motherboard's HD Audio controller (Realtek codec) and the GPU's HD Audio controller.

## Procedure

- One state per boot. The interrupt mode (`MSISupported` under the device's `Interrupt Management` key) was written
  before the reboot, and after logon the runner checked the mode by the sign of the device's IRQ, not by the
  registry: a negative IRQ is a message-signaled vector, a positive one a line. A boot in the wrong mode would have
  failed before measuring; none did.
- Every boot then waited 300 s for startup activity to settle. Background services, scheduled tasks and startup apps
  that could interfere were switched off for the whole series, and a preflight refused to measure if a known offender
  (hardware monitors, overlays, RGB and vendor suites, updaters, VPN clients) was running.
- 8 boots per state, ordered by a Williams Latin square followed by its mirror, so every state ran in every position
  equally often and a slow drift over the evening affects every state the same way.
- Load, the same in every run, so all three devices were busy at once:
  - GPU: Unigine Superposition 1.1, 2560x1440 fullscreen, DirectX 11, no vsync, about 120 fps and GPU-bound.
  - Audio: a 440 Hz tone at -40 dBFS looping on the Realtek output, which keeps the HD Audio controller
    interrupting (114 interrupts/s).
  - USB: back-to-back 64 KiB reads from a file on the T7 SSD with the Windows file cache bypassed, about 8,000
    xHCI interrupts/s, the range of a mouse polled at 8 kHz.
- 20 s after the load started, the bench ran a 5 s kernel trace to find the CPU that takes each device's interrupts,
  then pinned one stall probe per CPU and recorded 60 s: the NT Kernel Logger trace (ISR and DPC time per driver),
  the stall probes, and PresentMon 2.6.0 frame times. A run was rejected if PresentMon lost any frame, if its frames
  covered less than 57 s of the window, or if a device's interrupt rate fell below a floor that proves its load was
  running. No run was rejected.
- How to read the drivers: the AMD GPU's interrupts are logged under `dxgkrnl.sys`, both HD Audio controllers under
  `HDAudBus.sys`, and the USB controller under `Wdf01000.sys`.

## States

| State | GPU | HD Audio (both) | USB xHCI | Boots |
|---|---|---|---|---|
| `stock` | MSI | line IRQ 17, shared | MSI | 8 |
| `audio-msi` | MSI | **MSI** | MSI | 8 |
| `gpu-line` | **line IRQ 16** | line IRQ 17, shared | MSI | 8 |
| `usb-line` | MSI | line IRQ 17, shared | **line IRQ 16** | 8 |

`stock` is what the drivers install on this board: Windows' HD Audio bus driver sets `MSISupported` to 0 for the
motherboard controller, and the GPU's audio driver includes the same HD Audio section, so it also writes 0. The GPU and USB
drivers set 1. `audio-msi` is what `msi-mode-utility.ps1` changes here. `gpu-line` and `usb-line` force a device that already runs
in MSI mode back onto a legacy line, to show the ceiling of the effect, not a setting anyone ships.

## Results

Frames, one value per run (medians across runs; lower ms is better):

| State | n | Avg fps, median [min-max] | p50 ms | 1% low ms, median [min-max] | 0.1% low ms |
|---|---|---|---|---|---|
| stock | 8 | 120.0 [119.5-120.3] | 8.278 | 9.044 [9.023-9.081] | 9.232 |
| audio-msi | 8 | 120.7 [120.4-120.8] | 8.271 | 8.760 [8.689-8.800] | 9.010 |
| gpu-line | 8 | 121.4 [120.9-122.2] | 8.189 | 8.945 [8.536-9.000] | 9.090 |
| usb-line | 8 | 120.2 [119.9-120.4] | 8.266 | 9.034 [9.005-9.073] | 9.176 |

Interrupt cost per driver (medians across runs). ISR is the interrupt routine, DPC the deferred work it queues:

| Driver | State | CPU | ISR/s | ISR mean µs | DPC mean µs | DPC p99 µs |
|---|---|---|---|---|---|---|
| `HDAudBus.sys` | stock | 0 | 228 | 8.68 | 2.66 | 10.7 |
| | audio-msi | 1 | 114 | 15.06 | 1.98 | 7.2 |
| `dxgkrnl.sys` | stock | 1 | 906 | 21.08 | 1.48 | 8.5 |
| | gpu-line | 1 | 876 | 21.12 | 3.95 | 116.0 |
| `Wdf01000.sys` | stock | 0 | 8252 | 0.18 | 2.45 | 3.8 |
| | usb-line | 0 | 6333 | 1.11 | 3.44 | 5.4 |

Stall probe, a time-critical thread spinning on the CPU that takes the device's interrupts. A gap is any pause of 2 µs
or more; the full histogram is in each JSON:

| State | CPU 0 stalled %, median [min-max] | CPU 0 gap p50 µs | CPU 1 stalled %, median [min-max] | CPU 1 gap p50 µs |
|---|---|---|---|---|
| stock | 5.98 [5.82-6.39] | 3.8 | 6.13 [5.75-6.56] | 15.2 |
| audio-msi | 5.74 [5.43-6.42] | 3.8 | 5.92 [5.80-6.56] | 17.4 |
| gpu-line | 5.85 [5.43-6.30] | 3.7 | 5.84 [5.59-6.79] | 16.8 |
| usb-line | 6.53 [6.02-7.02] | 5.5 | 5.74 [5.49-6.53] | 15.3 |

What the tables show:

- **Audio on MSI** is the change that `msi-mode-utility.ps1` makes, and it moves frames outside the run-to-run
  spread: +0.6% average fps and a 3% better 1% low, with no overlap between the eight runs of each state. On the
  shared line every audio interrupt runs the routines of both HD Audio controllers (228 calls/s for 114 interrupts)
  on CPU 0; in MSI mode each interrupt runs one routine on CPU 1, where the GPU's interrupts also land.
- **GPU on a legacy line** keeps the same routine cost but its deferred work gets slower (DPC p99 8.5 → 116 µs),
  yet the frame rate is 1.2% higher with no overlap. We cannot explain that from this data.
- **USB on a legacy line** makes each interrupt about 6 times as expensive (0.18 → 1.11 µs) and raises the median
  probe gap on its CPU from 3.8 to 5.5 µs. The controller raised fewer interrupts for more data (6,333/s at 199 MiB/s
  against 8,252/s at 175 MiB/s). Frames do not change.
- The stalled share of a probe sits near 6% in every state; its spread is wider than any difference between states,
  so it backs no verdict here.

## Files

Names are `bootNN-state00-...`: the boot index (0 to 31); every boot measured one state.

- `bootNN-state00-msi.json`: the runner's record of the run: the state applied, the environment, CPU time per
  process, the background load figures (tone, SSD read rate) and the list of bench files.
- `bootNN-state00-msi-bench.log`: the console output of the bench.
- `msi-bench-bootNN-state00.json`: the interrupt mode table, the CPU each driver was found on, the per-driver ISR and
  DPC statistics with per-CPU counts, the stall probes with histograms, and the frame statistics. The matching
  `-presentmon.csv` is in the release archive.
- `msi-bench-bootNN-state00-stalls.csv`: every probe gap of 1 ms or more, with its offset in the window.
- `journal.jsonl`: the runner's log of every boot. `plan.json`: the full plan, with the state of each boot.
- User names, the machine name and account IDs are removed from every file; profile paths read `%USERPROFILE%`.

## Caveats

- **Most runs carry one long gap.** Both probes paused for 8 to 13 ms at the same instant once per run: in 21 of the
  24 `stock`, `audio-msi` and `gpu-line` runs 58.5 to 59.9 s into the 60 s window, as PresentMon finishes its
  capture; in `usb-line` 5 of 8 runs about 9.3 s in and one at the start, none at the end. We did not find the
  cause. The tables quote no probe maximum for this reason.
- One machine, one GPU, one load. Treat it as one careful data point, and run the bench on your own PC.
