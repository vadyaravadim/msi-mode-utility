# Raw results behind the MSI mode numbers

Every MSI mode number we publish comes from the two series in this folder. Each boot measured one interrupt-mode
state under one load.

| Series | Load | States | Boots | Recorded (local time) |
|---|---|---|---|---|
| [`msi-six-state/`](msi-six-state/) | Unigine Superposition 1.1, GPU-bound, about 121 fps | 6 | 72 | 2026-11-22 16:52 to 22:42 |
| [`msi-cs2/`](msi-cs2/) | Counter-Strike 2 build 1.42.0.0 at 1280x720, about 734 fps | 3 | 36 | 2026-11-23 19:58 to 2026-11-24 01:06 |

- The `msi-bench` files are the unedited output of [`../msi-bench.ps1`](../msi-bench.ps1). The runner's records
  (`bootNN-state00-msi.json`, `journal.jsonl`) are trimmed to the fields listed under [Files](#files).
- [`msi-six-state.tables.md`](msi-six-state.tables.md) and [`msi-cs2.tables.md`](msi-cs2.tables.md) are the
  complete output of [`../tools/Get-MsiSeriesTable.ps1`](../tools/Get-MsiSeriesTable.ps1) over these folders. The
  `.summary.json` files next to them hold the same numbers plus every per-boot value of the tests. A test in
  `../tests` rebuilds both from the committed files and fails if they differ.
- Tests compare numbers only inside one series. Where the text sets the two loads side by side, it reads no verdict
  from it.

## Short answer

No tested frame time moved. In CS2 the 1% low reads `no difference` in both states tested there; Superposition is
GPU-bound, so its 1% low can only read `cannot show`. The tweak itself, both audio controllers in MSI mode, ran only
under Superposition. One untested number did move, the Superposition 0.1% low of `gpu-line` (see [What the tables
show](#what-the-tables-show)). The tested changes were small and on the kernel side:

- **Audio in MSI mode** (the one change `msi-mode-utility.ps1` makes on this PC) cut the audio driver's interrupt
  time by about 0.3 ms per second, 0.03% of one core.
- **Switching the GPU's audio controller to MSI moved the audio interrupt to another CPU**, in every boot of both
  series. In Superposition about 0.2 points of stalled time left the CPU that serves the GPU and landed on the CPU
  that serves the USB controller.
- **Forcing the USB controller onto a legacy line** made each interrupt routine about eight times as long and raised
  the driver's interrupt time from 15.4 to 21.3 ms per second.
- **Forcing the GPU onto a legacy line** changed its interrupt numbers a little in both directions.

## Testbed

- Intel Core i9-14900F (8 P-cores, 16 E-cores, 32 logical CPUs), MSI MAG B760M MORTAR II (BIOS 1.C0), AMD Radeon
  RX 7800 XT (driver 32.0.32029.2010), one 2560x1440 monitor at 180 Hz.
- Windows 11 Pro 26H2, build 26300.9818, Memory Integrity on, power plan High performance. Every result file
  records the plan's processor settings (`metadata.power`).
- Audio drivers: Realtek High Definition Audio 6.0.10007.1 (motherboard codec) and AMD High Definition Audio
  Device 10.0.1.41 (the GPU's audio output).
- The four devices that change state: the GPU, the USB 3.2 xHCI host controller (mouse, keyboard and, through a
  hub, a Samsung T7 SSD hang off it), the motherboard's HD Audio controller and the GPU's HD Audio controller.
- How to read the drivers: the GPU's interrupts are logged under `dxgkrnl.sys` and its deferred work under
  `amdkmdag.sys`, both HD Audio controllers under `HDAudBus.sys`, and the USB controller under `Wdf01000.sys`.

## States

| State | GPU | Motherboard HD Audio | GPU HD Audio | USB xHCI | Superposition boots | CS2 boots |
|---|---|---|---|---|---|---|
| `stock` | MSI | line IRQ 17, shared | line IRQ 17, shared | MSI | 12 | 12 |
| `audio-msi` | MSI | **MSI** | **MSI** | MSI | 12 | - |
| `mobo-audio-msi` | MSI | **MSI** | line IRQ 17 | MSI | 12 | - |
| `gpu-audio-msi` | MSI | line IRQ 17 | **MSI** | MSI | 12 | 12 |
| `usb-line` | MSI | line IRQ 17, shared | line IRQ 17, shared | **line IRQ 16** | 12 | - |
| `gpu-line` | **line IRQ 16** | line IRQ 17, shared | line IRQ 17, shared | MSI | 12 | 12 |

- `stock` is what the drivers install on this board. Windows' HD Audio bus driver sets `MSISupported` to 0 for the
  motherboard controller, and the GPU's audio driver includes the same HD Audio section, so it also writes 0. The
  GPU and USB drivers set 1.
- `audio-msi` is what `msi-mode-utility.ps1` changes here. `mobo-audio-msi` and `gpu-audio-msi` split it in two, to
  see which controller the effect follows.
- `usb-line` and `gpu-line` force a device that already runs in MSI mode back onto a legacy line. They show the
  ceiling of the effect, not a setting anyone ships.
- The GPU's audio controller carries no sound in any state: the test tone plays on the motherboard codec. Its
  interrupt mode still matters, see [What the tables show](#what-the-tables-show).

## Procedure

- One state per boot. The `MSISupported` value was written before the reboot. Each bench file lists the mode
  every PCI device ran in, read from the sign of its IRQ, not from the registry: a negative IRQ is a
  message-signaled vector, a positive one a line. The table script refuses a series in which a planned device ran
  in another mode or shared a line the plan does not name. All 108 boots matched.
- Order: blocks of six boots (three for CS2), each state once per block. The first six blocks form a Williams
  square: every state runs in every position equally often and directly after every other state equally often.
  Then the same six blocks run again in reverse order. A slow drift over the evening hits every state the same
  way.
- After logon every boot waited 120 s. All physical network adapters were off (`enabledNetworkAdapters` is 0 in
  every record), and 23 services and 18 scheduled tasks that could interfere were switched off for the series and
  restored after it. A preflight refused to measure if a known offender (hardware monitors, overlays, RGB and
  vendor suites, vendor updaters, VPN clients) was running.
- Set by hand before the series, restored after it, and not recorded in these files: Windows application
  prelaunch off (`Disable-MMAgent -ApplicationPreLaunch`; with it on, Windows started the Settings app in the
  background a few minutes after every sign-in), Windows tips off, and one third-party background service on
  manual start.
- Load, the same in every boot of a series, so all three devices were busy at once:
  - GPU, `msi-six-state`: Unigine Superposition 1.1, 2560x1440 fullscreen, DirectX 11, no vsync.
  - GPU, `msi-cs2`: Counter-Strike 2 on the workshop map CS2 FPS BENCHMARK DUST2, a 131 s camera route, at
    1280x720 with no vsync and the video settings of [`../loads/cs2_video.txt`](../loads/cs2_video.txt).
  - Audio: a 440 Hz tone at -40 dBFS looping on the motherboard's Realtek output, which keeps the HD Audio
    controller interrupting (114 interrupts/s).
  - USB: back-to-back 64 KiB reads from a file on the T7 SSD with the Windows file cache bypassed, about 7,200 to
    7,700 xHCI interrupts/s with the controller in MSI mode, close to a mouse polled at 8,000 Hz.
- Superposition: 20 s after the load started, a 5 s kernel trace found the CPU that takes each device's interrupts,
  then one stall probe per CPU was pinned and 60 s were recorded. CS2: from the line the game logs when the route
  starts, a 15 s pause that holds the 5 s pre-trace, then a 100 s window that ends before the route does. Recorded:
  the NT Kernel Logger trace (ISR and DPC time per driver), the stall probes, and PresentMon 2.6.0 frame times.
- A boot is rejected and repeated if PresentMon lost a frame, if its frames covered less than 57 s of the 60 s
  window (95 s of 100 s for CS2), if the frames used more than one present mode, if a .NET garbage collection ran
  inside the window, if a device's interrupt rate fell below the floor in `plan.json` that proves its load was
  running, if the SSD read failed, if one background process or the unattributed CPU time passed the limits in
  `plan.json`, or if the CS2 build differed from the one the plan pins. All 108 boots were accepted on their first attempt.

## How the numbers are judged

The metrics, the test and the verdict words were fixed before either series ran. Three rules were added later, on
two dates, and are listed below. The outcome tables were first built on 2026-11-24, after the last rule was merged.

- **Six metrics per state, each against `stock`, lower is better:**
  1. Stalled share of the stall probe on the CPU that takes the GPU's interrupts (the `dxgkrnl.sys` core).
  2. Gap p99 of that probe.
  3. Stalled share of the probe on the CPU that takes the USB controller's interrupts (the `Wdf01000.sys` core).
  4. Gap p99 of that probe.
  5. 1% low frame time (the 99th percentile).
  6. ISR plus DPC time of the driver whose device changed: `HDAudBus.sys` in the three audio states,
     `dxgkrnl.sys` plus `amdkmdag.sys` in `gpu-line`, `Wdf01000.sys` in `usb-line`.
- **The stall probe** is a time-critical thread spinning on one CPU. A gap is any pause of 2 µs or more; the
  stalled share is the part of the window spent in gaps. The full histogram is in each JSON.
- **Test:** a two-sided exact permutation test of the rank sum, Holm-corrected over all tests of the series (30
  for Superposition, 12 for CS2) at alpha 0.05, and the Hodges-Lehmann shift (state minus stock) with an interval
  of at least 90% confidence.
- **Verdict words:** `helped` or `hurt` when the Holm-adjusted p is under 0.05. `no difference` when the whole
  interval lies strictly inside the margin: 0.3 points of stalled share, 10% of the stock median for gap p99, 0.5
  ms/s of ISR plus DPC time, and for the CS2 1% low 3.3% of the stock median (the Superposition 1% low has no
  margin, see below). `cannot tell` otherwise. A verdict word says the shift is real, not that it is large: read the
  shift next to it.
- **Superposition is GPU-bound**, so by the rule fixed in advance its 1% low can only read `helped`, `hurt` or
  `cannot show`: a flat frame time on such a load proves nothing.
- **Average fps is a load check only.** A state whose median differs from stock by more than 1% is marked; none
  was.
- **Another driver on a probe's CPU.** If a driver other than the changed one loads a probe's CPU differently in
  the state and in `stock` (0.1 points of the core or more), both tests of that CPU read `cannot tell`. It did not
  happen in either series.
- **2026-11-23, after `msi-six-state` and before `msi-cs2` started:** a Windows Error Reporting event outside the
  measured window, with no error-reporting process inside it, is listed below and does not void the series. A boot
  whose probes sit on other CPUs than usual, but on the CPUs its drivers used, stays in the tests, is named in the
  note, and the tests are also reported without it; no boot needed that (boot 27 is covered by the next rule).
- **2026-11-24, after both series, with their journals, device modes and interrupt placement checked and before
  any outcome table was built:** a probe that did not sit on the CPU its driver used in the measured window
  (`cpuPick.devices[].cpu` against `mainTraceCpu`) did not measure that driver's core, so the boot is left out of
  the two tests of that core and kept in every other test. This removed boot 27 of `msi-cs2` from the two
  `dxgkrnl.sys` core tests of `gpu-line`.

## Results

### Superposition, 72 boots

| State | Metric | Probe CPU, stock / state | Stock median | State median | Shift | Shift (% of stock) | Interval | Margin | p (Holm) | Verdict | Note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| audio-msi | Stalled (%), dxgkrnl.sys core | 5 / 5 | 3.68 | 3.44 | -0.23 | -6.26 | [-0.25, -0.18] | +/-0.3 | < 0.001 | helped | - |
| audio-msi | Gap p99 (us), dxgkrnl.sys core | 5 / 5 | 187.55 | 186.8 | -0.8 | -0.43 | [-1.3, -0.4] | +/-18.76 | 0.023 | helped | - |
| audio-msi | Stalled (%), Wdf01000.sys core | 0 / 0 | 2.72 | 2.9 | 0.17 | 6.26 | [0.12, 0.23] | +/-0.3 | < 0.001 | hurt | - |
| audio-msi | Gap p99 (us), Wdf01000.sys core | 0 / 0 | 5.5 | 17.3 | 12 | 218.18 | [11.7, 13.7] | +/-0.55 | < 0.001 | hurt | - |
| audio-msi | 1% low (ms) | - | 8.52 | 8.52 | 0 | -0.05 | [-0.04, 0.03] | - | 1 | cannot show | - |
| audio-msi | ISR+DPC of the changed driver (ms/s) | - | 2.16 | 1.88 | -0.28 | -13.09 | [-0.29, -0.27] | +/-0.5 | 0.004 | helped | - |
| usb-line | Stalled (%), dxgkrnl.sys core | 5 / 5 | 3.68 | 3.68 | 0.02 | 0.54 | [-0.01, 0.08] | +/-0.3 | 1 | no difference | - |
| usb-line | Gap p99 (us), dxgkrnl.sys core | 5 / 5 | 187.55 | 187.3 | 0.05 | 0.03 | [-0.5, 0.7] | +/-18.76 | 1 | no difference | - |
| usb-line | Stalled (%), Wdf01000.sys core | 0 / 0 | 2.72 | 3.28 | 0.57 | 20.99 | [0.5, 0.61] | +/-0.3 | < 0.001 | hurt | - |
| usb-line | Gap p99 (us), Wdf01000.sys core | 0 / 0 | 5.5 | 8.5 | 3 | 54.55 | [2.7, 3.4] | +/-0.55 | < 0.001 | hurt | - |
| usb-line | 1% low (ms) | - | 8.52 | 8.53 | 0.01 | 0.08 | [-0.02, 0.04] | - | 1 | cannot show | - |
| usb-line | ISR+DPC of the changed driver (ms/s) | - | 15.41 | 21.31 | 6.1 | 39.57 | [5.72, 6.38] | +/-0.5 | < 0.001 | hurt | - |
| mobo-audio-msi | Stalled (%), dxgkrnl.sys core | 5 / 5 | 3.68 | 3.6 | -0.03 | -0.82 | [-0.1, -0.01] | +/-0.3 | 0.737 | no difference | - |
| mobo-audio-msi | Gap p99 (us), dxgkrnl.sys core | 5 / 5 | 187.55 | 187.35 | -0.05 | -0.03 | [-0.6, 0.5] | +/-18.76 | 1 | no difference | - |
| mobo-audio-msi | Stalled (%), Wdf01000.sys core | 0 / 0 | 2.72 | 2.74 | 0 | 0 | [-0.05, 0.05] | +/-0.3 | 1 | no difference | - |
| mobo-audio-msi | Gap p99 (us), Wdf01000.sys core | 0 / 0 | 5.5 | 5.45 | -0.1 | -1.82 | [-0.4, 0.3] | +/-0.55 | 1 | no difference | - |
| mobo-audio-msi | 1% low (ms) | - | 8.52 | 8.53 | 0.02 | 0.18 | [-0.02, 0.04] | - | 1 | cannot show | - |
| mobo-audio-msi | ISR+DPC of the changed driver (ms/s) | - | 2.16 | 1.89 | -0.27 | -12.5 | [-0.28, -0.26] | +/-0.5 | 0.004 | helped | - |
| gpu-audio-msi | Stalled (%), dxgkrnl.sys core | 5 / 5 | 3.68 | 3.44 | -0.23 | -6.26 | [-0.26, -0.19] | +/-0.3 | < 0.001 | helped | - |
| gpu-audio-msi | Gap p99 (us), dxgkrnl.sys core | 5 / 5 | 187.55 | 187 | -0.4 | -0.21 | [-1, 0] | +/-18.76 | 1 | no difference | - |
| gpu-audio-msi | Stalled (%), Wdf01000.sys core | 0 / 0 | 2.72 | 2.9 | 0.19 | 7 | [0.12, 0.26] | +/-0.3 | < 0.001 | hurt | - |
| gpu-audio-msi | Gap p99 (us), Wdf01000.sys core | 0 / 0 | 5.5 | 16.7 | 11.3 | 205.45 | [11, 13.1] | +/-0.55 | < 0.001 | hurt | - |
| gpu-audio-msi | 1% low (ms) | - | 8.52 | 8.5 | -0.01 | -0.15 | [-0.05, 0.02] | - | 1 | cannot show | - |
| gpu-audio-msi | ISR+DPC of the changed driver (ms/s) | - | 2.16 | 1.86 | -0.3 | -13.74 | [-0.3, -0.29] | +/-0.5 | 0.003 | helped | - |
| gpu-line | Stalled (%), dxgkrnl.sys core | 5 / 5 | 3.68 | 3.66 | 0.01 | 0.27 | [-0.04, 0.05] | +/-0.3 | 1 | no difference | - |
| gpu-line | Gap p99 (us), dxgkrnl.sys core | 5 / 5 | 187.55 | 191.55 | 4.1 | 2.19 | [3.5, 4.6] | +/-18.76 | < 0.001 | hurt | - |
| gpu-line | Stalled (%), Wdf01000.sys core | 0 / 0 | 2.72 | 2.81 | 0.09 | 3.31 | [0.02, 0.16] | +/-0.3 | 0.156 | no difference | - |
| gpu-line | Gap p99 (us), Wdf01000.sys core | 0 / 0 | 5.5 | 5.6 | 0.1 | 1.82 | [-0.2, 0.4] | +/-0.55 | 1 | no difference | - |
| gpu-line | 1% low (ms) | - | 8.52 | 8.49 | -0.03 | -0.36 | [-0.06, -0.01] | - | 0.177 | cannot show | - |
| gpu-line | ISR+DPC of the changed driver (ms/s) | - | 44.92 | 42.04 | -2.9 | -6.45 | [-3.08, -2.75] | +/-0.5 | < 0.001 | helped | - |

Frames, median [min-max] over the 12 boots of each state:

| State | Boots | Avg FPS | p50 (ms) | 1% low (ms) | 0.1% low (ms) | GPU busy p50 (ms) | CPU busy p50 (ms) | System CPU busy (% of the machine) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| stock | 12 | 121.5 [121.1-121.7] | 8.22 [8.21-8.25] | 8.52 [8.48-9.21] | 10.66 [10.02-17.63] | 8.2 [8.19-8.23] | 8.19 [8.18-8.21] | 8.72 [8.66-8.95] |
| audio-msi | 12 | 121.5 [121.3-121.6] | 8.22 [8.21-8.24] | 8.52 [8.45-10] | 10.21 [8.66-17.06] | 8.2 [8.19-8.22] | 8.19 [8.18-8.2] | 8.72 [8.63-8.93] |
| usb-line | 12 | 121.4 [121.2-121.8] | 8.23 [8.21-8.25] | 8.53 [8.48-8.59] | 10.26 [9.51-18.37] | 8.21 [8.18-8.23] | 8.2 [8.17-8.21] | 8.79 [8.69-9] |
| mobo-audio-msi | 12 | 121.5 [121.3-121.7] | 8.23 [8.21-8.24] | 8.53 [8.48-9.93] | 12.17 [10.02-18.44] | 8.2 [8.19-8.22] | 8.19 [8.17-8.2] | 8.75 [8.67-8.98] |
| gpu-audio-msi | 12 | 121.5 [121.3-121.7] | 8.22 [8.21-8.24] | 8.5 [8.47-8.58] | 11.06 [10.02-16.78] | 8.21 [8.19-8.22] | 8.19 [8.17-8.2] | 8.73 [8.65-8.95] |
| gpu-line | 12 | 121.6 [121.4-121.9] | 8.22 [8.2-8.23] | 8.49 [8.45-8.54] | 8.61 [8.55-11.93] | 8.2 [8.18-8.21] | 8.19 [8.17-8.2] | 8.71 [8.58-8.89] |

### Counter-Strike 2, 36 boots

| State | Metric | Probe CPU, stock / state | Stock median | State median | Shift | Shift (% of stock) | Interval | Margin | p (Holm) | Verdict | Note |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpu-audio-msi | Stalled (%), dxgkrnl.sys core | 2 / 2 | 11.16 | 10.92 | -0.24 | -2.2 | [-0.3, -0.12] | +/-0.3 | 0.095 | cannot tell | - |
| gpu-audio-msi | Gap p99 (us), dxgkrnl.sys core | 2 / 2 | 135.05 | 133.7 | -1.3 | -0.96 | [-1.6, -0.8] | +/-13.5 | 0.002 | helped | - |
| gpu-audio-msi | Stalled (%), Wdf01000.sys core | 0 / 0 | 2.77 | 2.96 | 0.18 | 6.5 | [0.15, 0.21] | +/-0.3 | 0.137 | no difference | - |
| gpu-audio-msi | Gap p99 (us), Wdf01000.sys core | 0 / 0 | 5.4 | 16.8 | 11.3 | 209.26 | [4.4, 11.4] | +/-0.54 | < 0.001 | hurt | - |
| gpu-audio-msi | 1% low (ms) | - | 3.92 | 3.92 | -0.01 | -0.18 | [-0.02, 0] | +/-0.13 | 1 | no difference | - |
| gpu-audio-msi | ISR+DPC of the changed driver (ms/s) | - | 2.37 | 1.9 | -0.71 | -30.01 | [-0.74, -0.2] | +/-0.5 | < 0.001 | helped | - |
| gpu-line | Stalled (%), dxgkrnl.sys core | 2 / 2 | 11.16 | 11.31 | 0.16 | 1.48 | [0.08, 0.29] | +/-0.3 | 0.03 | hurt | probe off the dxgkrnl.sys core in the main trace, left out: gpu-line boot 27 (picked CPU 10, main trace CPU 2) |
| gpu-line | Gap p99 (us), dxgkrnl.sys core | 2 / 2 | 135.05 | 119.3 | -15.65 | -11.59 | [-15.9, -15.2] | +/-13.5 | < 0.001 | helped | probe off the dxgkrnl.sys core in the main trace, left out: gpu-line boot 27 (picked CPU 10, main trace CPU 2) |
| gpu-line | Stalled (%), Wdf01000.sys core | 0 / 0 | 2.77 | 2.76 | -0.01 | -0.36 | [-0.04, 0.01] | +/-0.3 | 1 | no difference | - |
| gpu-line | Gap p99 (us), Wdf01000.sys core | 0 / 0 | 5.4 | 5.4 | 0 | 0 | [-0.1, 0] | +/-0.54 | 1 | no difference | - |
| gpu-line | 1% low (ms) | - | 3.92 | 3.92 | 0 | -0.08 | [-0.01, 0] | +/-0.13 | 1 | no difference | - |
| gpu-line | ISR+DPC of the changed driver (ms/s) | - | 101.88 | 102.08 | 0.3 | 0.29 | [-0.19, 0.87] | +/-0.5 | 1 | cannot tell | - |

Frames, median [min-max] over the 12 boots of each state:

| State | Boots | Avg FPS | p50 (ms) | 1% low (ms) | 0.1% low (ms) | GPU busy p50 (ms) | CPU busy p50 (ms) | System CPU busy (% of the machine) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| stock | 12 | 734 [726.6-740.1] | 1.18 [1.17-1.19] | 3.92 [3.91-3.95] | 4.23 [4.21-4.24] | 1.12 [1.11-1.13] | 1.06 [1.04-1.08] | 32.48 [17.68-34.96] |
| gpu-audio-msi | 12 | 731.85 [727.3-736.4] | 1.18 [1.17-1.19] | 3.92 [3.9-3.95] | 4.23 [4.19-4.26] | 1.12 [1.11-1.12] | 1.08 [1.06-1.09] | 34.22 [31.16-35.24] |
| gpu-line | 12 | 732.6 [705-739.9] | 1.18 [1.17-1.23] | 3.92 [3.91-4] | 4.24 [4.2-4.35] | 1.13 [1.12-1.18] | 1.06 [1.01-1.07] | 32.81 [18.36-34.75] |

The driver, probe and USB read tables of both series are in the `.tables.md` files.

### What the tables show

- **Frames.** In Superposition the median 1% low is 8.49 to 8.53 ms in every state against 8.52 at stock, and all
  five tests read `cannot show`, as a GPU-bound load must. In CS2 it is 3.92 ms in all three states and both tests
  read `no difference`, with intervals of [-0.02, 0] and [-0.01, 0] ms inside a margin of 0.13 ms. No state moved
  the average fps by more than 0.3%.
- **Audio in MSI mode saves the second routine call.** On the shared line an audio interrupt can run the routines of
  both HD Audio controllers. `stock` ran 228 calls/s for 114 interrupts in 10 of 12 Superposition boots (8 of 12 in
  CS2) and 114 calls/s in the others, so the shared line did not cost the second call in every boot. In MSI mode it
  was 114 calls/s in every boot. The audio driver's ISR plus DPC time went from 2.16 to about 1.88 ms per second in
  all three audio states, a saving of 0.03% of one core.
- **The mode of the GPU's audio controller decides which CPU runs the audio routine.** With that controller on
  the line (`stock`, `mobo-audio-msi`, `usb-line`, `gpu-line`) the audio routine ran on the CPU that takes the
  GPU's interrupts (CPU 5 in Superposition, CPU 2 in CS2). With it in MSI mode (`audio-msi`, `gpu-audio-msi`) the
  routine ran on CPU 0, where the USB controller's interrupts land, in 12 of 12 boots of each state in both
  series. The controller itself was silent. With the routine moved its cost: in Superposition the GPU's CPU lost
  0.23 points of stalled share (3.68 to 3.44%), the USB controller's CPU gained 0.17 to 0.19 (2.72 to 2.90%), and
  the USB CPU's gap p99 went from 5.5 to about 17 µs, close to the length of one audio routine (15 µs). Switching
  only the motherboard controller left the routine where it was and changed no probe metric.
- **USB on a legacy line** made each interrupt routine about eight times as long (0.13 to 1.06 µs) and raised the
  driver's ISR plus DPC time from 15.41 to 21.31 ms per second, the stalled share on its CPU from 2.72 to 3.28%
  and that CPU's gap p99 from 5.5 to 8.5 µs. The controller raised fewer interrupts for more data: 5,709/s at
  178 MiB/s against 7,517/s at 157 MiB/s.
- **GPU on a legacy line** raised fewer interrupts in both loads (790/s against 847/s in Superposition, 3,169/s
  against 3,363/s in CS2). In Superposition the two GPU drivers together spent less time in interrupt work (44.92 to
  42.04 ms per second) while the gap p99 on the GPU's CPU grew 2% (187.55 to 191.55 µs). In CS2 the same gap p99
  fell 12% (135.05 to 119.3 µs) while the stalled share rose 0.16 points (11.16 to 11.31%). The directions disagree
  and we cannot explain them from this data. The 1% low reads `no difference` in CS2 and `cannot show` in
  Superposition. One number outside the tests moved: under Superposition the 0.1% low of `gpu-line` was below the
  lowest stock boot (10.02 ms) in 10 of 12 boots, median 8.61 ms against 10.66. We cannot explain that either.

## What went wrong

- **Boot 27 of `msi-cs2` (`gpu-line`).** The 5 s pre-trace found most of the GPU's interrupts on CPU 10, the probe
  was pinned there, and in the measured window every GPU interrupt ran on CPU 2. That boot is left out of the two
  `dxgkrnl.sys` core tests (11 boots against 12) and kept in the others. It is also the slowest boot of the series:
  705 fps against 727 to 740 in the other 35, with the GPU drivers' interrupt time about 45% higher (147 ms per
  second against 101 to 103). It was the only boot without a spinning probe on the GPU's CPU.
- **The CS2 series first refused to start.** Steam had updated the game from 1.41.9.6 to 1.42.0.0 and the plan
  pinned the old build, so the runner rejected the first boot twice and restored the PC. Nothing from that start
  is in the folder. The plan was changed to 1.42.0.0, a 6-boot smoke run was repeated on it, and then the series
  ran.
- **Xbox Game Bar crashed three times in the CS2 series**, 10 s after the game started in boots 3, 7 and 30, about
  a minute before the measured window opened. Source: the testbed's Windows event log, which is not published.
- **Retried reads on the USB SSD.** Windows logged 4 retried reads on the T7 during `msi-six-state` (boots 14, 64
  and 70), one of them inside the window of boot 64, and 12 during `msi-cs2`, all outside the windows. The read
  rate in every record shows no error. Source: the Windows event log.
- **Unplaced activity on CPU 0 in five CS2 boots.** In boots 0, 5, 13 and 16 the probe on the USB controller's CPU
  shows a gap p99 near 12.5 µs against 5.4 µs in the other boots of their states, and in boot 25 23 µs against
  16.8, with no extra driver interrupts on that CPU. The trace records DPCs per driver, not per CPU, so a driver
  with DPCs and no interrupts cannot be placed.
- **The machine was half to three quarters as busy as usual in four early CS2 boots.** Boots 0, 4, 6 and 7 show 18
  to 24% of the machine busy against 30 to 35% in the rest, at the same frame rate.
- **Lost trace events.** The kernel trace lost 1 event in boot 46 of `msi-six-state`, and 1 event in each of 8
  boots and 2 in one boot of `msi-cs2` (`trace.droppedEvents`).

## Files

Names are `bootNN-state00-...`: the boot index; every boot measured one state.

- `msi-bench-bootNN-state00.json`: the interrupt mode table, the CPU each driver was found on in the pre-trace and
  in the measured window (`cpuPick`), the per-driver ISR and DPC statistics with per-CPU interrupt counts, the stall
  probes with histograms, the frame statistics, the background load figures (tone, SSD read rate), and the bench
  script's hash, OS build and power settings.
- `msi-bench-bootNN-state00-stalls.csv`: every probe gap of 1 ms or more, with its offset in the window.
- `bootNN-state00-msi.json`: the runner's record of the boot: the state applied, the testbed fields the tables need
  (CPU name, board and BIOS version, GPU, audio and chipset drivers, Memory Integrity, microcode, timer flags,
  explicit power settings, the count of enabled network adapters) and the list of bench files.
- `bootNN-state00-msi-bench.log`: the console output of the bench.
- `journal.jsonl`: the runner's log of every boot. `plan.json`: the full plan, with the state of each boot, the
  interrupt-rate floors and the CPU limits.
- The per-frame PresentMon logs named in each record (`msi-bench-bootNN-state00-presentmon.csv`, 127 MiB for
  `msi-six-state` and 610 MiB for `msi-cs2`) are too large for the repository. They are attached to the releases
  [`bench-data-msi-six-state`](https://github.com/vadyaravadim/msi-mode-utility/releases/tag/bench-data-msi-six-state)
  and [`bench-data-msi-cs2`](https://github.com/vadyaravadim/msi-mode-utility/releases/tag/bench-data-msi-cs2).
  The tables need only the frame statistics in the JSON.
- No program, process, service or device inventory of the PC is published, beyond the PCI interrupt-mode table and
  the per-driver ISR and DPC table, which are the measurement. User names, the machine name and account IDs are not
  in any file.

To rebuild the tables, run from the `bench` folder:

```powershell
.\tools\Get-MsiSeriesTable.ps1 -SeriesPath .\results\msi-six-state -MarkdownPath tables.md -SummaryPath summary.json
```

## Caveats

- **Verdict words are about certainty, not size.** `hurt` on a 12 µs change of a p99 gap is still 12 µs.
- **The CS2 load is not purely CPU-bound.** PresentMon's GPU busy time (median 1.12 ms) fills about 95% of the 1.18
  ms median frame, so the GPU had little slack. Its CPU busy time (1.06 ms) proves no CPU limit either: under
  GPU-bound Superposition the same number reads 8.19 ms of an 8.22 ms frame.
- **The probe is part of the system it measures.** A time-critical thread spins on each measured CPU for the whole
  window, in every state.
- **Frame time and interrupt time are not input lag.** That needs an end-to-end instrument.
- One machine, one GPU, two loads. Treat it as one careful data point, and run the bench on your own PC.
