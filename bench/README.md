# MSI mode bench

Follow the procedure in the RigPolice article: https://rigpolice.com/system/articles/enable-msi-mode/ . The reboots, the settle wait and the checks between runs were done by the article's test runner; you do them by hand. `msi-bench.ps1` records the interrupt mode of every PCI device, ISR and DPC time per driver from a kernel trace, and a stall probe that counts every gap of 2 us or more in a spinning thread on a chosen CPU. The Superposition load below is the GPU-bound load for it.

**Same procedure, not same numbers.** A game update, a driver update or a different CPU moves every number. Compare states only inside one series of runs on one machine, never against the published tables.

## What you need

- Windows 11, an elevated PowerShell (Windows PowerShell 5.1 or PowerShell 7).
- Run one interrupt-mode state per series (stock, then after `msi-mode-utility.ps1`, with a reboot between). For `-Background` you also need Unigine Superposition 1.1 installed (the load below) and a USB SSD with a 1 GiB file of real data. Create it once, in PowerShell, with `$r = New-Object System.Random 1; $b = New-Object byte[] 64MB; $f = [System.IO.File]::Create('<path on the USB SSD>'); 1..16 | ForEach-Object { $r.NextBytes($b); $f.Write($b, 0, $b.Length) }; $f.Dispose()` (16 blocks of 64 MiB of pseudo-random data from `System.Random` seeded with 1).
- PresentMon 2.6.0: https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0. Verify the download: `(Get-FileHash .\PresentMon-2.6.0-x64.exe).Hash` must equal `b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af`.
- A load from the section "Loads" below.
- Download the whole `bench` folder: the script dot-sources `bench-env.ps1` and the load recipes live in `loads\*.json` next to it.

## Steps

1. Make the machine quiet yourself. The bench only measures: it does not check, close or change anything. Reboot, do not open a browser, launcher, updater, VPN or monitoring tool afterwards, and wait the same fixed time after every reboot (write it down) so uptime is comparable between states.
2. If you run with `-Load`, do not start the load yet: the bench waits for it. Otherwise start your own load now, if your test needs one.
3. Run the bench from the elevated shell: `.\msi-bench.ps1 -Phase stock -Load superposition -PresentMon <path to PresentMon-2.6.0-x64.exe> -Device dxgkrnl.sys,HDAudBus.sys,Wdf01000.sys`, then the same with `-Phase msi`. To run the same tone and SSD reads as the article, add `-Background tone,usb-read -UsbReadFile <path of the 1 GiB file>` to the Superposition command (admin shell). Without a load, `-Seconds` sets the window and `-Cpu 0,5` picks the probe CPUs (a load takes its window from the recipe, so `-Seconds` is refused with `-Load`). `-Device` takes the drivers whose interrupts you care about: a 5 s pre-trace finds the CPU that takes most of each driver's ISRs and the probe runs there too. A WDDM GPU logs its ISR as `dxgkrnl.sys`, not as the vendor driver, and `Wdf01000.sys` groups every KMDF device (USB host controller, GPIO). The result holds a histogram of the gaps per probe and `msi-bench-<phase>-stalls.csv` lists every gap of 1 ms or more. Results go next to the script, or to `-OutDir`. With `-Load`, start the load from the section "Loads" after the bench prints `Waiting for <process> ...`.
4. Repeat at least 5 times per state in the order A-B-A-B (never all A then all B), with a reboot before every run.

For `-Load` start the bench before the load: it waits for the load's process and, when the recipe names a start line, for that line in the game log, then waits the load pause and captures frame times with PresentMon while the kernel trace and the probes run. On a load with a fixed route the `-Device` pre-trace runs inside the load pause, so the window stays on the route. Do not touch the PC until it prints the result.

## What the bench touches

