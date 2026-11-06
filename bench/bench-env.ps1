function Get-BenchConfig {
    @{
        Limits = @{
            RefreshTolerance = 0.03
            RefreshClusterShare = 0.8
            Digits = 3
        }
        ProcessorSubgroup = 'SUB_PROCESSOR'
        PresentMonSession = 'rigpolice-bench'
        PresentMonColumns = @('MsBetweenPresents', 'MsGPUBusy', 'MsCPUBusy', 'SyncInterval', 'PresentMode')
        CappedMessage = 'this load cannot show a difference'
        PresentMonCircularBufferSize = 16384
        PresentMonOverflowPattern = '(\d+) overflowed present events'
    }
}

function Get-Percentile {
    param([double[]]$Sorted, [double]$Q, [int]$Digits = (Get-BenchConfig).Limits.Digits)
    if ($Sorted.Count -eq 0) { return 0 }
    [math]::Round($Sorted[[math]::Min($Sorted.Count - 1, [int][math]::Floor($Sorted.Count * $Q))], $Digits)
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
}

function Read-ValveKeyValues {
    param([string]$Path)
    $values = [ordered]@{}
    foreach ($line in Get-Content -Path $Path -Encoding UTF8) {
        if ($line -match '^\s*"([^"]+)"\s+"([^"]*)"\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    $values
}

function ConvertFrom-PowercfgQuery {
    param([string]$Text)
    $guidPattern = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    $headers = 0
    $current = $null
    $expectAlias = $false
    $done = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match "($guidPattern)(?:\s+\((.*)\))?") {
            $headers++
            if ($headers -le 2) { continue }
            if ($current) { $done.Add($current) }
            $current = @{ guid = $Matches[1].ToLower(); name = $Matches[2]; alias = $null; hex = @() }
            $expectAlias = $true
            continue
        }
        if (-not $current) { continue }
        if ($expectAlias) {
            $expectAlias = $false
            if ($line -match ':\s*(\S+)\s*$') { $current.alias = $Matches[1] }
        }
        $current.hex += @([regex]::Matches($line, '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
    }
    if ($current) { $done.Add($current) }
    foreach ($item in $done) {
        if ($item.hex.Count -lt 2) { continue }
        [pscustomobject]@{ guid = $item.guid; alias = $item.alias; name = $item.name; ac = $item.hex[-2]; dc = $item.hex[-1] }
    }
}

function Get-PowerState {
    $cfg = Get-BenchConfig
    $active = (& powercfg /getactivescheme 2>&1 | ForEach-Object { "$_" }) -join ' '
    $guid = if ($active -match '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}') { $Matches[0].ToLower() } else { $null }
    $query = (& powercfg /qh SCHEME_CURRENT $cfg.ProcessorSubgroup 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $overlayKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    [pscustomobject]@{
        schemeGuid = $guid
        overlayAc = Get-RegistryValue $overlayKey 'ActiveOverlayAcPowerScheme'
        overlayDc = Get-RegistryValue $overlayKey 'ActiveOverlayDcPowerScheme'
        processorSettings = @(ConvertFrom-PowercfgQuery -Text $query)
    }
}

function Get-BenchMetadata {
    param([Parameter(Mandatory)][string]$BenchScript, [string]$Load, [string]$PresentMonVersion)
    $nt = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        benchScript = [pscustomobject]@{
            name = Split-Path -Leaf $BenchScript
            sha256 = (Get-FileHash -Path $BenchScript -Algorithm SHA256).Hash.ToLower()
        }
        os = [pscustomobject]@{
            build = Get-RegistryValue $nt 'CurrentBuild'
            displayVersion = Get-RegistryValue $nt 'DisplayVersion'
            ubr = Get-RegistryValue $nt 'UBR'
        }
        power = Get-PowerState
        load = if ($Load) { $Load } else { 'none' }
        presentMonVersion = if ($PresentMonVersion) { $PresentMonVersion } else { $null }
        qpcFrequency = [System.Diagnostics.Stopwatch]::Frequency
    }
}

function Write-BenchResult {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Path)
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-MonitorRefreshHz {
    [double](Get-CimInstance Win32_VideoController | ForEach-Object { $_.CurrentRefreshRate } | Measure-Object -Maximum).Maximum
}

function Invoke-PresentMonCapture {
    param(
        [Parameter(Mandatory)][string]$PresentMonPath,
        [Parameter(Mandatory)][string]$ProcessName,
        [Parameter(Mandatory)][string]$OutputFile,
        [int]$Seconds = 60,
        [string]$ExpectedSha256
    )
    $cfg = Get-BenchConfig
    $sha = (Get-FileHash -Path $PresentMonPath -Algorithm SHA256).Hash.ToLower()
    if ($ExpectedSha256 -and $sha -ne $ExpectedSha256.ToLower()) {
        throw "PresentMon at $PresentMonPath has SHA256 $sha, expected $ExpectedSha256. Use the pinned release."
    }
    $captureArgs = @('--process_name', $ProcessName, '--output_file', $OutputFile, '--timed', $Seconds, '--terminate_after_timed',
        '--stop_existing_session', '--session_name', $cfg.PresentMonSession, '--no_console_stats',
        '--set_circular_buffer_size', $cfg.PresentMonCircularBufferSize)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& $PresentMonPath @captureArgs 2>&1) } finally { $ErrorActionPreference = $previousPreference }
    $overflowed = 0
    foreach ($line in @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })) {
        Write-Warning $line
        foreach ($m in [regex]::Matches($line, $cfg.PresentMonOverflowPattern)) { $overflowed += [int]$m.Groups[1].Value }
    }
    if ($LASTEXITCODE -ne 0) { throw "PresentMon exited with code $LASTEXITCODE" }
    if (-not (Test-Path -Path $OutputFile)) { throw "PresentMon wrote no CSV for $ProcessName (is the process running and the shell elevated?)" }
    [pscustomobject]@{
        presentMonSha256 = $sha
        csv = $OutputFile
        overflowedPresents = $overflowed
    }
}

