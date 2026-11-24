## Testbed

| Item | Value |
| --- | --- |
| Windows | 26H2 build 26300.9818 |
| CPU | Intel(R) Core(TM) i9-14900F |
| Board and BIOS | Micro-Star International Co., Ltd. MAG B760M MORTAR II (MS-7E13), BIOS 1.C0 |
| GPU driver | AMD Radeon RX 7800 XT 32.0.32029.2010 |
| Audio drivers | Realtek High Definition Audio 6.0.10007.1; AMD High Definition Audio Device 10.0.1.41 |
| Power scheme | 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c |
| Explicit power settings recorded | yes |
| Present mode | Hardware: Independent Flip |
| Refresh rate | 180 Hz |
| Load | cs2 1.42.0.0 |
| PresentMon | 2.6.0 |
| Settle before capture | 120 s |
| Enabled physical network adapters | 0 |
| Boots | 36 |
| Disabled services | 23 |
| Disabled tasks | 18 |
| Disabled startup | 0 |

## Checks that passed before these tables were written

| Check | Source | Repeatable from the bench JSON | Status |
| --- | --- | --- | --- |
| one accepted result per boot | private runner journal.jsonl and plan.json | no, needs the private runner | passed |
| interrupt mode of every planned device equals its state | bench JSON devices[].MSISupported, Mode | yes | passed |
| line sharing equals the plan where the plan sets it | private runner plan.json sharedWith, bench JSON devices[].SharedWith | no, needs the private runner | passed |
| OS build and UBR identical | bench JSON metadata.os | yes | passed |
| power scheme GUID and processor values identical | bench JSON metadata.power | yes | passed |
| present mode identical | bench JSON frames.presentModes | yes | passed |
| GPU and audio driver versions identical | private runner wrapper environment.drivers | no, needs the private runner | passed |
| explicit power settings identical | private runner wrapper environment.powerExplicit | no, needs the private runner | passed |
| bench script, PresentMon, load build, video config and refresh rate identical | bench JSON metadata.benchScript, metadata.presentMonVersion, presentMon, load, frames.refreshHz | yes | passed |
| HVCI, BIOS version, microcode, clock flags and enabled network adapters identical | private runner wrapper environment | no, needs the private runner | passed |
| tone played on the planned audio controller | bench JSON background.tone.controllerInstanceId | yes | passed |

## Pre-registered tests

Each state against stock, lower is better for every metric: a two-sided exact permutation test of the rank sum, Holm-corrected over the 12 tests at alpha 0.05, and the Hodges-Lehmann shift (state minus stock) with an interval of at least 90% confidence.
Verdicts: helped or hurt when the Holm-adjusted p is under 0.05; no difference when the whole interval lies strictly inside the margin; cannot tell otherwise. A test of a probe core reads cannot tell, whatever its p and interval, when the load of another driver on that core differs between the state and stock by 0.1 points or more (table Other drivers on the probe cores). The note names the boots whose probe core differs and the drivers that moved.
Each probe sits on the CPU a pre-trace picked for its driver. A boot whose main trace put most of that driver's ISRs on another CPU, or recorded none, did not measure the driver's core: it is left out of the tests of that core and of its loads in Other drivers on the probe cores, and kept in every other test. The note names it with the picked CPU and the main-trace CPU.

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

Average FPS is a load check only: a state whose median differs from the stock median by more than 1% is marked load differs on every row above, and the mark changes no verdict.

| State | Avg FPS, stock median | Avg FPS, state median | Difference (%) | Load |
| --- | --- | --- | --- | --- |
| gpu-audio-msi | 734 | 731.85 | -0.29 | same |
| gpu-line | 734 | 732.6 | -0.19 | same |

## Other drivers on the probe cores

Load of a driver on the probe core of dxgkrnl.sys or Wdf01000.sys: its share of ISRs on that CPU times its ISR plus DPC time, in % of one core. The core's own driver and the changed drivers of the state are left out. Median over the boots, listed when either median is at least 0.1%; moved when the two medians differ by 0.1 points or more.

| State | Probe core of | Driver | Stock median (% of the core) | State median | Moved |
| --- | --- | --- | --- | --- | --- |
| gpu-line | dxgkrnl.sys | HDAudBus.sys | 0.24 | 0.22 | no |

## Frames

Median [min-max] over the boots of each state. 1% low and 0.1% low are the 99th and 99.9th percentile frame time.

