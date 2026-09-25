# MSI Mode Utility

A single self-contained PowerShell script (`msi-mode-utility.ps1`) that lists PCI devices in an
`Out-GridView` picker and switches the selected ones to MSI (Message Signaled Interrupts) by writing the
documented `MSISupported` value. Part of a family of six single-script Windows tuning tools that share this
layout: one `.ps1`, `Run.bat`, `PSScriptAnalyzerSettings.psd1`, and the same three workflows.

**`Out-GridView` is a hard dependency and the check for it stays up front.** It exists only on Windows
editions with a desktop - Server Core has none, while PowerShell 7 on a desktop edition does have it; failing
early with instructions beats a raw `CommandNotFound` thrown halfway through a scan the user already
waited on.

## Invariants

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
  silently drop `-ShowAll` or `-Disable`. Splat it as `@(...)`: on PS 5.1 a single forwarded switch unrolls
  to a scalar string and breaks `powershell.exe -File` switch binding.
- **The elevated window must stay open on the error paths too.** The `trap` plus `Wait-IfElevatedWindow`
  exist because an unhandled error otherwise closes the window before the message can be read; under
  `irm | iex` the trap rethrows instead of calling `exit`, which would close the user's own console.

## The two CI gates

- **`ascii-check.yml` - the .ps1 must be pure ASCII with no BOM.** Both halves are load-bearing: a BOM
  makes `irm | iex` choke on a leading U+FEFF, and non-ASCII in a BOM-less file turns into mojibake when
  Windows PowerShell 5.1 runs it with `-File`. Write `\uXXXX` regex escapes rather than literals; em-dashes
  and typographic quotes are the usual way this reds. Only the `.ps1` is checked - Markdown is free.
- **`lint.yml` - PSScriptAnalyzer over the whole repo, Error + Warning, any finding fails.** Suppressions
  live in `PSScriptAnalyzerSettings.psd1` with the reason written next to each rule. Extend that file with
  a justification instead of adding an inline suppression attribute.

## Release - the tag is the only source of truth

`git tag vX.Y.Z && git push origin vX.Y.Z` runs `release.yml`, which stamps the tag into `.VERSION`, hashes
the script, attests build provenance, creates the GitHub Release and publishes to the PowerShell Gallery.
Nothing ships from a push to `main`.

- **The `irm | iex` URL is `releases/latest/download/msi-mode-utility.ps1` - in the README AND in the
  script's bootstrap download, never `raw.githubusercontent.com/.../main`.** That is what keeps the
  sentence above true for the one-liner, and makes the saved copy byte-identical to the attested asset.
- **`release.yml` calls `lint.yml` and `ascii-check.yml` through `workflow_call` and `needs:` both.** Their
  push-triggered runs on the tag do not block the release, and a PSGallery version cannot be re-published.
- **`v*` tags cannot be moved or deleted (tag ruleset) and releases are immutable (repo setting).** A broken
  release is fixed with a new patch tag, never by re-tagging.

**Before tagging, move the `## [Unreleased]` bullets in `CHANGELOG.md` into a `## [X.Y.Z] - YYYY-MM-DD`
section and add the compare link at the bottom.** The release job copies exactly that section into the
release body and **fails the release when the tag's section is missing**. This is a gate on purpose, not a
fallback: notes are hand-written because GitHub's `--generate-notes` lists merged PRs, and this repo lands
nearly everything as direct commits to `main`, so it published releases whose whole body was a compare
link.

Write the entries for someone who runs the tool, not for someone reading the diff: what changed on their
machine and why it matters. A fix says what was broken and what it cost them.

Do NOT bump `.VERSION` in the `.ps1` by hand - it is a placeholder the workflow overwrites, and a
hand-edited value that disagrees with the tag would only mislead whoever reads the committed file.
**The placeholder is `0.0.0` and must stay exactly that**: the banner reads its own `.VERSION` line and
prints `dev build` for `0.0.0`, the stamped tag otherwise. It used to be `1.0.0`, which is also a real tag,
so a clone of `main` was indistinguishable from the v1.0.0 release.

## The RigPolice pages that mirror this script

- **The hub card.** `src/lib/latency-toolbox.ts` in the rigpolice repo holds this script's card on
  https://rigpolice.com/system/latency-toolbox/: what it does, what was measured with it, and whether it
  writes an undo file. A release that changes any of those updates the card in the same pass; nothing
  there reads this repo, so the card drifts silently otherwise.
- **The companion article.** `src/content/articles/enable-msi-mode.md` (the "How to enable it"
  section) quotes the `irm | iex` one-liner, describes what a run prints and explains the undo. A
  change to the one-liner URL, the run output or the undo mechanism updates that article in the same
  pass. rigpolice's `src/lib/latency-toolbox.test.ts` reds on a one-liner that is not the release URL;
  the output and the undo text have no gate, so check them against this README by hand.
