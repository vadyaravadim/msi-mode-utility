# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released section below IS the GitHub Release body for that version: `release.yml` releases the newest
section, copies it verbatim into the release, and fails before anything is tagged or published if the
section is empty or its compare link at the bottom is missing.

## [Unreleased]

### Fixed

- On Windows Server Core the run stopped with a raw error after the device scan instead of saying the edition is not
  supported. It now says so before the scan. Nothing was ever changed.
- When every selected device failed to update, the run still ended with "REBOOT REQUIRED for changes to take effect"
  although nothing had changed. That line now shows only when at least one device was updated.

## [1.3.0] - 2026-11-10

### Added

- `bench/msi-bench.ps1` records frame times with PresentMon while a load runs (`-Load superposition -PresentMon <path>`).
  It waits for the load and the recipe's load pause, then captures frames for the recipe's window while the
  kernel trace and the stall probes run. On a load with a fixed route (Counter-Strike 2) the `-Device` pre-trace runs
  inside the load pause, so the window stays on the route; the result records `loadWindow`, the seconds from the load
  start to the start and to the end of the frames, and a capture that ends past the route rejects the run. The load
  recipes live in `bench/loads/*.json`, and `bench/README.md` is generated from them.
- The stall probe counts every gap of 2 microseconds or more and keeps a histogram of the gaps. With `-Device <driver.sys>`, a short pre-trace finds the CPU that takes that driver's interrupts and pins a probe
  there as well. The kernel trace uses the performance-counter clock.
- `-Background tone,usb-read -UsbReadFile <path>` (with `-Load`, needs admin) plays a 440 Hz tone at -40 dBFS on the default
  output and reads a file in a loop with the file cache bypassed, from the load pause until the trace stops. The
  result adds `background` with the playback device name, the PCI controller behind it and the read rate. A read
  error rejects the run.
- With `-ProcessCpu` (needs `-Load`), the result lists `processCpu`: each process that used at least 0.05 CPU-seconds
  inside the capture window, largest first, so a background job that ran during a measurement shows up in the file.
  Without the switch the result holds no process list.
- `bench/tools/Get-MsiSeriesTable.ps1` turns a folder of MSI series boots (the six-state Superposition series or the
  three-state CS2 series) into per-state median [min-max] tables and a `summary.json`, and refuses a series that mixes
  setups. It also tests every state against stock on six pre-registered metrics (stall share and gap p99 on the
  dxgkrnl.sys and Wdf01000.sys probe cores, 1% low frame time, ISR+DPC time of the changed driver): an exact rank test
  with a Holm correction, the Hodges-Lehmann shift with a 90% interval against a fixed margin, and a verdict (helped,
  hurt, no difference, cannot tell; on a GPU-bound load the 1% low reads cannot show instead). Average FPS is a load
  check only: a state more than 1% off stock is marked, and the mark changes no verdict. A series with states besides
  stock now needs a `stock` state, labels from audio-msi, mobo-audio-msi, gpu-audio-msi, gpu-line and usb-line, frames,
  a load with margins (superposition or cs2) and exactly one probe listing each of the two drivers in every boot. The
  probes table adds the drivers on each core, gap p99 and the count of stalls of 1 ms or more.
- With `-Load`, the result carries `systemCpu`: the whole-system busy and idle CPU seconds over the capture window and the
  logical CPU count, so work from processes that start and exit inside the window still shows.
- Every driver row carries `isrTotalUs` and `dpcTotalUs`, the summed time of its interrupt and deferred routines.
- Every result carries a metadata block: the hash of the bench script, the OS build, the power scheme values and
  the PresentMon version.
- `bench/results/msi-retest/` holds the raw output of a 32-boot retest (four interrupt-mode states, 8 boots
  each).

### Changed

- `msi-mode-utility.ps1` itself works exactly as in 1.2.0; only comments in it changed.
- If another program already holds the NT Kernel Logger session, the bench now stops and names the problem instead of killing that program's trace.
- PresentMon runs with a larger circular buffer, and the bench counts the presents it lost to a buffer overflow.
  A run that lost any is rejected.
- A run is also rejected when its frames cover less than 95% of the capture window, which happens when the load
  exits or stops presenting. Before, such a run passed.
- Releases are tagged only after every check has passed on the commit they are built from, and the
  PowerShell Gallery package always holds the same file as the GitHub release.
- A release now waits for the bench tests, which run under Windows PowerShell 5.1 and PowerShell 7;
  before, it was published without them.
- Before a release is published, the script is now checked against the syntax and .NET types of Windows
  PowerShell 5.1, the version `Run.bat` and the elevated relaunch run it under.
- Checking that a downloaded script was built from this repository takes a new `gh attestation verify` command
  from this release on: releases are now built by the release workflow all six RigPolice scripts share.
  SECURITY.md has both commands.

## [1.2.0] - 2026-10-03

### Added

- `bench/msi-bench.ps1` - the interrupt benchmark used to measure this tweak: the interrupt mode of every PCI
  device, per-driver ISR and DPC times from the built-in NT Kernel Logger, and a stall probe pinned to one
  core. You can run the same measurement on your own machine with `bench/msi-bench.ps1`.
  The raw results of our own runs are published next to it in `bench/results/`.
