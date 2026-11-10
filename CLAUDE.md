# MSI Mode Utility

A single self-contained PowerShell script (`msi-mode-utility.ps1`) that lists PCI devices in an
`Out-GridView` picker and switches the selected ones to MSI (Message Signaled Interrupts) by writing the
documented `MSISupported` value. Part of a family of six single-script Windows tuning tools that share this
layout: one `.ps1`, `Run.bat`, `PSScriptAnalyzerSettings.psd1`, and two thin workflows, `ci.yml` and
`release.yml`, that call the family's shared pipeline in `vadyaravadim/latency-toolbox-ci`.

**`Out-GridView` is a hard dependency and the check for it stays up front.** It exists only on Windows
editions with a desktop - Server Core has none, while PowerShell 7 on a desktop edition does have it; failing
early with instructions beats a raw `CommandNotFound` thrown halfway through a scan the user already
waited on. `-Status` prints to the console, so it skips that check and the elevation.

**The `Mode` column, not `MSI`, is what a device runs in.** `MSI` is the registry override, and it shows
the value an INF or a tool wrote. `Mode` comes from the IRQs Windows assigned this boot
(`Win32_PNPAllocatedResource`; negative = message-signaled, WMI reports it unsigned) - do not derive it
from `MSISupported`.

## Invariants

- **A run that changes nothing writes NO undo file.** Devices already at the target are dropped from the
  selection first; a snapshot of an already-tweaked device would make the newest undo file "revert" to the
  tweak.
- **Only present devices are listed** (`Get-PnpDevice -PresentOnly`). `Enum\PCI` keeps the keys of removed
  hardware, and writing those reports success while changing nothing.

- **The undo `.reg` is a per-run snapshot, written next to the script BEFORE any change.** After several
  runs over the same device they must be applied newest-to-oldest - only the oldest holds the original
  state. `-Disable` is not an undo: it writes an explicit `0`, which is not the same as the value being
  absent, and only the `.reg` restores that.
- **A piped run saves the script into the user profile, not `%TEMP%`.** The undo file is written next to
  the script, so it has to sit somewhere that survives automatic temp cleanup. This replaced an earlier
  Desktop-fallback path plus a `-FromIex` switch; do not reintroduce a second location for the undo file -
  one path for every launch mode is the point.
- **`Get-ForwardedSwitchList` is the ONE place mode switches are listed.** Both relaunch paths - the
  `irm | iex` bootstrap rerun and the UAC elevation - build their argument list from it, so neither can
  silently drop `-ShowAll`, `-Disable` or `-Status`. Splat it as `@(...)`: on PS 5.1 a single forwarded switch unrolls
  to a scalar string and breaks `powershell.exe -File` switch binding.
- **The elevated window must stay open on the error paths too.** The `trap` plus `Wait-IfElevatedWindow`
  exist because an unhandled error otherwise closes the window before the message can be read; under
  `irm | iex` the trap rethrows instead of calling `exit`, which would close the user's own console.

## The CI gates

The gates and the release job live in `.github/workflows/pipeline.yml` of `vadyaravadim/latency-toolbox-ci`,
not here: `ci.yml` runs it on every push and pull request, `release.yml` from a dispatch. Change a gate there.

- **The ASCII gate - every tracked `.ps1` must be pure ASCII with no BOM.** Both halves are load-bearing: a
  BOM makes `irm | iex` choke on a leading U+FEFF, and non-ASCII in a BOM-less file turns into mojibake when
  Windows PowerShell 5.1 runs it with `-File`. Write `\uXXXX` regex escapes rather than literals; em-dashes
  and typographic quotes are the usual way this reds. Only `.ps1` files are checked - Markdown is free.
- **The lint gate - PSScriptAnalyzer over the whole repo, Error + Warning, any finding fails.** Suppressions
  live in `PSScriptAnalyzerSettings.psd1` with the reason written next to each rule; add a justified
  exclusion there instead of an inline suppression attribute. The file is the family's: lint fails unless it
  is byte-identical to the one in `vadyaravadim/latency-toolbox-ci` at the pinned commit, so change it there
  and copy it into all six repos. Lint also fails unless `ci.yml` and `release.yml` pin `latency-toolbox-ci`
  to the full SHA of the commit the run uses. It also checks syntax and .NET types against Windows
  PowerShell 5.1 (`PSUseCompatibleSyntax`/`PSUseCompatibleTypes`). The type check knows APIs only up to .NET
  Core 3.1, so a newer one such as `[Convert]::ToHexString` passes lint and only the 5.1 test leg catches
  it. `PSUseCompatibleCommands` stays off: it flagged every Pester 5 parameter against the Pester 3.4 built
  into 5.1.
- **The Pester gate runs every tracked `*.Tests.ps1` under Windows PowerShell 5.1 and the runner's `pwsh`,
  and both legs block the release:** 5.1 is what `Run.bat` and the elevated relaunch always run, so test code
  stays 5.1-safe too - no .NET Core-only APIs, and `ConvertFrom-Json` there emits a top-level array as one
  object. A third leg on a pinned PowerShell preview (downloaded, SHA256-checked) only warns: it is
  `continue-on-error`, red without blocking. Nothing bumps that pin - move it by hand in `pipeline.yml`: to
  the final release when it ships, and once `windows-latest` itself ships that version, on to the next
  preview, or drop the leg if there is none. A repo with no test file passes the gate with a notice.

## Release - the newest CHANGELOG section is the version

