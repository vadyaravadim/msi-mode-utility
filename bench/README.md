# MSI mode bench

Reproduce the measurements behind the RigPolice article https://rigpolice.com/system/articles/enable-msi-mode/ . `msi-bench.ps1` records the interrupt mode of every PCI device, ISR and DPC time per driver from a kernel trace, and a stall probe pinned to one CPU. The Superposition load below is the GPU-bound load for it.

**Same procedure, not same numbers.** A game update, a driver update or a different CPU moves every number. Compare states only inside one series of runs on one machine, never against the published tables.

## What you need

- Windows 11, an elevated PowerShell (Windows PowerShell 5.1 or PowerShell 7).
- Run one interrupt-mode state per series (stock, then after `msi-mode-utility.ps1`, with a reboot between).
- PresentMon 2.6.0: https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0. Verify the download: `(Get-FileHash .\PresentMon-2.6.0-x64.exe).Hash` must equal `b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af`.
- A load from the section "Loads" below.
- Download the whole `bench` folder: the script dot-sources `bench-env.ps1` and the load recipes live in `loads\*.json` next to it.

## Steps

1. Make the machine quiet yourself. The bench only measures: it does not check, close or change anything. Reboot, do not open a browser, launcher, updater, VPN or monitoring tool afterwards, and wait the same fixed time after every reboot (write it down) so uptime is comparable between states.
2. Start the load from the section "Loads" and let it settle.
3. Run the bench from the elevated shell: `.\msi-bench.ps1 -Phase stock -Seconds 30`, then `.\msi-bench.ps1 -Phase msi -Seconds 30`.
4. Repeat at least 5 times per state in the order A-B-A-B (never all A then all B), with a reboot before every run.

Frame-time capture of a running load (`-Test game -Load <name>`) is not part of this version yet. The load recipes below are the single source it will read.

## What the bench touches

Nothing persistent. It reads the registry, `powercfg /qh`, WMI and performance counters, and it runs one temporary ETW session named "NT Kernel Logger" that it starts and stops itself, and the stall-probe thread. It changes no power, registry, service or boot setting and stops no process. It does not check whether your machine is quiet; that is up to you. A test in `tests\` fails if a changing command is added.

## Result record

Each result stores the bench script name and its SHA256, the OS build, display version and update revision, the active power scheme GUID with every processor setting for AC and DC, the load name and the PresentMon version, next to the measurements. Nothing else is recorded: no process or service list, no driver inventory, no user name or computer name.

## Reading the result

One run proves nothing. Take the median of the runs of each state and look at the spread (min to max). A difference counts only when it is larger than the spread inside a state. "Cannot tell" is a valid result. A maximum from a single run is never a headline.

## Sharing a result

The result files hold only the fields above and the measurements, so they can be shared as they are.

## Loads

### Counter-Strike 2, workshop map CS2 FPS BENCHMARK (Angel) (`cs2`)

- PresentMon 2.6.0, SHA256 `b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af` (https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0).
- Steam app 730 (free), workshop map 3240880604 ("CS2 FPS BENCHMARK" by Angel). The map is a 131 s camera route over de_dust2 and ends with a disconnect by itself.
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

Timings: load pause 15 s after the Enter, then capture 100 s.

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
- frame times cluster at the monitor refresh period
- cs2.exe is not the captured process

### Unigine Superposition 1.1 (free), infinite scene (`superposition`)

- PresentMon 2.6.0, SHA256 `b2a706bc6ad475749e3b7e3409263aa1e6906d45bdcf993f6dbc0f660188f1af` (https://github.com/GameTechDev/PresentMon/releases/tag/v2.6.0).
- Program: Unigine Superposition 1.1, installer `Unigine_Superposition-1.1.exe`, SHA256 `DE5DBF4F7AD284B709C5DB318DBEDC1B025A41E50326595A444EE9CBD4A17182`, installed to `C:\Program Files\Unigine\Superposition Benchmark`.
- Bottleneck: GPU. vsync: 0 (off).

Launch arguments:

```
bin\superposition.exe -project_name Superposition -video_mode -1 -console_command "world_load superposition/superposition" -video_app direct3d11 -video_width 2560 -video_height 1440 -video_fullscreen 1 -preset 0 -video_vsync 0 -sound 0
```

Run it from `C:\Program Files\Unigine\Superposition Benchmark\bin`. Change `-video_width` and `-video_height` to your monitor's native resolution.

Timings: load pause 20 s after the Enter, then capture 60 s.

Turn these off in the GPU driver and anywhere else before the run:

- AMD Radeon Chill
- AMD Frame Rate Target Control (FRTC)
- AMD Anti-Lag
- any external frame limiter

The bench rejects the run when:

- SyncInterval above 0
- frame times cluster at the monitor refresh period
- superposition.exe is not the captured process