- A **Mode** column shows the interrupt mode each device actually runs in this boot: `MSI`, or
  `Line IRQ n` plus the devices sharing that line. The `MSI` column only shows the registry setting,
  so people enabled MSI where there was nothing to gain. On our Windows 11 testbed the INFs of the AMD GPU
  and the USB xHCI controller write 1, and Windows' own HD Audio driver writes 0. Devices on a line now
  sort to the top.
- `-Status` prints the same list to the console and changes nothing. It needs no admin rights, so checking
  after the reboot that a device really switched no longer costs a UAC prompt and a grid you have to
  cancel.

### Changed

- A successful run now ends with one line linking to this repo and asking for a star, so people who got
  the one-liner from an article or a chatbot know where the tool lives. It is printed only when a device
  was switched to MSI mode: not with `-Disable`.

### Fixed

- The README's first install method, the PowerShell Gallery, failed in the Windows PowerShell 5.1 that
  comes with Windows: `Install-Script` stopped with "Administrator rights are required", and the installed
  script was then blocked by the default execution policy. The one-liner, which works in any PowerShell,
  is now listed first, and the Gallery route is marked as PowerShell 7.
- After the `irm | iex` one-liner, the PowerShell window you ran it from was left treating every error as
  fatal, so a later command or another script in that window could stop on an error it would normally
  shrug off. The one-liner no longer changes that setting in your window.
- Run from a folder with `[` or `]` in its path, the script stopped at once with "A parameter cannot be
  found that matches parameter name 'Raw'". It now runs, and writes its undo file, from any folder.
- Selecting a device that was already in the requested state wrote another undo file and reported it as
  "updated". Such devices are now skipped, and a run that changes nothing writes no undo file.
- Hardware that was removed from the PC (an old graphics card after an upgrade) still showed up in the
  list, and "enabling" it reported success while changing nothing. Only connected devices are listed now.
- The "Out-GridView is not available" message no longer tells you to install the
  `Microsoft.PowerShell.GraphicalTools` module, and the README no longer claims PowerShell 7 needs it.
  PowerShell 7 on a desktop edition of Windows has `Out-GridView` built in; it is missing only on Server
  Core, where no module brings it back.
- The README said msinfo32 shows MSI devices with negative IRQ values. It prints them as ten-digit
  numbers such as `IRQ 4294967255` at the bottom of the list; only Device Manager shows the negative form.

## [1.1.5] - 2026-09-18

### Added

- The banner shows the script version (`MSI MODE UTILITY v1.1.5`), so you can tell at a glance whether
  the copy you are running is the current release - and a bug report that includes the output says which
  version it is about. A copy cloned or zipped from `main` rather than taken from a release says
  `dev build`.

### Changed

- The `irm ... | iex` one-liner, and the copy it saves into your user profile, now download the latest
  tagged release instead of whatever sits on `main`. Until now the one-liner ran - as Administrator - a
  file that had not been through the release checks and had no checksum or provenance behind it. It is
  now byte-for-byte the release asset, so `SHA256SUMS.txt` and `gh attestation verify` cover it too. The
  old command keeps working; swap the URL for the one in the README when convenient.
- A release is no longer published unless `lint` and `ascii-check` pass on the tagged commit.

### Fixed

- `Run.bat -ShowAll` and `Run.bat -Disable` now do what they say. `Run.bat` dropped everything typed after
  its name, so `Run.bat -Disable` quietly ran the normal enable instead of turning MSI off.
- The README still said a one-liner run writes the undo `.reg` to your Desktop. It has gone next to the
  saved copy in your user profile since 1.1.3; the README now says so, and lists a working command for
  passing `-ShowAll` / `-Disable` under each install method.

## [1.1.4] - 2026-09-05

### Fixed

- The copy a piped `irm ... | iex` run saves into your user profile was written with a UTF-8 BOM, which
  then broke running that saved copy through `irm | iex` again - the parser chokes on the leading byte
  order mark. It is now written without one.

## [1.1.3] - 2026-07-19

### Added

- Published to the PowerShell Gallery: `Install-Script msi-mode-utility`.
- Every tagged release ships a `SHA256SUMS.txt` alongside the script plus a signed build-provenance
  attestation, so you can verify the file you downloaded is the one the workflow built from this source.

### Fixed

- Elevation under `irm | iex` re-ran the one-liner you typed instead of the script. 1.1.2 saved what it
  believed was the executing script text before asking for Administrator rights, but in a piped run that
  value is the caller's command line, not the script body - so the elevated window silently re-downloaded
  and re-executed the one-liner, and a run started from inside a wrapper script would have saved the
  wrapper instead. The script is now fetched from its canonical raw URL and that file is what gets
  elevated, with a guard so UAC is never asked to relaunch a file that failed to download. Note the
  trade-off this makes explicit: a piped fork or branch is replaced by canonical `main`, so a fork has to
  point the URL at itself.
