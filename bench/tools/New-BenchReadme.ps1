[CmdletBinding()]
param(
    [switch]$Write
)

$ErrorActionPreference = 'Stop'
$benchDir = Split-Path -Parent $PSScriptRoot
$loadsDir = Join-Path $benchDir 'loads'
$readmePath = Join-Path $benchDir 'README.md'

function Read-Json {
    param([string]$Path)
    Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-ValveKeyValues {
    param([string]$Path)
    $values = [ordered]@{}
    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        if ($line -match '^\s*"([^"]+)"\s+"([^"]*)"\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    $values
}

function Format-Arg {
    param([string]$Arg)
    if ($Arg -match '\s') { return '"' + $Arg + '"' }
    $Arg
}

function Get-VideoSection {
    param($Load)
    $video = $Load.videoConfig
    $values = Read-ValveKeyValues -Path (Join-Path $loadsDir $video.file)
    foreach ($key in 'setting.defaultres', 'setting.defaultresheight', 'setting.mat_vsync', 'setting.msaa_samples') {
        if (-not $values.Contains($key)) { throw "$($video.file) has no $key" }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('Video settings: use the provided file `bench\loads\{0}` as is. The mapping from its values to in-game menu labels is not confirmed against a primary source, so do not set the menu by hand.' -f $video.file))
    $out.Add('')
    $out.Add('1. Close CS2.')
    $out.Add(('2. Back up your own file: `{0}`.' -f $video.location))
    $out.Add(('3. Copy `bench\loads\{0}` over it.' -f $video.file))
    $out.Add('4. Run the load.')
    $out.Add('5. Close CS2 and put your backup back.')
    $out.Add('')
    $out.Add(('The file sets {0}x{1} (`setting.defaultres`, `setting.defaultresheight`), `setting.mat_vsync` = {2} and `setting.msaa_samples` = {3}. It also carries `VendorID`, `DeviceID`, `knowndevice`, `Autoconfig` and `Version` from the machine it was captured on. Whether CS2 accepts the file without them is not verified, so they are kept.' -f $values['setting.defaultres'], $values['setting.defaultresheight'], $values['setting.mat_vsync'], $values['setting.msaa_samples']))
    $out.Add('')
    $out
}

function Get-LoadSection {
    param($Load)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(('### {0} (`{1}`)' -f $Load.title, $Load.name))
    $out.Add('')
    $out.Add(('- PresentMon {0}, SHA256 `{1}` ({2}).' -f $Load.presentMon.version, $Load.presentMon.sha256, $Load.presentMon.url))
    if ($Load.program) {
        $out.Add(('- Program: Unigine Superposition {0}, installer `{1}`, SHA256 `{2}`, installed to `{3}`.' -f $Load.program.version, $Load.program.installerFile, $Load.program.installerSha256, $Load.program.installDir))
    }
    if ($Load.workshop) {
        $out.Add(('- Steam app {0} (free), workshop map {1} ("CS2 FPS BENCHMARK" by Angel). The map is a {2} s camera route over {3} and ends with a disconnect by itself.' -f $Load.game.steamAppId, $Load.workshop.id, $Load.workshop.routeSeconds, $Load.workshop.mapName))
    }
    $out.Add(('- Bottleneck: {0}. vsync: {1} (off).' -f $Load.bottleneck.ToUpper(), $Load.vsync))
    $out.Add('')
    $out.Add('Launch arguments:')
    $out.Add('')
    $out.Add('```')
    $exe = if ($Load.program) { $Load.program.exe } else { 'steam.exe' }
    $out.Add($exe + ' ' + ((@($Load.launchArgs) | ForEach-Object { Format-Arg $_ }) -join ' '))
    $out.Add('```')
    $out.Add('')
    if ($Load.program) {
        $out.Add(('Run it from `{0}\bin`. Change `-video_width` and `-video_height` to your monitor''s native resolution.' -f $Load.program.installDir))
        $out.Add('')
    }
    if ($Load.consoleLine) {
        $out.Add(('Wait {0} s for the main menu, bring the game window to the front, then type this into the console (the launch arguments open it) and press Enter:' -f $Load.menuWaitSeconds))
        $out.Add('')
        $out.Add('```')
        $out.Add($Load.consoleLine)
        $out.Add('```')
        $out.Add('')
        $out.Add('The line is fixed; do not edit it. `hideconsole` closes the console so it does not sit over the scene.')
        $out.Add('')
    }
    $out.Add(('Timings: load pause {0} s after the Enter, then capture {1} s.' -f $Load.timings.loadPauseSeconds, $Load.timings.captureSeconds))
    $out.Add('')
    $out.Add('Turn these off in the GPU driver and anywhere else before the run:')
    $out.Add('')
    foreach ($item in @($Load.driverOff)) { $out.Add("- $item") }
    $out.Add('')
    if ($Load.videoConfig) {
        foreach ($line in (Get-VideoSection -Load $Load)) { $out.Add($line) }
    }
    $out.Add('The bench rejects the run when:')
    $out.Add('')
    foreach ($item in @($Load.rejectIf)) { $out.Add("- $item") }
    $out.Add('')
    $out -join "`n"
}

function Get-Readme {
    $profileData = Read-Json -Path (Join-Path $benchDir 'readme-profile.json')
    $loads = @('cs2', 'superposition') | ForEach-Object { Read-Json -Path (Join-Path $loadsDir "$_.json") }
    $pm = $loads[0].presentMon
    $sections = @($loads | ForEach-Object { Get-LoadSection -Load $_ }) -join "`n"
    $template = @'
# {TITLE}

{INTRO}

**Same procedure, not same numbers.** A game update, a driver update or a different CPU moves every number. Compare states only inside one series of runs on one machine, never against the published tables.

## What you need

- Windows 11, an elevated PowerShell (Windows PowerShell 5.1 or PowerShell 7).
- {NEEDS}
- PresentMon {PMVERSION}: {PMURL}. Verify the download: `(Get-FileHash .\PresentMon-{PMVERSION}-x64.exe).Hash` must equal `{PMSHA}`.
- A load from the section "Loads" below.
- Download the whole `bench` folder: the script dot-sources `bench-env.ps1` and the load recipes live in `loads\*.json` next to it.

## Steps

1. Make the machine quiet yourself. The bench only measures: it does not check, close or change anything. Reboot, do not open a browser, launcher, updater, VPN or monitoring tool afterwards, and wait the same fixed time after every reboot (write it down) so uptime is comparable between states.
2. Start the load from the section "Loads" and let it settle.
3. Run the bench from the elevated shell: {RUN}
4. Repeat at least 5 times per state in the order A-B-A-B (never all A then all B), with a reboot before every run.

Frame-time capture of a running load (`-Test game -Load <name>`) is not part of this version yet. The load recipes below are the single source it will read.

## What the bench touches

Nothing persistent. It reads the registry, `powercfg /qh`, WMI and performance counters, and it runs {TOUCH}. It changes no power, registry, service or boot setting and stops no process. It does not check whether your machine is quiet; that is up to you. A test in `tests\` fails if a changing command is added.

## Result record

Each result stores the bench script name and its SHA256, the OS build, display version and update revision, the active power scheme GUID with every processor setting for AC and DC, the load name and the PresentMon version, next to the measurements. Nothing else is recorded: no process or service list, no driver inventory, no user name or computer name.

## Reading the result

One run proves nothing. Take the median of the runs of each state and look at the spread (min to max). A difference counts only when it is larger than the spread inside a state. "Cannot tell" is a valid result. A maximum from a single run is never a headline.

## Sharing a result

The result files hold only the fields above and the measurements, so they can be shared as they are.

## Loads

{LOADS}
'@
    $text = $template -replace "`r`n", "`n"
    $map = [ordered]@{
        '{TITLE}'     = $profileData.title
        '{INTRO}'     = $profileData.intro
        '{NEEDS}'     = $profileData.needs
        '{PMVERSION}' = $pm.version
        '{PMURL}'     = $pm.url
        '{PMSHA}'     = $pm.sha256
        '{RUN}'       = $profileData.run
        '{TOUCH}'     = $profileData.touch
    }
    foreach ($key in $map.Keys) { $text = $text.Replace($key, [string]$map[$key]) }
    $text.Replace('{LOADS}', $sections.TrimEnd("`n"))
}

$readme = Get-Readme
if ($Write) {
    [System.IO.File]::WriteAllText($readmePath, $readme, (New-Object System.Text.UTF8Encoding($false)))
} else {
    $readme
}