`gh workflow run release.yml` (or Actions > release > Run workflow) on `main` releases the newest
`## [X.Y.Z]` section of `CHANGELOG.md`: it gates that commit, stamps the version into `.VERSION`, hashes the
script, attests build provenance, publishes to the PowerShell Gallery and, last, creates the GitHub Release,
which creates the `vX.Y.Z` tag at that commit. A run from any other branch fails in the release job before
anything is written. Nothing ships from a push to `main`, and no tag exists until every gate has passed.

- **The `irm | iex` URL is `releases/latest/download/msi-mode-utility.ps1` - in the README AND in the
  script's bootstrap download, never `raw.githubusercontent.com/.../main`.** That is what keeps the
  sentence above true for the one-liner, and makes the saved copy byte-identical to the attested asset.
- **`ci.yml` and `release.yml` pin `pipeline.yml` of `vadyaravadim/latency-toolbox-ci` to the same full
  commit SHA, with its version tag as a comment.** There the release job `needs:` the lint, ASCII and Pester
  jobs of the same run, on the same commit: the push-triggered `ci` runs on `main` do not block a release,
  and a PSGallery version cannot be re-published. A pipeline change reaches this repo only when the pin
  moves: Dependabot proposes the bump monthly, a hand bump changes both lines together (lint fails while
  they differ), and reverting the whole bump - including a `PSScriptAnalyzerSettings.psd1` copy it brought -
  undoes it.
- **The provenance is signed by `pipeline.yml` of `vadyaravadim/latency-toolbox-ci`, not by this repo.**
  `gh attestation verify` needs
  `--signer-workflow vadyaravadim/latency-toolbox-ci/.github/workflows/pipeline.yml` (SECURITY.md); 1.1.3 to
  1.2.0 were signed by this repo's own `release.yml`, earlier releases carry no provenance. Never rename or
  delete `latency-toolbox-ci`: GitHub does not redirect a renamed reusable workflow, so every caller breaks.
- **`v*` tags cannot be moved or deleted (tag ruleset) and releases are immutable (repo setting).** A broken
  release is fixed by releasing a new patch version (a new CHANGELOG section), never by re-tagging. The
  ruleset leaves tag creation open on purpose: the release creates the tag with `GITHUB_TOKEN`.
- **Never push a `v*` tag by hand.** It starts no release and cannot be deleted; unless it sits on the exact
  commit the release then runs on, the release stops before publishing and that version is burned.
- **Finish a failed release with "Re-run failed jobs" on that run, not a new run.** The re-run builds the
  same commit with the same pinned pipeline: the Gallery step (`.github/Publish-GalleryScript.ps1` of
  `vadyaravadim/latency-toolbox-ci`) skips a version already there with identical bytes and fails on
  different bytes. A run cancelled during the GitHub Release step can leave a draft - delete it before
  re-running. Release the next version instead only when that run is older than 30 days and can no longer
  be re-run. A failure inside the pipeline itself needs a fixed `latency-toolbox-ci` version, a bump here and
  a new run.

**Before releasing, move the `## [Unreleased]` bullets in `CHANGELOG.md` into a `## [X.Y.Z] - YYYY-MM-DD`
section and add its `[X.Y.Z]: .../compare/vPREV...vX.Y.Z` link at the bottom.** That section is the
version. The release job copies exactly that section into the release body and **fails before anything is
tagged or published when it is empty or its compare link is missing**; a newest section that is already
released fails the same way. This is a gate on purpose, not a fallback: notes are hand-written because
GitHub's `--generate-notes` lists merged PRs, and this repo lands nearly everything as direct commits to
`main`, so it published releases whose whole body was a compare link.

Write the entries for someone who runs the tool, not for someone reading the diff: what changed on their
machine and why it matters. A fix says what was broken and what it cost them.

Do NOT bump `.VERSION` in the `.ps1` by hand - it is a placeholder the workflow overwrites, and a
hand-edited value that disagrees with the tag would only mislead whoever reads the committed file.
**The placeholder is `0.0.0` and must stay exactly that**: the banner reads its own `.VERSION` line and
prints `dev build` for `0.0.0`, the stamped tag otherwise. It used to be `1.0.0`, which is also a real tag,
so a clone of `main` was indistinguishable from the v1.0.0 release.

## README claims

**The README claims only what a published measurement shows** (the companion article, `bench/results`).
An effect nobody measured, on frame times, DPC latency, stutter or input lag, is attributed to the guides
that recommend the tweak or marked as not measured, never stated as fact, and the star ask names no
effect. Frame time and ISR/DPC time are not input lag. The method lives in rigpolice's
`.claude/rules/bench-methodology.md`, section "Conclusions".

## The RigPolice pages that mirror this script

Every copy of the verdict (what MSI mode did or did not change in our measurements) is rewritten together
after a retest: the README FAQ, `bench/results/README.md`, the RigPolice article, the toolbox card and the
toolbox FAQ on /system/latency-toolbox/, the article chart data and the release notes.

- **The hub card.** `src/lib/latency-toolbox.ts` in the rigpolice repo holds this script's card on
  https://rigpolice.com/system/latency-toolbox/: what it does, what was measured with it, and whether it
  writes an undo file. A release that changes any of those updates the card in the same pass; nothing
  there reads this repo, so the card drifts silently otherwise.
- **The companion article.** `src/content/articles/enable-msi-mode.md` (the "How to enable it"
  section) quotes the `irm | iex` one-liner, describes what a run prints and explains the undo. A
  change to the one-liner URL, the run output or the undo mechanism updates that article in the same
  pass. rigpolice's `src/lib/latency-toolbox.test.ts` reds on a one-liner that is not the release URL;
  the output and the undo text have no gate, so check them against this README by hand.
