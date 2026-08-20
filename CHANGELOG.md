# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released section below IS the GitHub Release body for that tag: `release.yml` copies the section
verbatim into the release and fails the release if the tag has no section here.

## [Unreleased]

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
- `-ShowAll` and `-Disable` could be dropped on the way through a relaunch. Both relaunch paths - the
  piped-run rerun and the UAC elevation - now build their arguments from one shared list, so neither can
  lose a switch. A single forwarded switch also used to break argument binding on Windows PowerShell 5.1.

### Changed

- The undo `.reg` now always lands next to the script, on every launch path. A piped run used to have no
  script directory of its own and fell back to writing the undo file on your Desktop; the run now saves
  itself into your user profile first and works from there, so the fallback and its `-FromIex` switch are
  gone.
- A failed download or a failed elevation now prints the actual reason - no internet, UAC refused, UAC
  service disabled - and keeps the window open, instead of the console closing on an empty screen.

## [1.1.2] - 2026-07-18

### Changed

- Elevation under `irm | iex` was reworked to relaunch the text that was actually executing rather than
  re-fetching `main`, so that a fork or a pinned commit would keep running after the UAC prompt. This did
  not hold in practice - see the 1.1.3 fix.

## [1.1.1] - 2026-07-18

### Fixed

- When the one-liner failed to download the script, the elevated window closed before you could read why.
  It now stays open on that error.

## [1.1.0] - 2026-07-18

### Added

- The tool runs from a one-line `irm ... | iex` command, self-elevating through UAC. A piped run has no
  script directory, so the undo `.reg` was written to the Desktop in that case.

## [1.0.1] - 2026-07-18

### Fixed

- Two runs within the same second silently destroyed the first run's undo file. The file is named from a
  whole-second timestamp and was overwritten without asking, so the `.reg` you would have reverted with was
  gone. Colliding names now get a numeric suffix.

## [1.0.0] - 2026-07-17

### Added

- First release. Lists your PCI devices with their MSI (Message Signaled Interrupts) status in a grid and
  switches the devices you pick to MSI mode by writing the documented `MSISupported` value.
- `-Disable` sets the selected devices to MSI off instead of on; `-ShowAll` includes the bridges and
  abstract controllers that are hidden by default.
- Writes an `msi_undo_<stamp>.reg` next to the script before any change, so one double-click reverts that
  run. Note that `-Disable` writes an explicit `0` rather than restoring a value that was originally
  absent - only the undo file restores that.
- Self-elevates through UAC and keeps the elevated window open on both success and error. Zero external
  dependencies, Windows PowerShell 5.1+. A reboot is needed for the change to take effect.

[Unreleased]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.3...HEAD
[1.1.3]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/vadyaravadim/msi-mode-utility/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/vadyaravadim/msi-mode-utility/releases/tag/v1.0.0
