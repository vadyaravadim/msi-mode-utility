# Security Policy

## Reporting a Vulnerability

Please report security issues **privately** via
[GitHub Security Advisories](https://github.com/vadyaravadim/msi-mode-utility/security/advisories/new)
— not through a public issue.

Expect a first response within 7 days. If a fix is warranted, it ships as a new
tagged release and the advisory is published once the fix is available.

## Supported Versions

Only the latest release receives fixes. Older tags are left as-is — update to the
newest version before reporting.

## Scope

This script runs **with administrator rights** and writes the `MSISupported`
registry value under `HKLM\SYSTEM\CurrentControlSet\Enum\PCI` for the devices
you select. That is its intended purpose, not a vulnerability.

In scope:

- The self-elevation path (`irm | iex` saving to `%USERPROFILE%` and re-running
  from there) — e.g. a way to make it execute attacker-controlled content
- The saved-copy / `.bak` handling — e.g. a path that overwrites an unrelated file
- The undo file (`msi_undo_*.reg`) — e.g. a registry path that makes the script
  write a `.reg` touching keys or values it never changed
- The release pipeline — checksums, provenance, or the PowerShell Gallery package
  not matching the tagged source

Out of scope:

- Requiring admin rights, or the UAC prompt
- Needing a reboot for the change to take effect — documented in
  [Using the picker](README.md#using-the-picker)
- A device that misbehaves or fails to start with MSI enabled — documented in the
  [Disclaimer](README.md#disclaimer), and reversible per
  [Reverting](README.md#reverting)
- Applying an undo `.reg` file you edited by hand

## Verifying a Release

Each release publishes `SHA256SUMS.txt` and Sigstore build provenance. Verify a
download before running it:

```powershell
Get-FileHash .\msi-mode-utility.ps1 -Algorithm SHA256
```

Compare the hash against the one in the corresponding
[release](https://github.com/vadyaravadim/msi-mode-utility/releases).

The hash only proves the file matches the release page. The provenance proves the
file was built from the tagged commit of this repository by the release workflow
shared by the six RigPolice Latency Toolbox scripts,
[`vadyaravadim/latency-toolbox-ci`](https://github.com/vadyaravadim/latency-toolbox-ci) - check it
with the [GitHub CLI](https://cli.github.com/):

```powershell
gh attestation verify .\msi-mode-utility.ps1 -R vadyaravadim/msi-mode-utility --signer-workflow vadyaravadim/latency-toolbox-ci/.github/workflows/pipeline.yml
```

Without `--signer-workflow` the command rejects these releases: by default it only
accepts a signature from this repository's own workflows.

Releases v1.1.3 to v1.2.0 were built by this repository's own `release.yml`
(earlier ones carry no provenance). Verify those with:

```powershell
gh attestation verify .\msi-mode-utility.ps1 -R vadyaravadim/msi-mode-utility
```

Releases from v1.1.4 on are immutable: when one is published, GitHub itself attests
its tag, its commit and every file attached to it. That check does not depend on
which workflow built the file:

```powershell
gh release verify-asset vX.Y.Z .\msi-mode-utility.ps1 -R vadyaravadim/msi-mode-utility
```
