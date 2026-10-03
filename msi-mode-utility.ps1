<#PSScriptInfo

.VERSION 0.0.0

.GUID 01a3b6f9-f755-49e4-8cff-86c95dc4cb83

.AUTHOR vadyaravadim

.COMPANYNAME

.COPYRIGHT

.TAGS Windows Windows10 Windows11 Gaming MSI MessageSignaledInterrupts DPC Latency PCI GPU Performance Tweak

.LICENSEURI https://github.com/vadyaravadim/msi-mode-utility/blob/main/LICENSE

.PROJECTURI https://github.com/vadyaravadim/msi-mode-utility

.ICONURI

.EXTERNALMODULEDEPENDENCIES

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES

.PRIVATEDATA

#>

<#
.SYNOPSIS
    Native MSI (Message Signaled Interrupts) mode manager for PCI devices.
.DESCRIPTION
    Lists PCI devices, shows their MSI status in Out-GridView, and enables MSI
    for the devices you select. Zero external dependencies. Windows PowerShell 5.1+.
.PARAMETER ShowAll
    Show every MSI-capable PCI device, including bridges and abstract
    controllers (hidden by default).
.PARAMETER Disable
    Set the selected devices to MSI OFF instead of ON.
.PARAMETER Status
    Print the device list with the interrupt mode each device actually runs
    in, change nothing. Does not need Administrator rights.
.NOTES
    A reboot is required for changes to take effect.
    Revert: apply the msi_undo_*.reg file written before each change.
    Each undo file is a per-run snapshot: after several runs touching the
    same device, apply them newest-to-oldest - only the oldest file holds
    the original state.
    (-Disable writes an explicit 0; it does not restore the original
    "value absent" state - only the undo file does.)
#>
[CmdletBinding()]
param(
    [switch]$ShowAll,
    [switch]$Disable,
    [switch]$Status,
    [switch]$Elevated   # internal: set by the self-elevation relaunch
)

$ErrorActionPreference = 'Stop'

# Keep the self-elevated window open so the user can read the output.
function Wait-IfElevatedWindow {
    if ($Elevated) { Read-Host "Press Enter to close" | Out-Null }
}

# Without this, an unhandled error closes the self-elevated window before
# the user can read the message.
trap {
    Write-Host "ERROR: $_" -ForegroundColor Red
    Wait-IfElevatedWindow
    # Under `irm | iex` this runs inside the user's own session, where `exit`
    # would close their console - rethrow so only the piped script stops.
    if ($PSCommandPath) { exit 1 }
    break
}

# Mode switches forwarded on every relaunch (the irm|iex bootstrap rerun below
# and the self-elevation later) - one list so neither path can silently drop one.
function Get-ForwardedSwitchList {
    $a = @()
    if ($ShowAll) { $a += '-ShowAll' }
    if ($Disable) { $a += '-Disable' }
    if ($Status)  { $a += '-Status' }
    $a
}

# Launched via `irm <url> | iex` - no file on disk. The undo .reg is written
# next to the script, so a stable path is required: save the script to the
# user profile (not TEMP - the undo file must survive automatic temp cleanup)
# and rerun it from there (the rerun handles elevation).
if (-not $PSCommandPath) {
    # The piped text is not recoverable from inside iex ($MyInvocation there
    # holds the caller's command line, not the script body) - download the
    # script.
    try {
        $body = Invoke-RestMethod 'https://github.com/vadyaravadim/msi-mode-utility/releases/latest/download/msi-mode-utility.ps1' -TimeoutSec 30
    } catch {
        Write-Host "ERROR: could not download the script ($($_.Exception.Message)). Check your internet connection, or save the script to a file and run it from there." -ForegroundColor Red
        return
    }
    $saved = Join-Path $env:USERPROFILE 'msi-mode-utility.ps1'
    if ((Test-Path $saved) -and ([IO.File]::ReadAllText($saved) -cne $body)) {
        Copy-Item $saved "$saved.bak" -Force
        Write-Host "Existing $saved differs - previous copy kept as $saved.bak" -ForegroundColor Yellow
    }
    # UTF8Encoding($false) = no BOM: a BOM would break a later `irm | iex` of
    # the saved copy and violates the ASCII/no-BOM invariant the repo enforces.
    [IO.File]::WriteAllText($saved, $body, [Text.UTF8Encoding]::new($false))
    Write-Host "Script saved to: $saved (the undo file will be written next to it)" -ForegroundColor Cyan
    # @(): a single forwarded switch unrolls to a scalar, and splatting a
    # scalar string breaks powershell.exe -File switch binding on PS 5.1.
    $fwd = @(Get-ForwardedSwitchList)
    powershell -NoProfile -ExecutionPolicy Bypass -File $saved @fwd
    # The rerun's exit code stays in $LASTEXITCODE for scripted callers.
    return
}