| State | Boots | Avg FPS | p50 (ms) | 1% low (ms) | 0.1% low (ms) | GPU busy p50 (ms) | CPU busy p50 (ms) | System CPU busy (% of the machine) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| stock | 12 | 734 [726.6-740.1] | 1.18 [1.17-1.19] | 3.92 [3.91-3.95] | 4.23 [4.21-4.24] | 1.12 [1.11-1.13] | 1.06 [1.04-1.08] | 32.48 [17.68-34.96] |
| gpu-audio-msi | 12 | 731.85 [727.3-736.4] | 1.18 [1.17-1.19] | 3.92 [3.9-3.95] | 4.23 [4.19-4.26] | 1.12 [1.11-1.12] | 1.08 [1.06-1.09] | 34.22 [31.16-35.24] |
| gpu-line | 12 | 732.6 [705-739.9] | 1.18 [1.17-1.23] | 3.92 [3.91-4] | 4.24 [4.2-4.35] | 1.13 [1.12-1.18] | 1.06 [1.01-1.07] | 32.81 [18.36-34.75] |

## Drivers

Every driver whose median ISR plus DPC time is at least 0.5 ms/s in any state. Median [min-max] over the boots of each state.

| Driver | State | ISR/s | ISR mean (us) | ISR (ms/s) | DPC/s | DPC mean (us) | DPC p99 (us) | DPC (ms/s) | CPU of the ISR |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| amdkmdag.sys | stock | 0 [0-0] | 0 [0-0] | 0 [0-0] | 3354.87 [3321-3390.47] | 18.27 [18.06-18.8] | 61.5 [60.9-62.3] | 61.4 [60.64-62.43] | - |
| amdkmdag.sys | gpu-audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 3348.45 [3321.74-3364.96] | 18.2 [18.02-18.39] | 60.25 [60-60.7] | 60.88 [60.53-61.46] | - |
| amdkmdag.sys | gpu-line | 0 [0-0] | 0 [0-0] | 0 [0-0] | 3105.1 [2905.58-3129.48] | 19.98 [19.72-32.12] | 70.95 [70.5-120.6] | 62.11 [61.35-93.34] | - |
| dxgkrnl.sys | stock | 3363.38 [3335.24-3397.93] | 10.56 [10.49-10.67] | 35.59 [35.33-35.67] | 5778.16 [5727.06-5832.17] | 0.84 [0.84-0.87] | 2 [2-2.1] | 4.88 [4.82-4.98] | 2 |
| dxgkrnl.sys | gpu-audio-msi | 3358.22 [3331.09-3373.12] | 10.59 [10.52-10.64] | 35.52 [35.31-35.7] | 5773.93 [5733.61-5799.46] | 0.84 [0.83-0.85] | 2 [2-2.1] | 4.86 [4.78-4.91] | 2 |
| dxgkrnl.sys | gpu-line | 3169.25 [3032.15-3194.31] | 10.98 [10.9-15.55] | 34.82 [34.6-47.15] | 5507.8 [4994.42-5543.5] | 0.94 [0.93-1.33] | 2.2 [2.2-3.8] | 5.15 [5.13-6.65] | 2 |
| storport.sys | stock | 180.17 [177.77-195.21] | 1.3 [1.25-1.35] | 0.23 [0.22-0.24] | 2647.22 [2639.23-2667.95] | 6.14 [6.07-6.18] | 12.6 [12.3-12.7] | 16.24 [16.07-16.37] | 19, 21, 26, 29, 30, 31 |
| storport.sys | gpu-audio-msi | 178.48 [176.84-180.71] | 1.32 [1.29-1.39] | 0.23 [0.23-0.25] | 2647.12 [2632.26-2656.81] | 6.12 [6.07-6.16] | 12.6 [12.4-12.7] | 16.16 [16.11-16.37] | 19, 25, 27, 29, 30 |
| storport.sys | gpu-line | 174.48 [171.57-178.23] | 1.32 [1.3-1.36] | 0.23 [0.23-0.24] | 2645.84 [2640.55-2660.88] | 6.11 [6.01-6.19] | 12.6 [12.4-12.7] | 16.2 [15.97-16.37] | 19, 25, 26, 29, 30 |
| Wdf01000.sys | stock | 7401.33 [7375.09-7418.02] | 0.16 [0.16-0.17] | 1.21 [1.16-1.28] | 7401.33 [7375.09-7418.02] | 2.04 [1.98-2.06] | 3.1 [3.1-3.2] | 15.06 [14.68-15.23] | 0 |
| Wdf01000.sys | gpu-audio-msi | 7397.31 [7359.23-7425.83] | 0.17 [0.16-0.18] | 1.22 [1.15-1.3] | 7397.31 [7359.23-7425.83] | 2.04 [2-2.07] | 3.15 [3.1-3.2] | 15.06 [14.77-15.32] | 0 |
| Wdf01000.sys | gpu-line | 7413.31 [7394.15-7455.56] | 0.16 [0.16-0.17] | 1.19 [1.17-1.25] | 7413.31 [7394.15-7455.56] | 2.02 [1.98-2.07] | 3.1 [3-3.2] | 15.04 [14.74-15.31] | 0 |
| ntoskrnl.exe | stock | 0 [0-0] | 0 [0-0] | 0 [0-0] | 999.25 [967.26-1074.72] | 12.26 [11.62-12.76] | 51.3 [49.9-56.2] | 12.5 [11.38-12.91] | - |
| ntoskrnl.exe | gpu-audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 1017.18 [966.88-1031.33] | 12.37 [11.78-12.59] | 50.95 [49.7-52] | 12.55 [11.39-12.91] | - |
| ntoskrnl.exe | gpu-line | 0 [0-0] | 0 [0-0] | 0 [0-0] | 1013.29 [968.87-1041.58] | 12.32 [11.28-12.65] | 51.4 [50.9-52.6] | 12.36 [11.75-12.9] | - |
| HDAudBus.sys | stock | 227.85 [113.93-228.14] | 10.34 [7.23-15.25] | 2.08 [1.43-2.39] | 114.05 [114-114.1] | 2.56 [2.48-2.63] | 10.5 [10.5-10.7] | 0.29 [0.28-0.3] | 2 |
| HDAudBus.sys | gpu-audio-msi | 114.04 [113.96-114.07] | 14.35 [7.9-14.38] | 1.64 [0.9-1.64] | 114.08 [114-114.1] | 2.36 [2.31-2.38] | 10.2 [10.1-10.2] | 0.27 [0.26-0.27] | 0 |
| HDAudBus.sys | gpu-line | 120.96 [119.73-233.21] | 15.12 [9.56-15.42] | 1.85 [1.8-2.53] | 114.04 [113.99-114.14] | 2.7 [2.63-3.5] | 15.05 [12.6-17.8] | 0.31 [0.3-0.4] | 2 |