function ConvertTo-FiniteDouble {
    param($Value)
    $parsed = 0.0
    if ([double]::TryParse("$Value", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { $parsed }
}

function Get-FrameStats {
    param([Parameter(Mandatory, ValueFromPipeline)]$Row, [double]$RefreshHz = (Get-MonitorRefreshHz))
    begin { $rows = New-Object System.Collections.Generic.List[object] }
    process { $rows.Add($Row) }
    end {
        $cfg = Get-BenchConfig
        if (-not $rows.Count) { throw 'no frames to analyse' }
        $missing = @($cfg.PresentMonColumns | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ })
        if ($missing.Count) { throw "PresentMon CSV lacks column(s): $($missing -join ', '). PresentMon 2.x is required." }
        $ft = [double[]]@($rows | ForEach-Object { ConvertTo-FiniteDouble $_.MsBetweenPresents } | Sort-Object)
        $cpuBusy = [double[]]@($rows | ForEach-Object { ConvertTo-FiniteDouble $_.MsCPUBusy } | Sort-Object)
        $gpuBusy = [double[]]@($rows | ForEach-Object { ConvertTo-FiniteDouble $_.MsGPUBusy } | Sort-Object)
        $sync = @($rows | ForEach-Object { $_.SyncInterval } | Select-Object -Unique)
        $modes = @($rows | ForEach-Object { $_.PresentMode } | Select-Object -Unique)
        $reasons = New-Object System.Collections.Generic.List[string]
        if (@($sync | Where-Object { (ConvertTo-FiniteDouble $_) -gt 0 }).Count) { $reasons.Add('SyncInterval above 0 (vsync)') }
        if ($RefreshHz -gt 0) {
            $period = 1000.0 / $RefreshHz
            $near = @($ft | Where-Object { [math]::Abs($_ - $period) -le $period * $cfg.Limits.RefreshTolerance }).Count
            if ($near / $ft.Count -ge $cfg.Limits.RefreshClusterShare) { $reasons.Add(("frame times cluster at the {0:N1} Hz refresh period" -f $RefreshHz)) }
        }
        $avg = ($ft | Measure-Object -Average).Average
        [pscustomobject]@{
            frames = $ft.Count
            avgFps = [math]::Round(1000.0 / $avg, 1)
            p50Ms = Get-Percentile $ft 0.50
            low1PctMs = Get-Percentile $ft 0.99
            low01PctMs = Get-Percentile $ft 0.999
            cpuBusyP50Ms = Get-Percentile $cpuBusy 0.50
            gpuBusyP50Ms = Get-Percentile $gpuBusy 0.50
            syncIntervals = $sync
            presentModes = $modes
            refreshHz = $RefreshHz
            capped = ($reasons.Count -gt 0)
            cappedReason = ($reasons -join '; ')
        }
    }
}

function Assert-LoadCanShowDifference {
    param([Parameter(Mandatory)]$Stats)
    if ($Stats.capped) { throw "Run rejected: $((Get-BenchConfig).CappedMessage) ($($Stats.cappedReason))." }
}

function Find-LogMarker {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Pattern, [int]$From = 0)
    if ($From -gt $Text.Length) { return -1 }
    $Text.IndexOf($Pattern, $From, [System.StringComparison]::Ordinal)
}

