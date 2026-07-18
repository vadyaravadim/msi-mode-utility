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
    [switch]$Elevated,  # internal: set by the self-elevation relaunch
    [switch]$FromIex    # internal: elevated rerun of a piped (irm | iex) script - undo falls back to Desktop
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

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as Administrator. Requesting elevation..." -ForegroundColor Yellow
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        # Launched via `irm ... | iex` - no file on disk to relaunch, and the
        # piped text is not recoverable from inside iex ($MyInvocation there
        # holds the caller's command line, not the script body). Download to a
        # file and elevate that, so -Elevated/-FromIex and the mode switches
        # still flow through.
        $scriptPath = Join-Path $env:TEMP 'msi-mode-utility.ps1'
        Invoke-RestMethod 'https://raw.githubusercontent.com/vadyaravadim/msi-mode-utility/main/msi-mode-utility.ps1' -OutFile $scriptPath
    }
    try {
        # Always powershell.exe (not pwsh) so Out-GridView is guaranteed.
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                     '-File', "`"$scriptPath`"", '-Elevated')
        if (-not $PSCommandPath) { $argList += '-FromIex' }
        if ($ShowAll) { $argList += '-ShowAll' }
        if ($Disable) { $argList += '-Disable' }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host "ERROR: elevation was refused. Run this script as Administrator." -ForegroundColor Red
    }
    return
}

# PowerShell 7 ships without Out-GridView (Server Core has none at all);
# fail up front with instructions instead of a raw CommandNotFound mid-run.
if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
    Write-Host "Out-GridView is not available in this PowerShell. Run the script with Windows PowerShell (powershell.exe), or install the Microsoft.PowerShell.GraphicalTools module." -ForegroundColor Red
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

function Get-DeviceName {
    param([Microsoft.Win32.RegistryKey]$Key)
    $fn = $Key.GetValue('FriendlyName')
    if ([string]::IsNullOrWhiteSpace($fn)) { $fn = $Key.GetValue('DeviceDesc') }
    if ($fn -and $fn -match ';') {
        # Strip the @res;Text prefix; keep the raw string if nothing follows ';'
        # (a malformed indirect string) so the device stays visible.
        $text = $fn.Split(';')[-1]
        if (-not [string]::IsNullOrWhiteSpace($text)) { $fn = $text }
    }
    return $fn
}

Write-Host "Scanning PCI devices..." -ForegroundColor Cyan
$pciRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
$rows = New-Object System.Collections.Generic.List[object]

$hidden = 0
foreach ($devClass in Get-ChildItem $pciRoot -ErrorAction SilentlyContinue) {
    foreach ($inst in Get-ChildItem $devClass.PSPath -ErrorAction SilentlyContinue) {
        $name = Get-DeviceName -Key $inst
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        # MSI-capable devices expose "Device Parameters\Interrupt Management".
        $imPath = Join-Path $inst.PSPath 'Device Parameters\Interrupt Management'
        if (-not (Test-Path $imPath)) { continue }

        if (-not $ShowAll) {
            # HD Audio controllers register under the System class, not Media;
            # their locale-invariant marker is the HDAudBus service.
            $classGuid = $inst.GetValue('ClassGUID')
            if ($classGuid -notin $IncludeClassGuids -and
                $inst.GetValue('Service') -ne 'HDAudBus') { $hidden++; continue }
        }

        # Absent key/value = no explicit override: the driver default applies,
        # and MSI-X-capable devices may already run in MSI-X mode regardless.
        $msiPath = Join-Path $imPath 'MessageSignaledInterruptProperties'
        $v = (Get-ItemProperty -Path $msiPath -Name 'MSISupported' -ErrorAction SilentlyContinue).MSISupported
        $status = 'Default'
        if     ($v -eq 1) { $status = 'Enabled' }
        elseif ($v -eq 0) { $status = 'Disabled' }

        $rows.Add([PSCustomObject]@{
            Name       = $name
            MSI        = $status
            DeviceID   = $inst.PSChildName
            RegPath    = $msiPath   # target key we will write
        })
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No matching devices found. Try -ShowAll." -ForegroundColor Yellow
    Wait-IfElevatedWindow
    return
}
if ($hidden) {
    Write-Host "$hidden more MSI-capable device(s) (storage controllers, bridges, ...) are hidden by the default filter. Use -ShowAll to include them." -ForegroundColor DarkGray
}

if ($Disable) { $action = 'DISABLE'; $target = 0; $label = 'OFF' }
else          { $action = 'enable';  $target = 1; $label = 'ON ' }
$selected = $rows |
    Sort-Object MSI, Name |
    Out-GridView -Title "Select devices to $action MSI Mode (Ctrl-click for multiple)" -PassThru

if (-not $selected) {
    Write-Host "No devices selected. No changes made." -ForegroundColor Yellow
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
# Next to the script; via `irm | iex` fall back to the Desktop - durable, and
# resolved through the known-folder API so OneDrive redirection (Known Folder
# Move) is honored, unlike a hardcoded $env:USERPROFILE\Desktop. -FromIex marks
# the elevated rerun of a piped script: it HAS a file path (the %TEMP% shim),
# but undo must not land in %TEMP%.
$undoDir = if ($PSCommandPath -and -not $FromIex) { $PSScriptRoot } else { [Environment]::GetFolderPath('Desktop') }
$undoFile = Join-Path $undoDir "msi_undo_$stamp.reg"
$n = 1
while (Test-Path $undoFile) { $undoFile = Join-Path $undoDir ("msi_undo_{0}_{1}.reg" -f $stamp, $n++) }
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
Wait-IfElevatedWindow