## Probes

Median [min-max] over the boots of each state. Stalls of 1 ms or more counts the rows of the stall file on that CPU in one boot.

| State | Probe CPU | Drivers on the core | Stalled (%) | Gap p50 (us) | Gap p99 (us) | Gap p99.9 (us) | Stalls of 1 ms or more |
| --- | --- | --- | --- | --- | --- | --- | --- |
| stock | 0 | Wdf01000.sys | 2.77 [2.73-3.05] | 3.3 [3.3-3.4] | 5.4 [5.4-12.9] | 6.9 [6.8-34.6] | 0 [0-0] |
| stock | 2 | dxgkrnl.sys, HDAudBus.sys | 11.16 [10.82-11.27] | 19.55 [19.1-19.9] | 135.05 [133.5-136.1] | 195.9 [194.9-196.7] | 0 [0-0] |
| gpu-audio-msi | 0 | HDAudBus.sys, Wdf01000.sys | 2.96 [2.9-3.22] | 3.3 [3.3-3.4] | 16.8 [9.1-23] | 30.2 [30.2-34.4] | 0 [0-0] |
| gpu-audio-msi | 2 | dxgkrnl.sys | 10.92 [10.56-10.98] | 19.4 [19.2-19.7] | 133.7 [133.1-134.9] | 194.9 [194-195.3] | 0 [0-0] |
| gpu-line | 0 | Wdf01000.sys | 2.76 [2.73-3.02] | 3.3 [3.3-3.4] | 5.4 [5.4-12.5] | 6.9 [6.8-33.5] | 0 [0-0] |
| gpu-line | 2 | dxgkrnl.sys, HDAudBus.sys | 11.31 [10.9-11.49] | 20.1 [19.9-20.5] | 119.3 [119.1-119.7] | 194.3 [192.2-195.3] | 0 [0-0] |
| gpu-line | 10 | dxgkrnl.sys off this core in boot 27 (main trace CPU 2), HDAudBus.sys off this core in boot 27 (main trace CPU 2) | 0.14 [0.14-0.14] | 2.5 [2.5-2.5] | 10.5 [10.5-10.5] | 43.1 [43.1-43.1] | 0 [0-0] |