function Get-ExtraLaunchFlag {
    param([string]$CommandLine, [string[]]$Expected)
    $tokens = @([regex]::Matches("$CommandLine", '"[^"]*"|\S+') | ForEach-Object { $_.Value } | Select-Object -Skip 1)
    @($tokens | Where-Object { $_ -match '^[-+][A-Za-z_][A-Za-z0-9_]*$' -and $Expected -notcontains $_ } | Select-Object -Unique)
}

function Get-LoadRecipe {
    param([Parameter(Mandatory)][string]$Name)
    $dir = Join-Path $PSScriptRoot 'loads'
    $path = Join-Path $dir "$Name.json"
    if (-not (Test-Path -Path $path)) { throw "No load recipe $path. Pick one of: $((Get-ChildItem -Path $dir -Filter *.json | ForEach-Object { $_.BaseName }) -join ', ')." }
    $recipe = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($recipe.workshop -and ($recipe.timings.loadPauseSeconds + $recipe.timings.captureSeconds) -gt $recipe.workshop.routeSeconds) {
        throw "$Name.json: load pause plus capture is longer than the $($recipe.workshop.routeSeconds) s route."
    }
    $recipe
}

function Get-RecipeProcessArg {
    param([Parameter(Mandatory)]$Recipe)
    $all = @($Recipe.launchArgs)
    if ($Recipe.game) { return @($all | Select-Object -Skip 2) }
    $all
}

function Read-SharedText {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { (New-Object System.IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
}

function Wait-LoadStart {
    param([Parameter(Mandatory)]$Recipe)
    Write-Host "Waiting for $($Recipe.presentMonProcess) ..."
    $proc = $null
    while (-not $proc) {
        $proc = Get-Process -Name $Recipe.process -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $Recipe.startMarker) { return $proc }
    $logPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $proc.Path) $Recipe.startMarker.log))
    Write-Host "Found $($Recipe.presentMonProcess). Waiting for '$($Recipe.startMarker.pattern)' in $(Split-Path -Leaf $logPath) ..."
    $from = 0
    if (Test-Path -Path $logPath) { $from = (Read-SharedText -Path $logPath).Length }
    $seenLength = $from
    while ($true) {
        if ($proc.HasExited) { throw "$($Recipe.presentMonProcess) exited before the route started." }
        if (Test-Path -Path $logPath) {
            $text = Read-SharedText -Path $logPath
            if ($text.Length -lt $seenLength) { $from = 0 }
            $seenLength = $text.Length
            if ((Find-LogMarker -Text $text -Pattern $Recipe.startMarker.pattern -From $from) -ge 0) { return $proc }
        }
        Start-Sleep -Milliseconds 500
    }
}

function Get-VideoConfigMismatch {
    param([Parameter(Mandatory)][string]$Expected, [Parameter(Mandatory)][string]$Installed, [Parameter(Mandatory)][string]$KeyPrefix)
    $want = Read-ValveKeyValues -Path $Expected
    $have = Read-ValveKeyValues -Path $Installed
    @($want.Keys | Where-Object { $_.StartsWith($KeyPrefix) -and (-not $have.Contains($_) -or $have[$_] -ne $want[$_]) })
}

