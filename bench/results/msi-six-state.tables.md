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
| Load | superposition 1.1 |
| PresentMon | 2.6.0 |
| Settle before capture | 120 s |
| Enabled physical network adapters | 0 |
| Boots | 72 |
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

Each state against stock, lower is better for every metric: a two-sided exact permutation test of the rank sum, Holm-corrected over the 30 tests at alpha 0.05, and the Hodges-Lehmann shift (state minus stock) with an interval of at least 90% confidence.
Verdicts: helped or hurt when the Holm-adjusted p is under 0.05; no difference when the whole interval lies strictly inside the margin; cannot tell otherwise. A test of a probe core reads cannot tell, whatever its p and interval, when the load of another driver on that core differs between the state and stock by 0.1 points or more (table Other drivers on the probe cores). The note names the boots whose probe core differs and the drivers that moved.
On this gpu-bound load a test that is not significant reads cannot show for: 1% low (ms).

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

Average FPS is a load check only: a state whose median differs from the stock median by more than 1% is marked load differs on every row above, and the mark changes no verdict.

| State | Avg FPS, stock median | Avg FPS, state median | Difference (%) | Load |
| --- | --- | --- | --- | --- |
| audio-msi | 121.5 | 121.5 | 0 | same |
| usb-line | 121.5 | 121.4 | -0.08 | same |
| mobo-audio-msi | 121.5 | 121.5 | 0 | same |
| gpu-audio-msi | 121.5 | 121.5 | 0 | same |
| gpu-line | 121.5 | 121.6 | 0.08 | same |

## Other drivers on the probe cores

Load of a driver on the probe core of dxgkrnl.sys or Wdf01000.sys: its share of ISRs on that CPU times its ISR plus DPC time, in % of one core. The core's own driver and the changed drivers of the state are left out. Median over the boots, listed when either median is at least 0.1%; moved when the two medians differ by 0.1 points or more.

| State | Probe core of | Driver | Stock median (% of the core) | State median | Moved |
| --- | --- | --- | --- | --- | --- |
| usb-line | dxgkrnl.sys | HDAudBus.sys | 0.21 | 0.22 | no |
| gpu-line | dxgkrnl.sys | HDAudBus.sys | 0.21 | 0.22 | no |

## Frames

Median [min-max] over the boots of each state. 1% low and 0.1% low are the 99th and 99.9th percentile frame time.

| State | Boots | Avg FPS | p50 (ms) | 1% low (ms) | 0.1% low (ms) | GPU busy p50 (ms) | CPU busy p50 (ms) | System CPU busy (% of the machine) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| stock | 12 | 121.5 [121.1-121.7] | 8.22 [8.21-8.25] | 8.52 [8.48-9.21] | 10.66 [10.02-17.63] | 8.2 [8.19-8.23] | 8.19 [8.18-8.21] | 8.72 [8.66-8.95] |
| audio-msi | 12 | 121.5 [121.3-121.6] | 8.22 [8.21-8.24] | 8.52 [8.45-10] | 10.21 [8.66-17.06] | 8.2 [8.19-8.22] | 8.19 [8.18-8.2] | 8.72 [8.63-8.93] |
| usb-line | 12 | 121.4 [121.2-121.8] | 8.23 [8.21-8.25] | 8.53 [8.48-8.59] | 10.26 [9.51-18.37] | 8.21 [8.18-8.23] | 8.2 [8.17-8.21] | 8.79 [8.69-9] |
| mobo-audio-msi | 12 | 121.5 [121.3-121.7] | 8.23 [8.21-8.24] | 8.53 [8.48-9.93] | 12.17 [10.02-18.44] | 8.2 [8.19-8.22] | 8.19 [8.17-8.2] | 8.75 [8.67-8.98] |
| gpu-audio-msi | 12 | 121.5 [121.3-121.7] | 8.22 [8.21-8.24] | 8.5 [8.47-8.58] | 11.06 [10.02-16.78] | 8.21 [8.19-8.22] | 8.19 [8.17-8.2] | 8.73 [8.65-8.95] |
| gpu-line | 12 | 121.6 [121.4-121.9] | 8.22 [8.2-8.23] | 8.49 [8.45-8.54] | 8.61 [8.55-11.93] | 8.2 [8.18-8.21] | 8.19 [8.17-8.2] | 8.71 [8.58-8.89] |

## Drivers

Every driver whose median ISR plus DPC time is at least 0.5 ms/s in any state. Median [min-max] over the boots of each state.