Nothing persistent. It reads the registry, `powercfg /qh`, WMI and performance counters, and it runs one temporary ETW session named "NT Kernel Logger" that it starts and stops itself (twice with `-Device`: the pre-trace and the main trace), for `-Load` PresentMon with its own ETW session named `rigpolice-bench`, the stall-probe threads, and with `-Background` a 440 Hz tone at -40 dBFS on the default output and an unbuffered read loop over `-UsbReadFile`. It changes no power, registry, service or boot setting and stops no process. It does not check whether your machine is quiet; that is up to you. A test in `tests\` fails if a changing command is added.

## Result record

Each result stores the bench script name and its SHA256, the OS build, display version and update revision, the active power scheme GUID with every processor setting for AC and DC, the load name and the PresentMon version, and the QPC timer frequency, next to the measurements. `msi-bench.ps1` adds the interrupt mode of every PCI device, the stall probe per CPU (histogram, percentiles, total stalled time, the devices behind each CPU, and `gcCollections`, the .NET garbage collections that ran inside its window, which the bench runs inside a .NET no-GC region with 64 MB reserved; a `-Load` run with one is rejected), the trace clock type, the CPU picked per `-Device` driver next to the CPU the main trace shows for it, and, with `-Load`, the load build, whether the installed video config matches the shipped one (mismatched key names only), the names of launch flags outside the recipe (names only, no values), the frame statistics and the count of frames PresentMon lost to a present event buffer overflow (`presentMon.overflowedPresents`; a run that lost any is rejected). `loadWindow` gives the seconds from the load start to the start and to the end of the capture window; on a load with a fixed route a window that ends past the route rejects the run. With `-Background`, the result adds `background`: for the tone its frequency, level, the default playback device name and the PCI controller it sits behind, for the SSD reads the bytes read, wraps, seconds and MiB/s (a read error rejects the run). With `-Load`, `systemCpu` adds the whole-system CPU time over the same window (`windowSeconds`, `busySeconds`, `idleSeconds`, `logicalCpus`), read from the OS at the same two points, so work from processes that start and exit inside the window still shows. Each driver row carries the summed ISR and DPC time (`isrTotalUs`, `dpcTotalUs`). The device table names each PCI device and its driver, because the interrupt mode per device is the measurement. Nothing else is recorded: no process or service list, no driver inventory, no user name or computer name.

## Reading the result

One run proves nothing. Take the median of the runs of each state and look at the spread (min to max). A difference counts only when it is larger than the spread inside a state. "Cannot tell" is a valid result. A maximum from a single run is never a headline.

## Sharing a result

The result files hold only the fields above and the measurements, so they can be shared as they are.

## Loads

### Counter-Strike 2, workshop benchmark map (`cs2`)

- PresentMon 2.6.0, SHA256 `b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af` (https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0).
- Steam app 730 (free), workshop map 3240880604 ("CS2 FPS BENCHMARK DUST2"). The map is a 131 s camera route over de_dust2 and ends with a disconnect by itself.
- Bottleneck: CPU. vsync: 0 (off).

Launch arguments:

```
steam.exe -applaunch 730 -novid -condebug +con_enable 1 -console +toggleconsole
```

Wait 25 s for the main menu, bring the game window to the front, then type this into the console (the launch arguments open it) and press Enter:

```
game_type 3; game_mode 0; sv_skirmish_id 0; sv_game_mode_flags 32; mapgroup @workshop/3240880604/de_dust2; nextlevel de_dust2; map de_dust2 customgamemode=3240880604 nomapvalidation=true; hideconsole
```

The line is fixed; do not edit it. `hideconsole` closes the console so it does not sit over the scene.

Timings: the route has started when the game log `../../csgo/console.log` (relative to the folder of cs2.exe) shows `[VProf] VProfLite started.`. From that line: load pause 15 s, then capture 100 s.

Turn these off in the GPU driver and anywhere else before the run:

- AMD Radeon Chill
- AMD Frame Rate Target Control (FRTC)
- AMD Anti-Lag
- NVIDIA Reflex / Low Latency Mode overrides
- any external frame limiter

Video settings: use the provided file `bench\loads\cs2_video.txt` as is. The mapping from its values to in-game menu labels is not confirmed against a primary source, so do not set the menu by hand.

1. Close CS2.
2. Back up your own file: `<Steam>\userdata\<your Steam id>\730\local\cfg\cs2_video.txt`.
3. Copy `bench\loads\cs2_video.txt` over it.
4. Run the load.
5. Close CS2 and put your backup back.

The file sets 1280x720 (`setting.defaultres`, `setting.defaultresheight`), `setting.mat_vsync` = 0 and `setting.msaa_samples` = 0. It also carries `VendorID`, `DeviceID`, `knowndevice`, `Autoconfig` and `Version` from the machine it was captured on. Whether CS2 accepts the file without them is not verified, so they are kept.

The bench rejects the run when:

- SyncInterval above 0
- the installed cs2_video.txt differs from the shipped cs2_video.txt in any setting.* value, or is not found
- frame times cluster at the monitor refresh period
- cs2.exe is not the captured process
- the captured frames cover less than 95 s of the 100 s capture (the load stopped presenting or exited)

### Unigine Superposition 1.1 (free), infinite scene (`superposition`)

- PresentMon 2.6.0, SHA256 `b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af` (https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0).
- Program: Unigine Superposition 1.1, installer `Unigine_Superposition-1.1.exe`, SHA256 `DE5DBF4F7AD284B709C5DB318DBEDC1B025A41E50326595A444EE9CBD4A17182`, installed to `C:\Program Files\Unigine\Superposition Benchmark`.
- Bottleneck: GPU. vsync: 0 (off).

Launch arguments:

```
bin\superposition.exe -project_name Superposition -video_mode -1 -console_command "world_load superposition/superposition" -video_app direct3d11 -video_width 2560 -video_height 1440 -video_fullscreen 1 -preset 0 -video_vsync 0 -sound 0
```

Run it from `C:\Program Files\Unigine\Superposition Benchmark\bin`. Change `-video_width` and `-video_height` to your monitor's native resolution.

Timings: from the start of superposition.exe: load pause 20 s, then capture 60 s.

Turn these off in the GPU driver and anywhere else before the run:

- AMD Radeon Chill
- AMD Frame Rate Target Control (FRTC)
- AMD Anti-Lag
- any external frame limiter

The bench rejects the run when:

- SyncInterval above 0
- frame times cluster at the monitor refresh period
- superposition.exe is not the captured process
- the captured frames cover less than 57 s of the 60 s capture (the load stopped presenting or exited)