function Find-InstalledVideoConfig {
    param([Parameter(Mandatory)]$Recipe)
    $steam = Get-RegistryValue 'HKCU:\Software\Valve\Steam' 'SteamPath'
    if (-not $steam) { return $null }
    $userdata = Join-Path $steam 'userdata'
    if (-not (Test-Path -Path $userdata)) { return $null }
    Get-ChildItem -Path $userdata -Directory |
        ForEach-Object { Join-Path $_.FullName "$($Recipe.game.steamAppId)\local\cfg\$($Recipe.videoConfig.file)" } |
        Where-Object { Test-Path -Path $_ } | ForEach-Object { Get-Item -Path $_ } |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }
}

function Get-VideoConfigCheck {
    param([Parameter(Mandatory)]$Recipe)
    if (-not $Recipe.videoConfig) { return $null }
    $installed = Find-InstalledVideoConfig -Recipe $Recipe
    if (-not $installed) { return [pscustomobject]@{ found = $false; mismatchedKeys = @() } }
    $expected = Join-Path (Join-Path $PSScriptRoot 'loads') $Recipe.videoConfig.file
    [pscustomobject]@{ found = $true; mismatchedKeys = @(Get-VideoConfigMismatch -Expected $expected -Installed $installed -KeyPrefix $Recipe.videoConfig.compareKeyPrefix) }
}

function Get-GameRejection {
    param([Parameter(Mandatory)]$Stats, [Parameter(Mandatory)]$Capture, $Video, [Parameter(Mandatory)]$Recipe)
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($Stats.capped) { $reasons.Add("$((Get-BenchConfig).CappedMessage) ($($Stats.cappedReason))") }
    if ($Capture.overflowedPresents -gt 0) { $reasons.Add("PresentMon lost $($Capture.overflowedPresents) frames (present event buffer overflow)") }
    if ($Video -and -not $Video.found) { $reasons.Add("no installed $($Recipe.videoConfig.file) found under the Steam userdata folder") }
    if ($Video -and $Video.mismatchedKeys.Count) { $reasons.Add("the installed $($Recipe.videoConfig.file) differs from bench\loads\$($Recipe.videoConfig.file) in $($Video.mismatchedKeys -join ', ')") }
    if ($reasons.Count) { $reasons -join '; ' } else { $null }
}

function Get-LoadBuild {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][string]$ExePath)
    if ($Recipe.build) {
        $file = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $ExePath) $Recipe.build.file))
        $line = Get-Content -Path $file -ErrorAction SilentlyContinue | Where-Object { $_ -match "^$([regex]::Escape($Recipe.build.key))=" } | Select-Object -First 1
        if ($line) { return ($line -split '=', 2)[1].Trim() }
        return $null
    }
    (Get-Item -Path $ExePath).VersionInfo.ProductVersion
}

function Wait-LoadReady {
    param([Parameter(Mandatory)]$Recipe)
    $proc = Wait-LoadStart -Recipe $Recipe
    Write-Host "Load started. Waiting $($Recipe.timings.loadPauseSeconds) s, then capturing $($Recipe.timings.captureSeconds) s. Do not touch the PC."
    Start-Sleep -Seconds $Recipe.timings.loadPauseSeconds
    $proc
}

function Get-LoadRecord {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Process)
    $cmd = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($Process.Id)").CommandLine
    [pscustomobject]@{
        name = $Name
        build = Get-LoadBuild -Recipe $Recipe -ExePath $Process.Path
        videoConfig = Get-VideoConfigCheck -Recipe $Recipe
        extraLaunchFlags = @(Get-ExtraLaunchFlag -CommandLine $cmd -Expected (Get-RecipeProcessArg -Recipe $Recipe))
    }
}

function Format-Invariant {
    param([double]$Value)
    $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-CsvFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Header, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)
    $text = (@($Header) + $Lines) -join "`n"
    [System.IO.File]::WriteAllText($Path, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