| Driver | State | ISR/s | ISR mean (us) | ISR (ms/s) | DPC/s | DPC mean (us) | DPC p99 (us) | DPC (ms/s) | CPU of the ISR |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| amdkmdag.sys | stock | 0 [0-0] | 0 [0-0] | 0 [0-0] | 973.77 [970.78-975.07] | 26.71 [26.62-26.82] | 173.35 [172.8-175.1] | 25.99 [25.88-26.12] | - |
| amdkmdag.sys | audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 973.91 [972.17-975.34] | 26.64 [26.46-26.71] | 172.65 [172.2-173.6] | 25.92 [25.76-26.02] | - |
| amdkmdag.sys | usb-line | 0 [0-0] | 0 [0-0] | 0 [0-0] | 973.64 [970.33-975.78] | 26.72 [26.62-27] | 173.55 [172.9-179.4] | 26.03 [25.92-26.34] | - |
| amdkmdag.sys | mobo-audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 973.46 [971.67-975.51] | 26.72 [26.55-26.91] | 173.05 [172.4-176.8] | 25.99 [25.84-26.18] | - |
| amdkmdag.sys | gpu-audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 973.29 [971.69-975.04] | 26.68 [26.55-26.76] | 172.8 [172.2-174.9] | 26 [25.81-26.03] | - |
| amdkmdag.sys | gpu-line | 0 [0-0] | 0 [0-0] | 0 [0-0] | 837.11 [807.65-852.6] | 27.52 [26.51-28.39] | 175.5 [174.9-177] | 23.02 [22.4-23.61] | - |
| Wdf01000.sys | stock | 7516.51 [7203.48-7642.63] | 0.13 [0.13-0.14] | 0.98 [0.94-1.02] | 7516.59 [7203.48-7642.63] | 1.92 [1.86-1.95] | 2.8 [2.7-2.9] | 14.42 [13.41-14.74] | 0 |
| Wdf01000.sys | audio-msi | 7514.77 [7241.08-7614.4] | 0.13 [0.13-0.13] | 0.98 [0.94-1] | 7514.85 [7241.14-7614.47] | 1.9 [1.82-1.95] | 2.8 [2.6-2.9] | 14.21 [13.43-14.82] | 0 |
| Wdf01000.sys | usb-line | 5709.11 [5510.61-5817.32] | 1.06 [1.05-1.06] | 6.04 [5.83-6.14] | 5708.89 [5512.02-5817.04] | 2.71 [2.59-2.74] | 4.2 [4-4.3] | 15.28 [14.79-15.81] | 0 |
| Wdf01000.sys | mobo-audio-msi | 7535.79 [7306.16-7682.9] | 0.13 [0.13-0.13] | 0.98 [0.95-1.03] | 7535.82 [7306.24-7682.9] | 1.9 [1.88-1.94] | 2.8 [2.7-2.8] | 14.35 [13.9-14.68] | 0 |
| Wdf01000.sys | gpu-audio-msi | 7517.97 [7333.73-7647.37] | 0.13 [0.13-0.14] | 0.99 [0.95-1.04] | 7518.05 [7333.74-7647.37] | 1.91 [1.84-1.95] | 2.8 [2.7-2.9] | 14.26 [14-14.91] | 0 |
| Wdf01000.sys | gpu-line | 7676.99 [7536.19-7733.26] | 0.13 [0.13-0.14] | 1 [0.97-1.07] | 7677.03 [7536.27-7733.26] | 1.91 [1.87-1.98] | 2.8 [2.7-2.9] | 14.69 [14.13-15.16] | 0 |
| dxgkrnl.sys | stock | 847.38 [845.89-851.43] | 20.87 [20.77-20.92] | 17.69 [17.64-17.71] | 1244.93 [1182.85-1269.02] | 0.98 [0.95-1.12] | 7.7 [7.2-8.2] | 1.22 [1.2-1.32] | 5 |
| dxgkrnl.sys | audio-msi | 847.63 [846.52-851.64] | 20.86 [20.77-20.97] | 17.7 [17.64-17.75] | 1245.91 [1196.52-1269.27] | 0.98 [0.94-1.06] | 7.8 [7.2-8.1] | 1.23 [1.19-1.28] | 5 |
| dxgkrnl.sys | usb-line | 848.27 [845.4-851.26] | 20.86 [20.84-20.9] | 17.69 [17.65-17.78] | 1244.3 [1181.11-1278.66] | 0.98 [0.95-1.1] | 7.7 [7.5-8.2] | 1.22 [1.18-1.31] | 5 |
| dxgkrnl.sys | mobo-audio-msi | 847.58 [846.11-849.47] | 20.9 [20.81-20.96] | 17.7 [17.65-17.77] | 1223.11 [1172.49-1261.06] | 1.03 [0.97-1.12] | 7.95 [7.4-8.2] | 1.24 [1.2-1.31] | 5 |
| dxgkrnl.sys | gpu-audio-msi | 847.71 [844.99-849.42] | 20.89 [20.8-20.96] | 17.7 [17.65-17.76] | 1226.34 [1187.38-1267.12] | 1 [0.95-1.06] | 7.85 [7.1-8.2] | 1.24 [1.19-1.29] | 5 |
| dxgkrnl.sys | gpu-line | 789.67 [755.17-801.61] | 21.82 [21.56-22.75] | 17.22 [17.15-17.3] | 1216.55 [1138.97-1248.47] | 1.5 [1.28-1.71] | 8.2 [5.7-8.6] | 1.84 [1.6-2.08] | 5 |
| storport.sys | stock | 145.95 [123.61-176.72] | 0.48 [0.43-0.55] | 0.07 [0.06-0.08] | 2654.14 [2527.5-2693.6] | 1.75 [1.67-1.79] | 5.5 [5.3-5.6] | 4.61 [4.43-4.75] | 6, 12 |
| storport.sys | audio-msi | 125.48 [122.43-183.54] | 0.5 [0.44-0.57] | 0.07 [0.06-0.08] | 2649.78 [2567.58-2704.12] | 1.75 [1.7-1.77] | 5.5 [5.2-5.6] | 4.58 [4.48-4.77] | 6, 14 |
| storport.sys | usb-line | 147.74 [107.7-162.67] | 0.48 [0.45-0.52] | 0.07 [0.05-0.08] | 2985.42 [2887.05-3059.3] | 1.66 [1.6-1.7] | 5.4 [5.2-5.6] | 4.88 [4.76-5.16] | 6 |
| storport.sys | mobo-audio-msi | 149.78 [122.1-179.12] | 0.48 [0.44-0.56] | 0.07 [0.06-0.08] | 2672.07 [2558.74-2714.97] | 1.74 [1.68-1.86] | 5.5 [5.2-5.6] | 4.62 [4.38-4.98] | 6, 12 |
| storport.sys | gpu-audio-msi | 143.85 [121.67-183.24] | 0.48 [0.43-0.54] | 0.07 [0.06-0.08] | 2663.12 [2568.73-2707.3] | 1.75 [1.7-1.77] | 5.45 [5.3-5.5] | 4.62 [4.41-4.74] | 6, 12 |
| storport.sys | gpu-line | 163.59 [124.17-180.08] | 0.48 [0.45-0.55] | 0.08 [0.06-0.09] | 2705.02 [2679.88-2746.31] | 1.73 [1.68-1.75] | 5.4 [5.2-5.6] | 4.71 [4.53-4.77] | 6, 12 |
| ntoskrnl.exe | stock | 0 [0-0] | 0 [0-0] | 0 [0-0] | 454.1 [408.43-636.24] | 8.4 [7.31-9.15] | 33.9 [32.5-35.3] | 3.84 [3.58-5.16] | - |
| ntoskrnl.exe | audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 458.16 [406.77-542.17] | 8.7 [7.29-9.57] | 33.95 [32.8-35.7] | 3.77 [3.67-4.76] | - |
| ntoskrnl.exe | usb-line | 0 [0-0] | 0 [0-0] | 0 [0-0] | 425.69 [402.9-620.08] | 8.84 [8.38-9.37] | 33.5 [33.1-35.9] | 3.74 [3.63-5.2] | - |
| ntoskrnl.exe | mobo-audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 484.3 [411.28-610.68] | 8.82 [8-9.29] | 34.1 [33.3-35.4] | 4.3 [3.62-4.89] | - |
| ntoskrnl.exe | gpu-audio-msi | 0 [0-0] | 0 [0-0] | 0 [0-0] | 491.77 [415.36-600.74] | 8.56 [7.2-9.66] | 33.6 [31.4-36.8] | 4.04 [3.64-4.85] | - |
| ntoskrnl.exe | gpu-line | 0 [0-0] | 0 [0-0] | 0 [0-0] | 461.72 [399.5-627.63] | 8.92 [7.29-9.82] | 33.95 [31.7-36.5] | 3.99 [3.58-5.19] | - |
| HDAudBus.sys | stock | 228 [114.06-228.26] | 8.36 [8.33-14.44] | 1.9 [1.26-1.92] | 114.07 [113.92-114.16] | 2.25 [2.17-2.3] | 10.25 [10.2-10.3] | 0.26 [0.25-0.26] | 5 |
| HDAudBus.sys | audio-msi | 114.06 [113.92-114.15] | 15.08 [14.95-15.15] | 1.72 [1.71-1.73] | 114.06 [113.92-114.15] | 1.38 [1.3-1.45] | 5.7 [5.7-5.8] | 0.16 [0.15-0.17] | 0 |
| HDAudBus.sys | usb-line | 231.39 [117.96-234.03] | 9.01 [6.29-15.62] | 1.97 [1.45-2.1] | 114.1 [113.96-114.18] | 2.25 [2.17-2.28] | 10.3 [10.3-10.4] | 0.26 [0.25-0.26] | 5 |
| HDAudBus.sys | mobo-audio-msi | 114.11 [113.94-114.18] | 15.06 [14.99-15.16] | 1.72 [1.71-1.73] | 114.11 [113.94-114.18] | 1.5 [1.43-1.55] | 6.4 [5.8-6.6] | 0.17 [0.16-0.18] | 5 |
| HDAudBus.sys | gpu-audio-msi | 113.99 [113.87-114.07] | 14.25 [7.75-14.3] | 1.62 [0.88-1.63] | 114.03 [113.91-114.11] | 2.11 [2.04-2.17] | 9.9 [9.9-10] | 0.24 [0.23-0.25] | 0 |
| HDAudBus.sys | gpu-line | 228.82 [115.08-229.4] | 8.5 [6.02-14.68] | 1.94 [1.37-1.96] | 114.06 [113.96-114.13] | 2.32 [2.18-2.35] | 10.3 [10.2-10.3] | 0.26 [0.25-0.27] | 5 |

