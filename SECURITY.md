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
file was built by this repository's `release.yml` from the tagged commit - check it
with the [GitHub CLI](https://cli.github.com/):

```powershell
gh attestation verify .\msi-mode-utility.ps1 -R vadyaravadim/msi-mode-utility
```