# ---- Everything below -Status writes the registry: Administrator required ----
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $Status -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as Administrator. Requesting elevation..." -ForegroundColor Yellow
    try {
        # Always powershell.exe (not pwsh) so Out-GridView is guaranteed.
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                     '-File', "`"$PSCommandPath`"", '-Elevated') + (Get-ForwardedSwitchList)
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        # Not always a refusal (UAC service disabled, ...) - show the real cause.
        Write-Host "ERROR: elevation failed ($($_.Exception.Message)). Run this script as Administrator." -ForegroundColor Red
        Read-Host "Press Enter to close" | Out-Null
    }
    return
}

# Read from this file's own PSScriptInfo block - the one place the version
# lives (release.yml stamps the tag into it). 0.0.0 is the committed
# placeholder: a clone or ZIP of main, not a release.
$version = [regex]::Match((Get-Content $PSCommandPath -Raw), '(?m)^\.VERSION\s+(\S+)').Groups[1].Value
$version = if ($version -eq '0.0.0') { 'dev build' } else { "v$version" }

Write-Host ""
Write-Host "===================================" -ForegroundColor Cyan
Write-Host "  MSI MODE UTILITY $version" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan
Write-Host ""

# Out-GridView exists only on Windows editions with a desktop - Server Core has
# none; fail up front with instructions instead of a raw CommandNotFound mid-run.
# -Status prints to the console and does not need it.
if (-not $Status -and -not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
    Write-Host "Out-GridView is not available in this PowerShell. It needs a Windows edition with a desktop (not Server Core); on a desktop edition, run the script with Windows PowerShell (powershell.exe)." -ForegroundColor Red
    Wait-IfElevatedWindow
    return
}

# Latency-critical classes kept when -ShowAll is NOT set. Matched by ClassGUID,
# not display name: names are localized and OEM-specific (a real xHCI controller
# can be named "(Intel(R),3.20,1.20)"), so keyword matching silently misses devices.
$IncludeClassGuids = @(
    '{4d36e968-e325-11ce-bfc1-08002be10318}',  # Display (GPU)
    '{4d36e972-e325-11ce-bfc1-08002be10318}',  # Net (NIC)
    '{4d36e96c-e325-11ce-bfc1-08002be10318}',  # Media (sound cards)
    '{36fc9e60-c465-11cf-8056-444553540000}'   # USB host controllers
)

Write-Host "Scanning PCI devices..." -ForegroundColor Cyan
# Present devices only: Enum\PCI also keeps the keys of removed hardware (an
# old GPU), and writing those changes nothing. Windows resolves the names.
$present = @(Get-PnpDevice -PresentOnly)
$names = @{}
foreach ($d in $present) { $names[$d.InstanceId] = $d.FriendlyName }

# The interrupts Windows actually assigned this boot - what the device runs
# in, whatever MSISupported says: a negative IRQ number is a message-signaled
# vector, a non-negative one a legacy line that other devices may share.
$irqs = @{}
$lineUsers = @{}
foreach ($r in Get-CimInstance Win32_PNPAllocatedResource) {
    if ($r.Antecedent.CimClass.CimClassName -ne 'Win32_IRQResource') { continue }
    $n = [int64]$r.Antecedent.IRQNumber
    if ($n -gt 2147483647) { $n -= 4294967296 }   # WMI reports it unsigned
    $irqs[$r.Dependent.DeviceID] += @($n)
    if ($n -ge 0) { $lineUsers[$n] += @($r.Dependent.DeviceID) }
}

$rows = New-Object System.Collections.Generic.List[object]
$hidden = 0
foreach ($dev in $present) {
    if ($dev.InstanceId -notlike 'PCI\*' -or -not $dev.FriendlyName) { continue }

    # MSI-capable devices expose "Device Parameters\Interrupt Management".
    $imPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\$($dev.InstanceId)\Device Parameters\Interrupt Management"
    if (-not (Test-Path $imPath)) { continue }

    # HD Audio controllers register under the System class, not Media; their
    # locale-invariant marker is the HDAudBus service.
    if (-not $ShowAll -and $dev.ClassGuid -notin $IncludeClassGuids -and $dev.Service -ne 'HDAudBus') {
        $hidden++; continue
    }

    # Absent key/value = no explicit override: the driver default applies,
    # and MSI-X-capable devices may already run in MSI-X mode regardless.
    $msiPath = "$imPath\MessageSignaledInterruptProperties"
    $v = (Get-ItemProperty -Path $msiPath -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
    $setting = 'Default'
    if     ($v -eq 1) { $setting = 'Enabled' }
    elseif ($v -eq 0) { $setting = 'Disabled' }

    $vectors = $irqs[$dev.InstanceId]
    $lines = @($vectors | Where-Object { $_ -ge 0 })
    if ($lines) {
        $shared = @()
        foreach ($n in $lines) {
            foreach ($other in $lineUsers[$n]) {
                if ($other -ne $dev.InstanceId -and $names[$other]) { $shared += $names[$other] }
            }
        }
        $mode = "Line IRQ $($lines -join ',')"
        if ($shared) { $mode += ", shared with: $($shared -join '; ')" }
    } elseif ($vectors) {
        $mode = 'MSI'
    } else {
        $mode = '-'
    }

    $rows.Add([PSCustomObject]@{
        Name       = $dev.FriendlyName
        MSI        = $setting
        Mode       = $mode
        DeviceID   = $dev.InstanceId
        RegPath    = $msiPath   # target key we will write
    })
}

if ($rows.Count -eq 0) {
    Write-Host "No matching devices found. Try -ShowAll." -ForegroundColor Yellow
    Wait-IfElevatedWindow
    return
}
if ($hidden) {
    Write-Host "$hidden more MSI-capable device(s) (storage controllers, bridges, ...) are hidden by the default filter. Use -ShowAll to include them." -ForegroundColor DarkGray
}

# Line-IRQ devices sort first: they are the ones MSI can change.
$rows = $rows | Sort-Object Mode, Name
if ($Status) {
    $rows | Format-Table Name, MSI, Mode -AutoSize -Wrap | Out-Host
    Wait-IfElevatedWindow; return
}

if ($Disable) { $action = 'DISABLE'; $target = 0; $label = 'OFF'; $targetState = 'Disabled' }
else          { $action = 'enable';  $target = 1; $label = 'ON ';  $targetState = 'Enabled' }
$selected = $rows |
    Out-GridView -Title "Select devices to $action MSI Mode (Ctrl-click for multiple)" -PassThru

if (-not $selected) {
    Write-Host "No devices selected. No changes made." -ForegroundColor Yellow
    Wait-IfElevatedWindow
    return
}

# A device already at the target would still get an undo file whose
# "previous" value is the tweak itself, and be reported as updated.
$selected = @($selected | Where-Object MSI -ne $targetState)
if (-not $selected) {
    Write-Host "Every selected device is already $($targetState.ToLower()) - nothing to change, no undo file written." -ForegroundColor Green
    Wait-IfElevatedWindow
    return
}

# Lightweight rollback: record the CURRENT state of every selected key into a
# .reg file BEFORE changing anything. Double-clicking it reverts everything.
# Undo is value-level on purpose: a "[-key]" stanza would also wipe values the
# tool never wrote (e.g. MessageNumberLimit added later by a driver or tweak);
# deleting just MSISupported may leave an empty key behind, which is harmless.
# The suffix loop keeps two runs within the same second from clobbering
# each other's undo file.
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$undoFile = Join-Path $PSScriptRoot "msi_undo_$stamp.reg"
$n = 1
while (Test-Path $undoFile) { $undoFile = Join-Path $PSScriptRoot ("msi_undo_{0}_{1}.reg" -f $stamp, $n++) }
$undo = New-Object System.Text.StringBuilder
[void]$undo.AppendLine('Windows Registry Editor Version 5.00')
[void]$undo.AppendLine('')
foreach ($d in $selected) {
    # Provider path -> raw path for the .reg format
    $raw = $d.RegPath -replace '^.*Registry::', ''
    $old = (Get-ItemProperty -Path $d.RegPath -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
    [void]$undo.AppendLine("[$raw]")
    if ($null -eq $old) {
        [void]$undo.AppendLine('"MSISupported"=-')          # value was absent -> delete it
    } else {
        [void]$undo.AppendLine(('"MSISupported"=dword:{0:x8}' -f [int]$old))
    }
    [void]$undo.AppendLine('')
}
Set-Content -Path $undoFile -Value $undo.ToString() -Encoding Unicode
Write-Host "Undo file saved: $undoFile (double-click it to revert, then reboot)" -ForegroundColor Cyan

$updated = 0
$failed  = 0
foreach ($d in $selected) {
    try {
        if (-not (Test-Path $d.RegPath)) {
            New-Item -Path $d.RegPath -Force | Out-Null      # create subkey if absent
        }
        New-ItemProperty -Path $d.RegPath -Name 'MSISupported' `
            -Value $target -PropertyType DWord -Force | Out-Null
        Write-Host ("  [{0}] {1}" -f $label, $d.Name) -ForegroundColor Green
        $updated++
    } catch {
        Write-Host ("  [ERR] {0}: {1}" -f $d.Name, $_) -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "Done. $updated of $(@($selected).Count) device(s) updated." -ForegroundColor Green
if ($failed) {
    # The undo file lists the failed devices too; reverting an unchanged value is a no-op.
    Write-Host "$failed device(s) failed - see errors above." -ForegroundColor Yellow
}
Write-Host "REBOOT REQUIRED for changes to take effect." -ForegroundColor Green
if ($updated -and -not $Disable) {
    Write-Host ""
    Write-Host "Useful? A star on GitHub helps others find it: https://github.com/vadyaravadim/msi-mode-utility"
}
Wait-IfElevatedWindow