- Forwarding a mode switch got a second chance to go wrong: the piped-run rerun added in this release is a
  second relaunch path, on top of the UAC elevation that 1.1.2 had already fixed. Both now build their
  arguments from one shared list, so neither can lose `-ShowAll` or `-Disable`. Passing exactly one switch
  also used to break argument binding on Windows PowerShell 5.1, where a single-element list unrolls to a
  plain string.

### Changed

- The undo `.reg` now always lands next to the script, on every launch path. A piped run used to have no
  script directory of its own and fell back to writing the undo file on your Desktop; the run now saves
  itself into your user profile first and works from there, so the fallback and its `-FromIex` switch are
  gone.
- A failed download or a failed elevation now prints the actual reason - no internet, UAC refused, UAC
  service disabled - and keeps the window open, instead of the console closing on an empty screen.

## [1.1.2] - 2026-07-18

### Changed

- Elevation under `irm | iex` was reworked to relaunch the text that was actually executing rather
  than re-fetching `main`: the piped text - a fork, a branch, a pinned commit, a local copy - was
  saved to `%TEMP%` and elevated with `-File`, where before the elevated window silently ran
  whatever `main` happened to contain at that moment. This did not hold in practice - see the 1.1.3
  fix.
- The undo `.reg` still lands on your Desktop for one-liner runs, through an internal `-FromIex`
  marker, even though the elevated rerun is now file-backed.
- The `MSI_UTIL_ELEVATED` environment-variable workaround and the second network fetch it needed are
  gone; the `-File` relaunch passes `-Elevated` directly.
- The script is now pure ASCII, with its em-dashes replaced, and an `ascii-check` CI workflow keeps
  it that way on every commit. The encoding is not cosmetic here: non-ASCII in a BOM-less file
  breaks Windows PowerShell 5.1 `-File` runs, and a BOM breaks `irm | iex`.

### Fixed

- `-ShowAll` and `-Disable` were silently dropped by the elevated relaunch of a piped run, so a
  piped `-Disable` flipped to enable mode after the UAC prompt and turned MSI on for the devices you
  had picked to turn it off for. Both switches are now forwarded across that relaunch.
- An unhandled error in a piped (`irm | iex`) run closed your console. The trap used `exit 1`, which
  terminates the session it runs in and not just the script; it now rethrows the error instead.

## [1.1.1] - 2026-07-18

### Fixed

- When the script download inside the elevated one-liner relaunch failed - no network, GitHub
  unreachable - the elevated window closed before you could read why. It now prints the error and
  waits for Enter.

## [1.1.0] - 2026-07-18

### Added

- The tool runs from a one-line `irm ... | iex` command, with no download step at all. Without
  Administrator rights it self-elevates by re-running that one-liner in an elevated Windows
  PowerShell window, which also guarantees the device grid is there when you started from PowerShell
  7, since `Out-GridView` does not ship with PowerShell 7.
- A piped run has no script directory, so the undo `.reg` is written to your Desktop in that case.
  The Desktop path is resolved through the Windows known-folder API, so a Desktop that OneDrive
  Known Folder Move has redirected is honored rather than guessed at.

### Changed

- The README Quick Start now leads with the short `irm | iex` one-liner, and Requirements records
  that self-elevation works in every launch mode again.

## [1.0.1] - 2026-07-18

### Changed

- New FAQ entry on whether disabling MPO (Multiplane Overlay) helps with flickering and stutters,
  and why there is no MPO disabler in this series.
- The Related section now links Timer Resolution Utility, GameDVR & FSO Disabler, and Interrupt
  Affinity Utility.

### Fixed

- Two runs within the same second silently destroyed the first run's undo file. The file is named
  from a whole-second timestamp and was overwritten without asking, so the `.reg` you would have
  reverted with was gone. Colliding names now take the first free numeric suffix (`_1`, `_2`, ...),
  and undo files still sort newest to oldest by name.

## [1.0.0] - 2026-07-17

### Added

- First public release. Lists your PCI devices with their MSI (Message Signaled Interrupts) status
  in a grid and switches the devices you pick to MSI mode by writing the documented `MSISupported`
  value. On Windows 10 and 11, check which devices run on a legacy line. The default grid lists the GPU,
  network, USB and audio controllers.
- `-Disable` sets the selected devices to MSI off instead of on; `-ShowAll` drops the default filter
  and lists every MSI-capable PCI device, including the bridges and abstract controllers hidden
  otherwise.
- Writes an `msi_undo_<stamp>.reg` next to the script before any change, so one double-click reverts
  that run - and it reverts from Safe Mode too, which is where you will be if a device stops coming
  up after the reboot. Note that `-Disable` writes an explicit `0` rather than restoring a value
  that was originally absent - only the undo file restores that.
- Self-elevates through UAC and keeps the elevated window open on both success and error. A
  `Run.bat` is included so the whole thing is a double-click. Nothing to install and no external
  dependencies - one readable PowerShell script on Windows PowerShell 5.1+, an open-source
  alternative to the closed-source MSI Util v3. A reboot is needed for the change to take effect.

[Unreleased]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.5...v1.2.0
[1.1.5]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/vadyaravadim/msi-mode-utility/releases/tag/v1.0.0