## Probes

Median [min-max] over the boots of each state. Stalls of 1 ms or more counts the rows of the stall file on that CPU in one boot.

| State | Probe CPU | Drivers on the core | Stalled (%) | Gap p50 (us) | Gap p99 (us) | Gap p99.9 (us) | Stalls of 1 ms or more |
| --- | --- | --- | --- | --- | --- | --- | --- |
| stock | 0 | Wdf01000.sys | 2.72 [2.61-2.8] | 3 [3-3.1] | 5.5 [5.1-6.7] | 38.5 [27-39.9] | 3 [1-7] |
| stock | 5 | dxgkrnl.sys, HDAudBus.sys | 3.68 [3.52-3.71] | 13.95 [12.9-18.2] | 187.55 [186.6-189.6] | 205.95 [203-213.6] | 0 [0-2] |
| audio-msi | 0 | HDAudBus.sys, Wdf01000.sys | 2.9 [2.74-2.99] | 3 [2.9-3.1] | 17.3 [17.1-20.9] | 51.2 [30.4-53.5] | 1.5 [0-6] |
| audio-msi | 5 | dxgkrnl.sys | 3.44 [3.32-3.46] | 13.05 [12.9-13.9] | 186.8 [186.1-187.9] | 198.55 [196.8-211.6] | 0.5 [0-2] |
| usb-line | 0 | Wdf01000.sys | 3.28 [3.16-3.42] | 4.6 [4.5-4.7] | 8.5 [7.8-15.8] | 39.4 [28.5-44] | 2 [0-11] |
| usb-line | 5 | dxgkrnl.sys, HDAudBus.sys | 3.68 [3.52-3.73] | 13.75 [12.8-16.3] | 187.3 [186.8-192.7] | 207 [204.2-213.8] | 0 [0-2] |
| mobo-audio-msi | 0 | Wdf01000.sys | 2.74 [2.56-2.81] | 3 [3-3.1] | 5.45 [5-6.8] | 36.35 [9.1-39] | 3 [1-6] |
| mobo-audio-msi | 5 | dxgkrnl.sys, HDAudBus.sys | 3.6 [3.52-3.68] | 14.8 [13.7-17.1] | 187.35 [186.6-192] | 207 [202.2-212.3] | 0 [0-3] |
| gpu-audio-msi | 0 | HDAudBus.sys, Wdf01000.sys | 2.9 [2.8-3.14] | 3 [3-3.1] | 16.7 [9.3-26.9] | 52.35 [30-54.8] | 2 [0-5] |
| gpu-audio-msi | 5 | dxgkrnl.sys | 3.44 [3.32-3.47] | 13 [12.9-14.2] | 187 [186.4-190.6] | 198.85 [197.5-211.7] | 0.5 [0-2] |
| gpu-line | 0 | Wdf01000.sys | 2.81 [2.66-3.22] | 3 [3-3.1] | 5.6 [5-27.2] | 37.6 [8.6-112.3] | 1.5 [0-3] |
| gpu-line | 5 | dxgkrnl.sys, HDAudBus.sys | 3.66 [3.53-3.73] | 15.45 [13.6-18.7] | 191.55 [190.9-193.6] | 210 [207.9-215.3] | 0 [0-2] |