## Runs with a gap of 5 ms or more

| State | Runs with such a gap | Offsets from the start of the stall timeline |
| --- | --- | --- |
| stock | 0 of 12 | - |
| gpu-audio-msi | 0 of 12 | - |
| gpu-line | 0 of 12 | - |

## USB reads

| State | MiB/s |
| --- | --- |
| stock | 154.25 [153.6-154.6] |
| gpu-audio-msi | 154.2 [150.3-154.9] |
| gpu-line | 154.45 [154-155] |

## Table to file map

| Table | File | Fields | Needs the private runner |
| --- | --- | --- | --- |
| Pre-registered tests | msi-bench-bootNN-stateNN.json, bench/loads/<load.name>.json | probes[].devices, probes[].cpu, cpuPick.devices[].driver, cpuPick.devices[].cpu, cpuPick.devices[].mainTraceCpu, probes[].stalledPct, probes[].gapP99Us, frames.low1PctMs, frames.avgFps, trace.seconds, trace.drivers[].isrTotalUs, trace.drivers[].dpcTotalUs, trace.drivers[].isrPlain, trace.drivers[].isrMessage, trace.drivers[].isrPerCpu, load.name; the recipe bottleneck | no |
| Frames | msi-bench-bootNN-stateNN.json | frames.*, systemCpu | no |
| Drivers | msi-bench-bootNN-stateNN.json | trace.seconds, trace.drivers[] | no |
| Probes | msi-bench-bootNN-stateNN.json, msi-bench-bootNN-stateNN-stalls.csv | probes[], cpuPick.devices[]; stall file rows per cpu | no |
| Runs with a gap of 5 ms or more | msi-bench-bootNN-stateNN-stalls.csv | cpu, offsetMs, gapUs | no |
| USB reads | msi-bench-bootNN-stateNN.json | background.usbRead.mibPerSecond | no |
| Testbed: OS, power, present mode, load, PresentMon | msi-bench-bootNN-stateNN.json | metadata.*, frames.presentModes, load | no |
| Testbed: CPU, BIOS, drivers, explicit power settings | bootNN-stateNN-msi.json | environment.* | yes |
| Testbed: counts of disabled services, tasks and startup items | journal.jsonl | start event services, tasks, startup counts | yes |
| State labels and device modes | plan.json | boots[].label, boots[].states[].devices[] | yes |

| State | Boots | Bench JSON files |
| --- | --- | --- |
| stock | 0, 5, 7, 11, 12, 16, 19, 21, 26, 28, 32, 33 | msi-bench-boot00-state00.json, msi-bench-boot05-state00.json, msi-bench-boot07-state00.json, msi-bench-boot11-state00.json, msi-bench-boot12-state00.json, msi-bench-boot16-state00.json, msi-bench-boot19-state00.json, msi-bench-boot21-state00.json, msi-bench-boot26-state00.json, msi-bench-boot28-state00.json, msi-bench-boot32-state00.json, msi-bench-boot33-state00.json |
| gpu-audio-msi | 1, 3, 8, 10, 14, 15, 18, 23, 25, 29, 30, 34 | msi-bench-boot01-state00.json, msi-bench-boot03-state00.json, msi-bench-boot08-state00.json, msi-bench-boot10-state00.json, msi-bench-boot14-state00.json, msi-bench-boot15-state00.json, msi-bench-boot18-state00.json, msi-bench-boot23-state00.json, msi-bench-boot25-state00.json, msi-bench-boot29-state00.json, msi-bench-boot30-state00.json, msi-bench-boot34-state00.json |
| gpu-line | 2, 4, 6, 9, 13, 17, 20, 22, 24, 27, 31, 35 | msi-bench-boot02-state00.json, msi-bench-boot04-state00.json, msi-bench-boot06-state00.json, msi-bench-boot09-state00.json, msi-bench-boot13-state00.json, msi-bench-boot17-state00.json, msi-bench-boot20-state00.json, msi-bench-boot22-state00.json, msi-bench-boot24-state00.json, msi-bench-boot27-state00.json, msi-bench-boot31-state00.json, msi-bench-boot35-state00.json |