## Runs with a gap of 5 ms or more

| State | Runs with such a gap | Offsets from the start of the stall timeline |
| --- | --- | --- |
| stock | 0 of 12 | - |
| audio-msi | 0 of 12 | - |
| usb-line | 0 of 12 | - |
| mobo-audio-msi | 0 of 12 | - |
| gpu-audio-msi | 0 of 12 | - |
| gpu-line | 0 of 12 | - |

## USB reads

| State | MiB/s |
| --- | --- |
| stock | 156.75 [152.4-158.4] |
| audio-msi | 156.45 [153-157.8] |
| usb-line | 178.3 [173.4-180.1] |
| mobo-audio-msi | 157.05 [154-158.9] |
| gpu-audio-msi | 156.95 [154-158.7] |
| gpu-line | 158.75 [156.9-160.3] |

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
| stock | 0, 8, 16, 23, 27, 31, 37, 45, 53, 58, 62, 66 | msi-bench-boot00-state00.json, msi-bench-boot08-state00.json, msi-bench-boot16-state00.json, msi-bench-boot23-state00.json, msi-bench-boot27-state00.json, msi-bench-boot31-state00.json, msi-bench-boot37-state00.json, msi-bench-boot45-state00.json, msi-bench-boot53-state00.json, msi-bench-boot58-state00.json, msi-bench-boot62-state00.json, msi-bench-boot66-state00.json |
| audio-msi | 1, 6, 14, 22, 29, 33, 39, 47, 52, 56, 60, 67 | msi-bench-boot01-state00.json, msi-bench-boot06-state00.json, msi-bench-boot14-state00.json, msi-bench-boot22-state00.json, msi-bench-boot29-state00.json, msi-bench-boot33-state00.json, msi-bench-boot39-state00.json, msi-bench-boot47-state00.json, msi-bench-boot52-state00.json, msi-bench-boot56-state00.json, msi-bench-boot60-state00.json, msi-bench-boot67-state00.json |
| usb-line | 2, 10, 17, 21, 25, 30, 36, 43, 51, 59, 64, 68 | msi-bench-boot02-state00.json, msi-bench-boot10-state00.json, msi-bench-boot17-state00.json, msi-bench-boot21-state00.json, msi-bench-boot25-state00.json, msi-bench-boot30-state00.json, msi-bench-boot36-state00.json, msi-bench-boot43-state00.json, msi-bench-boot51-state00.json, msi-bench-boot59-state00.json, msi-bench-boot64-state00.json, msi-bench-boot68-state00.json |
| mobo-audio-msi | 3, 7, 12, 20, 28, 35, 41, 46, 50, 54, 61, 69 | msi-bench-boot03-state00.json, msi-bench-boot07-state00.json, msi-bench-boot12-state00.json, msi-bench-boot20-state00.json, msi-bench-boot28-state00.json, msi-bench-boot35-state00.json, msi-bench-boot41-state00.json, msi-bench-boot46-state00.json, msi-bench-boot50-state00.json, msi-bench-boot54-state00.json, msi-bench-boot61-state00.json, msi-bench-boot69-state00.json |
| gpu-audio-msi | 4, 11, 15, 19, 24, 32, 38, 42, 49, 57, 65, 70 | msi-bench-boot04-state00.json, msi-bench-boot11-state00.json, msi-bench-boot15-state00.json, msi-bench-boot19-state00.json, msi-bench-boot24-state00.json, msi-bench-boot32-state00.json, msi-bench-boot38-state00.json, msi-bench-boot42-state00.json, msi-bench-boot49-state00.json, msi-bench-boot57-state00.json, msi-bench-boot65-state00.json, msi-bench-boot70-state00.json |
| gpu-line | 5, 9, 13, 18, 26, 34, 40, 44, 48, 55, 63, 71 | msi-bench-boot05-state00.json, msi-bench-boot09-state00.json, msi-bench-boot13-state00.json, msi-bench-boot18-state00.json, msi-bench-boot26-state00.json, msi-bench-boot34-state00.json, msi-bench-boot40-state00.json, msi-bench-boot44-state00.json, msi-bench-boot48-state00.json, msi-bench-boot55-state00.json, msi-bench-boot63-state00.json, msi-bench-boot71-state00.json |
