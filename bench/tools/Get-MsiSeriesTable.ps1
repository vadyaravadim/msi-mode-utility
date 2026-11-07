[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SeriesPath,
    [string]$MarkdownPath,
    [string]$SummaryPath
)

$ErrorActionPreference = 'Stop'
$driverFloorMsPerSecond = 0.5
$longGapUs = 5000
$summaryDigits = 4
$displayDigits = 2
$invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Median {
    param([Parameter(Mandatory)][double[]]$Values)
    $sorted = @($Values | Sort-Object)
    $middle = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$middle] }
    ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Get-Spread {
    param([Parameter(Mandatory)][double[]]$Values)
    $sorted = @($Values | Sort-Object)
    [pscustomobject]@{
        median = [math]::Round((Get-Median -Values $Values), $summaryDigits)
        min    = [math]::Round([double]$sorted[0], $summaryDigits)
        max    = [math]::Round([double]$sorted[-1], $summaryDigits)
        n      = $sorted.Count
    }
}

function Format-Rounded {
    param([Parameter(Mandatory)][double]$Value)
    [math]::Round($Value, $displayDigits).ToString('0.##', $invariant)
}

function Format-Spread {
    param($Spread)
    if ($null -eq $Spread) { return 'n/a' }
    '{0} [{1}-{2}]' -f (Format-Rounded $Spread.median), (Format-Rounded $Spread.min), (Format-Rounded $Spread.max)
}

function Get-Field {
    param($Object, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Where)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($current -isnot [pscustomobject] -or -not $current.PSObject.Properties[$part]) { throw "$Where has no field $Path" }
        $current = $current.$part
    }
    if ($null -eq $current) { throw "$Where field $Path is null" }
    $current
}

function Get-OptionalField {
    param($Object, [Parameter(Mandatory)][string]$Path)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($current -isnot [pscustomobject] -or -not $current.PSObject.Properties[$part]) { return $null }
        $current = $current.$part
    }
    $current
}

function Read-Json {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Where)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Where is missing: $Path" }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Read-Journal {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "journal.jsonl is missing: $Path" }
    @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-StateLabel {
    param($PlanBoot, [int]$StateIndex)
    if (@($PlanBoot.states).Count -eq 1) { return [string]$PlanBoot.label }
    "$($PlanBoot.label)-$StateIndex"
}

function Get-AcceptedResult {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Journal)
    $boots = @($Plan.boots)
    if ($boots.Count -eq 0) { throw 'plan.json lists no boots' }
    $events = @($Journal | Where-Object { $_.event -eq 'boot' -and $_.outcome -eq 'success' })
    for ($boot = 0; $boot -lt $boots.Count; $boot++) {
        $planStates = @($boots[$boot].states)
        for ($state = 0; $state -lt $planStates.Count; $state++) {
            $accepted = @()
            foreach ($entry in @($events | Where-Object { [int]$_.index -eq $boot })) {
                $accepted += @(@($entry.states) | Where-Object { [int]$_.index -eq $state -and $_.status -eq 'ok' -and $_.result })
            }
            if ($accepted.Count -ne 1) { throw "boot $boot state $state : expected exactly one accepted result in journal.jsonl, found $($accepted.Count)" }
            [pscustomobject]@{
                Boot       = $boot
                StateIndex = $state
                Label      = Get-StateLabel -PlanBoot $boots[$boot] -StateIndex $state
                PlanState  = $planStates[$state]
                WrapperFile = [string]$accepted[0].result
            }
        }
    }
}

function Read-BootData {
    param([Parameter(Mandatory)][string]$SeriesPath, [Parameter(Mandatory)]$Accepted)
    $where = "boot $($Accepted.Boot)"
    $wrapper = Read-Json -Path (Join-Path $SeriesPath $Accepted.WrapperFile) -Where "$where wrapper $($Accepted.WrapperFile)"
    if ([int](Get-Field $wrapper 'boot' $where) -ne $Accepted.Boot) { throw "$where wrapper field boot is $($wrapper.boot)" }
    if ([int](Get-Field $wrapper 'stateIndex' $where) -ne $Accepted.StateIndex) { throw "$where wrapper field stateIndex is $($wrapper.stateIndex), the journal says $($Accepted.StateIndex)" }
    $benchName = [string](Get-Field $wrapper 'bench.resultFile' $where)
    $bench = Read-Json -Path (Join-Path $SeriesPath $benchName) -Where "$where bench result $benchName"
    $stallsName = @(@(Get-OptionalField $wrapper 'bench.files') | Where-Object { $_ -is [string] -and $_ -like '*-stalls.csv' }) | Select-Object -First 1
    if (-not $stallsName) { $stallsName = [IO.Path]::GetFileNameWithoutExtension($benchName) + '-stalls.csv' }
    $stallsPath = Join-Path $SeriesPath $stallsName
    if (-not (Test-Path -LiteralPath $stallsPath -PathType Leaf)) { throw "$where stall file is missing: $stallsName" }
    $rejected = Get-OptionalField $bench 'rejected'
    if (@($rejected | Where-Object { $_ }).Count) { throw "$where bench field rejected is not empty: $(@($rejected) -join '; ')" }
    [pscustomobject]@{
        Boot       = $Accepted.Boot
        StateIndex = $Accepted.StateIndex
        Label      = $Accepted.Label
        PlanState  = $Accepted.PlanState
        Wrapper    = $wrapper
        Bench      = $bench
        BenchFile  = $benchName
        StallsFile = $stallsName
        Stalls     = @(Import-Csv -LiteralPath $stallsPath)
    }
}

function Assert-DeviceMode {
    param([Parameter(Mandatory)]$Boot)
    $where = "boot $($Boot.Boot) ($($Boot.Label))"
    $rows = @(Get-Field $Boot.Bench 'devices' $where)
    foreach ($device in @($Boot.PlanState.devices)) {
        $name = [string](Get-OptionalField $device 'deviceName')
        if (-not $name) { throw "$where plan device $($device.instanceId) has no field deviceName" }
        $found = @($rows | Where-Object { $_.Device -eq $name })
        if ($found.Count -ne 1) { throw "$where bench field devices has $($found.Count) rows named '$name', expected 1" }
        $row = $found[0]
        $wantMsi = [int]$device.msiSupported -eq 1
        $isMsi = $row.MSISupported -eq 'on' -and $row.Mode -like 'message-signaled*'
        $lineNumber = [regex]::Match([string]$row.Mode, '^line IRQ (\d+)$')
        $isLine = $row.MSISupported -eq 'off' -and $lineNumber.Success
        if ($wantMsi -and -not $isMsi) { throw "$where device '$name' field Mode: the state wants message-signaled (MSISupported 1), the bench JSON has MSISupported '$($row.MSISupported)' and Mode '$($row.Mode)'" }
        if (-not $wantMsi -and -not $isLine) { throw "$where device '$name' field Mode: the state wants a line (MSISupported 0), the bench JSON has MSISupported '$($row.MSISupported)' and Mode '$($row.Mode)'" }
        $sharedProperty = $device.PSObject.Properties['sharedWith']
        if ($sharedProperty -and $null -ne $sharedProperty.Value) {
            $expected = @(@($sharedProperty.Value) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object)
            $actual = @(([string]$row.SharedWith).Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object)
            if (($actual -join ';') -ne ($expected -join ';')) {
                throw "$where device '$name' field SharedWith is '$($actual -join '; ')', the plan says '$($expected -join '; ')'"
            }
        }
    }
}

function Assert-ToneController {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Boot)
    if (@($Plan.background) -notcontains 'tone') { return }
    $where = "boot $($Boot.Boot)"
    $planned = [string](Get-Field $Plan 'toneController' 'plan.json')
    $actual = [string](Get-Field $Boot.Bench 'background.tone.controllerInstanceId' $where)
    if ($actual -ne $planned) { throw "$where bench field background.tone.controllerInstanceId is '$actual', the plan puts the tone on '$planned'" }
}

function Get-DriverFingerprint {
    param($List)
    (@($List) | ForEach-Object { "$($_.device)|$($_.version)" } | Sort-Object) -join ';'
}

function ConvertTo-FingerprintValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    ConvertTo-Json -InputObject $Value -Depth 10 -Compress
}

$optionalBenchFingerprintField = 'metadata.benchScript.sha256', 'metadata.presentMonVersion', 'presentMon.sha256', 'load.build', 'load.videoConfig', 'frames.refreshHz'
$optionalWrapperFingerprintField = 'environment.hvciEnabled', 'environment.bios.version', 'environment.microcodeRaw', 'environment.clockFlags'

function Get-Fingerprint {
    param([Parameter(Mandatory)]$Boot)
    $where = "boot $($Boot.Boot)"
    $processor = @(Get-Field $Boot.Bench 'metadata.power.processorSettings' $where) | ForEach-Object { "$($_.guid):$($_.ac):$($_.dc)" } | Sort-Object
    $explicit = Get-OptionalField $Boot.Wrapper 'environment.powerExplicit'
    $fingerprint = [ordered]@{
        'metadata.os.build'                  = [string](Get-Field $Boot.Bench 'metadata.os.build' $where)
        'metadata.os.ubr'                    = [string](Get-Field $Boot.Bench 'metadata.os.ubr' $where)
        'metadata.power.schemeGuid'          = [string](Get-Field $Boot.Bench 'metadata.power.schemeGuid' $where)
        'metadata.power.processorSettings'   = $processor -join ';'
        'frames.presentModes'                = (@(Get-Field $Boot.Bench 'frames.presentModes' $where) | Sort-Object) -join ';'
        'environment.drivers.gpu'            = Get-DriverFingerprint (Get-Field $Boot.Wrapper 'environment.drivers.gpu' $where)
        'environment.drivers.audio'          = Get-DriverFingerprint (Get-Field $Boot.Wrapper 'environment.drivers.audio' $where)
        'environment.powerExplicit'          = if ($null -eq $explicit) { $null } else { ConvertTo-Json -InputObject $explicit -Depth 10 -Compress }
    }
    foreach ($field in $optionalBenchFingerprintField) { $fingerprint[$field] = ConvertTo-FingerprintValue (Get-OptionalField $Boot.Bench $field) }
    foreach ($field in $optionalWrapperFingerprintField) { $fingerprint[$field] = ConvertTo-FingerprintValue (Get-OptionalField $Boot.Wrapper $field) }
    $fingerprint
}

function Assert-Homogeneous {
    param([Parameter(Mandatory)][object[]]$Boots)
    $reference = Get-Fingerprint -Boot $Boots[0]
    foreach ($boot in $Boots | Select-Object -Skip 1) {
        $current = Get-Fingerprint -Boot $boot
        foreach ($field in $reference.Keys) {
            if ($current[$field] -ne $reference[$field]) {
                throw "boot $($boot.Boot) field $field differs from boot $($Boots[0].Boot): '$($current[$field])' against '$($reference[$field])'"
            }
        }
    }
}

function Get-DriverMetric {
    param([Parameter(Mandatory)]$Boot, [Parameter(Mandatory)][string]$Driver)
    $where = "boot $($Boot.Boot)"
    $seconds = [double](Get-Field $Boot.Bench 'trace.seconds' $where)
    $row = @(Get-Field $Boot.Bench 'trace.drivers' $where) | Where-Object { $_.driver -eq $Driver } | Select-Object -First 1
    if (-not $row) {
        return [pscustomobject]@{ isrPerSecond = 0.0; isrMeanUs = 0.0; isrMsPerSecond = 0.0; dpcPerSecond = 0.0; dpcMeanUs = 0.0; dpcP99Us = 0.0; dpcMsPerSecond = 0.0; cpu = $null }
    }
    $rowWhere = "$where driver $Driver"
    $isrTotal = [double](Get-Field $row 'isrTotalUs' $rowWhere)
    $dpcTotal = [double](Get-Field $row 'dpcTotalUs' $rowWhere)
    $cpus = @($row.isrPerCpu | Sort-Object -Property @{ Expression = { -[double]$_.isr } }, @{ Expression = { [int]$_.cpu } })
    [pscustomobject]@{
        isrPerSecond   = ([double]$row.isrPlain + [double]$row.isrMessage) / $seconds
        isrMeanUs      = [double]$row.isrMeanUs
        isrMsPerSecond = $isrTotal / 1000 / $seconds
        dpcPerSecond   = [double]$row.dpcCount / $seconds
        dpcMeanUs      = [double]$row.dpcMeanUs
        dpcP99Us       = [double]$row.dpcP99Us
        dpcMsPerSecond = $dpcTotal / 1000 / $seconds
        cpu            = if ($cpus.Count) { [int]$cpus[0].cpu } else { $null }
    }
}

function Get-DriverNameList {
    param([Parameter(Mandatory)][object[]]$Boots)
    $names = [System.Collections.Generic.SortedSet[string]]::new()
    foreach ($boot in $Boots) {
        foreach ($row in @(Get-Field $boot.Bench 'trace.drivers' "boot $($boot.Boot)")) { $null = $names.Add([string]$row.driver) }
    }
    @($names)
}

function Get-StateDriver {
    param([Parameter(Mandatory)][object[]]$Boots, [Parameter(Mandatory)][string]$Driver)
    $metrics = @($Boots | ForEach-Object { Get-DriverMetric -Boot $_ -Driver $Driver })
    $spread = [ordered]@{}
    foreach ($key in 'isrPerSecond', 'isrMeanUs', 'isrMsPerSecond', 'dpcPerSecond', 'dpcMeanUs', 'dpcP99Us', 'dpcMsPerSecond') {
        $spread[$key] = Get-Spread -Values @($metrics | ForEach-Object { [double]$_.$key })
    }
    $total = Get-Spread -Values @($metrics | ForEach-Object { $_.isrMsPerSecond + $_.dpcMsPerSecond })
    [pscustomobject]@{
        driver           = $Driver
        totalMsPerSecond = $total
        metrics          = [pscustomobject]$spread
        cpu              = @($metrics | Where-Object { $null -ne $_.cpu } | ForEach-Object { $_.cpu } | Sort-Object -Unique)
    }
}

function Get-StateFrame {
    param([Parameter(Mandatory)][object[]]$Boots)
    $result = [ordered]@{}
    foreach ($key in 'avgFps', 'p50Ms', 'low1PctMs', 'low01PctMs', 'gpuBusyP50Ms', 'cpuBusyP50Ms') {
        $values = @($Boots | ForEach-Object { Get-OptionalField $_.Bench "frames.$key" })
        $result[$key] = if (@($values | Where-Object { $null -eq $_ }).Count) { $null } else { Get-Spread -Values @($values | ForEach-Object { [double]$_ }) }
    }
    [pscustomobject]$result
}

function Get-StateSystemCpu {
    param([Parameter(Mandatory)][object[]]$Boots)
    $values = foreach ($boot in $Boots) {
        $record = Get-OptionalField $boot.Bench 'systemCpu'
        if ($null -eq $record) { return $null }
        $where = "boot $($boot.Boot) bench"
        $capacity = [double](Get-Field $record 'windowSeconds' "$where systemCpu") * [double](Get-Field $record 'logicalCpus' "$where systemCpu")
        if ($capacity -le 0) { throw "$where field systemCpu has no capacity: windowSeconds times logicalCpus is $capacity" }
        [double](Get-Field $record 'busySeconds' "$where systemCpu") / $capacity * 100
    }
    Get-Spread -Values @($values)
}

function Get-StateProbe {
    param([Parameter(Mandatory)][object[]]$Boots)
    $probes = foreach ($boot in $Boots) { @(Get-Field $boot.Bench probes "boot $($boot.Boot)") }
    foreach ($group in @($probes | Group-Object -Property { [int]$_.cpu } | Sort-Object -Property { [int]$_.Name })) {
        $list = @($group.Group)
        [pscustomobject]@{
            cpu        = [int]$group.Name
            stalledPct = Get-Spread -Values @($list | ForEach-Object { [double]$_.stalledPct })
            gapP50Us   = Get-Spread -Values @($list | ForEach-Object { [double]$_.gapP50Us })
            gapP999Us  = Get-Spread -Values @($list | ForEach-Object { [double]$_.gapP999Us })
        }
    }
}

function Get-StateLongGap {
    param([Parameter(Mandatory)][object[]]$Boots)
    foreach ($boot in $Boots) {
        $gaps = @($boot.Stalls | Where-Object { [double]$_.gapUs -ge $longGapUs })
        if ($gaps.Count) {
            [pscustomobject]@{
                boot = $boot.Boot
                gaps = @($gaps | ForEach-Object { [pscustomobject]@{ cpu = [int]$_.cpu; offsetMs = [double]$_.offsetMs; gapUs = [double]$_.gapUs } })
            }
        }
    }
}

function Get-StateUsb {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][object[]]$Boots)
    if (@($Plan.background) -notcontains 'usb-read') { return $null }
    $values = foreach ($boot in $Boots) {
        $where = "boot $($boot.Boot)"
        $usbError = Get-OptionalField $boot.Bench 'background.usbRead.error'
        if ($usbError) { throw "$where bench field background.usbRead.error is '$usbError'" }
        [double](Get-Field $boot.Bench 'background.usbRead.mibPerSecond' $where)
    }
    Get-Spread -Values @($values)
}

function Format-MarkdownTable {
    param([Parameter(Mandatory)][string[]]$Header, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('| ' + ($Header -join ' | ') + ' |')
    $lines.Add('| ' + (($Header | ForEach-Object { '---' }) -join ' | ') + ' |')
    foreach ($row in $Rows) { $lines.Add('| ' + (@($row) -join ' | ') + ' |') }
    $lines
}

function Get-CheckList {
    param($Plan, [object[]]$Boots)
    $hasExplicit = $null -ne (Get-OptionalField $Boots[0].Wrapper 'environment.powerExplicit')
    $reference = Get-Fingerprint -Boot $Boots[0]
    $benchRecorded = @($optionalBenchFingerprintField | Where-Object { $null -ne $reference[$_] }).Count -gt 0
    $wrapperRecorded = @($optionalWrapperFingerprintField | Where-Object { $null -ne $reference[$_] }).Count -gt 0
    $checks = @(
        @{ name = 'one accepted result per boot'; source = 'private runner journal.jsonl and plan.json'; benchJson = $false; status = 'passed' }
        @{ name = 'interrupt mode of every planned device equals its state'; source = 'bench JSON devices[].MSISupported, Mode'; benchJson = $true; status = 'passed' }
        @{ name = 'line sharing equals the plan where the plan sets it'; source = 'private runner plan.json sharedWith, bench JSON devices[].SharedWith'; benchJson = $false; status = 'passed' }
        @{ name = 'OS build and UBR identical'; source = 'bench JSON metadata.os'; benchJson = $true; status = 'passed' }
        @{ name = 'power scheme GUID and processor values identical'; source = 'bench JSON metadata.power'; benchJson = $true; status = 'passed' }
        @{ name = 'present mode identical'; source = 'bench JSON frames.presentModes'; benchJson = $true; status = 'passed' }
        @{ name = 'GPU and audio driver versions identical'; source = 'private runner wrapper environment.drivers'; benchJson = $false; status = 'passed' }
        @{ name = 'explicit power settings identical'; source = 'private runner wrapper environment.powerExplicit'; benchJson = $false; status = $(if ($hasExplicit) { 'passed' } else { 'not recorded' }) }
        @{ name = 'bench script, PresentMon, load build, video config and refresh rate identical'; source = 'bench JSON metadata.benchScript, metadata.presentMonVersion, presentMon, load, frames.refreshHz'; benchJson = $true; status = $(if ($benchRecorded) { 'passed' } else { 'not recorded' }) }
        @{ name = 'HVCI, BIOS version, microcode and clock flags identical'; source = 'private runner wrapper environment'; benchJson = $false; status = $(if ($wrapperRecorded) { 'passed' } else { 'not recorded' }) }
        @{ name = 'tone played on the planned audio controller'; source = 'bench JSON background.tone.controllerInstanceId'; benchJson = $true; status = $(if (@($Plan.background) -contains 'tone') { 'passed' } else { 'not planned' }) }
    )
    $checks | ForEach-Object { [pscustomobject]$_ }
}

function Get-FileMap {
    param([bool]$SystemCpu)
    @(
        @{ table = 'Frames'; files = 'msi-bench-bootNN-stateNN.json'; fields = $(if ($SystemCpu) { 'frames.*, systemCpu' } else { 'frames.*' }); runner = $false }
        @{ table = 'Drivers'; files = 'msi-bench-bootNN-stateNN.json'; fields = 'trace.seconds, trace.drivers[]'; runner = $false }
        @{ table = 'Probes'; files = 'msi-bench-bootNN-stateNN.json'; fields = 'probes[]'; runner = $false }
        @{ table = 'Runs with a gap of 5 ms or more'; files = 'msi-bench-bootNN-stateNN-stalls.csv'; fields = 'cpu, offsetMs, gapUs'; runner = $false }
        @{ table = 'USB reads'; files = 'msi-bench-bootNN-stateNN.json'; fields = 'background.usbRead.mibPerSecond'; runner = $false }
        @{ table = 'Testbed: OS, power, present mode, load, PresentMon'; files = 'msi-bench-bootNN-stateNN.json'; fields = 'metadata.*, frames.presentModes, load'; runner = $false }
        @{ table = 'Testbed: CPU, BIOS, drivers, explicit power settings'; files = 'bootNN-stateNN-msi.json'; fields = 'environment.*'; runner = $true }
        @{ table = 'Testbed: background services and tasks'; files = 'journal.jsonl'; fields = 'start event'; runner = $true }
        @{ table = 'State labels and device modes'; files = 'plan.json'; fields = 'boots[].label, boots[].states[].devices[]'; runner = $true }
    ) | ForEach-Object { [pscustomobject]$_ }
}

function Format-JournalValue {
    param($Value)
    if ($Value -is [array]) {
        if (-not $Value.Count) { return '0' }
        $names = foreach ($entry in $Value) {
            if ($entry -is [string]) { $entry }
            elseif ($entry.PSObject.Properties['path']) { "$($entry.path)$($entry.name)" }
            else { [string]$entry.name }
        }
        return "$($Value.Count): $($names -join ', ')"
    }
    [string]$Value
}

function Get-Testbed {
    param($Plan, $Journal, [object[]]$Boots)
    $first = $Boots[0]
    $rows = [ordered]@{}
    $os = Get-OptionalField $first.Bench 'metadata.os'
    if ($os) { $rows['Windows'] = "$($os.displayVersion) build $($os.build).$($os.ubr)" }
    $cpuName = Get-OptionalField $first.Wrapper 'environment.cpu.name'
    if ($cpuName) { $rows['CPU'] = [string]$cpuName }
    $bios = Get-OptionalField $first.Wrapper 'environment.bios'
    if ($bios) { $rows['Board and BIOS'] = "$($bios.board), BIOS $($bios.version)" }
    $rows['GPU driver'] = (@(Get-Field $first.Wrapper 'environment.drivers.gpu' 'boot 0') | ForEach-Object { "$($_.device) $($_.version)" }) -join '; '
    $rows['Audio drivers'] = (@(Get-Field $first.Wrapper 'environment.drivers.audio' 'boot 0') | ForEach-Object { "$($_.device) $($_.version)" }) -join '; '
    $rows['Power scheme'] = [string](Get-Field $first.Bench 'metadata.power.schemeGuid' 'boot 0')
    $rows['Explicit power settings recorded'] = if ($null -ne (Get-OptionalField $first.Wrapper 'environment.powerExplicit')) { 'yes' } else { 'no' }
    $rows['Present mode'] = (@(Get-Field $first.Bench 'frames.presentModes' 'boot 0')) -join '; '
    $refresh = Get-OptionalField $first.Bench 'frames.refreshHz'
    if ($null -ne $refresh) { $rows['Refresh rate'] = "$refresh Hz" }
    $load = Get-OptionalField $first.Bench 'load'
    if ($load) { $rows['Load'] = "$($load.name) $($load.build)" }
    $presentMon = Get-OptionalField $first.Bench 'metadata.presentMonVersion'
    if ($presentMon) { $rows['PresentMon'] = [string]$presentMon }
    if ($null -ne (Get-OptionalField $Plan 'settleSeconds')) { $rows['Settle before capture'] = "$($Plan.settleSeconds) s" }
    $rows['Boots'] = "$($Boots.Count)"
    $start = @($Journal | Where-Object { $_.event -eq 'start' }) | Select-Object -First 1
    if ($start) {
        foreach ($key in 'services', 'tasks', 'startup') {
            $names = $start.PSObject.Properties['disabled' + $key.Substring(0, 1).ToUpper() + $key.Substring(1)]
            $counts = $start.PSObject.Properties[$key]
            if ($names) { $rows["Disabled $key"] = Format-JournalValue $names.Value } elseif ($counts) { $rows["Disabled $key"] = Format-JournalValue $counts.Value }
        }
    }
    $rows
}

function New-SeriesReport {
    param([Parameter(Mandatory)][string]$SeriesPath)
    $plan = Read-Json -Path (Join-Path $SeriesPath 'plan.json') -Where 'plan.json'
    $journal = Read-Journal -Path (Join-Path $SeriesPath 'journal.jsonl')
    $accepted = @(Get-AcceptedResult -Plan $plan -Journal $journal)
    $boots = @($accepted | ForEach-Object { Read-BootData -SeriesPath $SeriesPath -Accepted $_ })
    foreach ($boot in $boots) {
        Assert-DeviceMode -Boot $boot
        Assert-ToneController -Plan $plan -Boot $boot
    }
    Assert-Homogeneous -Boots $boots

    $labels = @($boots | ForEach-Object { $_.Label } | Select-Object -Unique)
    $stateBoots = [ordered]@{}
    foreach ($label in $labels) { $stateBoots[$label] = @($boots | Where-Object { $_.Label -eq $label }) }

    $driverNames = Get-DriverNameList -Boots $boots
    $perState = [ordered]@{}
    foreach ($label in $labels) {
        $perState[$label] = @($driverNames | ForEach-Object { Get-StateDriver -Boots $stateBoots[$label] -Driver $_ })
    }
    $listed = @($driverNames | Where-Object {
            $name = $_
            @($perState.Values | ForEach-Object { $_ | Where-Object { $_.driver -eq $name -and $_.totalMsPerSecond.median -ge $driverFloorMsPerSecond } }).Count -gt 0
        })
    $listed = @($listed | Sort-Object -Property @{ Expression = {
                $name = $_
                -(@($perState.Values | ForEach-Object { $_ | Where-Object { $_.driver -eq $name } | ForEach-Object { $_.totalMsPerSecond.median } } | Measure-Object -Maximum).Maximum)
            } }, @{ Expression = { $_ } })

    $states = foreach ($label in $labels) {
        $group = $stateBoots[$label]
        [pscustomobject]@{
            label        = $label
            boots        = @($group | ForEach-Object { $_.Boot })
            benchFiles   = @($group | ForEach-Object { $_.BenchFile })
            frames       = Get-StateFrame -Boots $group
            systemCpuBusyPct = Get-StateSystemCpu -Boots $group
            drivers      = @($perState[$label] | Where-Object { $listed -contains $_.driver })
            probes       = @(Get-StateProbe -Boots $group)
            longGapRuns  = @(Get-StateLongGap -Boots $group)
            usbMiBPerSecond = Get-StateUsb -Plan $plan -Boots $group
        }
    }
    $states = @($states)
    $hasSystemCpu = @($states | Where-Object { $null -ne $_.systemCpuBusyPct }).Count -gt 0
    if (-not $hasSystemCpu) { $states = @($states | ForEach-Object { $_.PSObject.Properties.Remove('systemCpuBusyPct'); $_ }) }
    $testbed = Get-Testbed -Plan $plan -Journal $journal -Boots $boots
    $checks = @(Get-CheckList -Plan $plan -Boots $boots)
    $fileMap = @(Get-FileMap -SystemCpu $hasSystemCpu)

    $summary = [ordered]@{
        series    = [string]$plan.series
        constants = [ordered]@{ driverFloorMsPerSecond = $driverFloorMsPerSecond; longGapUs = $longGapUs }
        checks    = $checks
        testbed   = $testbed
        states    = $states
        fileMap   = $fileMap
    }

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('## Testbed')
    $md.Add('')
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'Item', 'Value' -Rows @($testbed.Keys | ForEach-Object { , @($_, $testbed[$_]) })))
    $md.Add('')
    $md.Add('## Checks that passed before these tables were written')
    $md.Add('')
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'Check', 'Source', 'Repeatable from the bench JSON', 'Status' -Rows @($checks | ForEach-Object { , @($_.name, $_.source, $(if ($_.benchJson) { 'yes' } else { 'no, needs the private runner' }), $_.status) })))
    $md.Add('')
    $md.Add('## Frames')
    $md.Add('')
    $md.Add('Median [min-max] over the boots of each state. 1% low and 0.1% low are the 99th and 99.9th percentile frame time.')
    $md.Add('')
    $frameHeader = @('State', 'Boots', 'Avg FPS', 'p50 (ms)', '1% low (ms)', '0.1% low (ms)', 'GPU busy p50 (ms)', 'CPU busy p50 (ms)')
    if ($hasSystemCpu) { $frameHeader += 'System CPU busy (% of the machine)' }
    $frameRows = foreach ($state in $states) {
        $cells = @($state.label, $state.boots.Count, (Format-Spread $state.frames.avgFps), (Format-Spread $state.frames.p50Ms), (Format-Spread $state.frames.low1PctMs), (Format-Spread $state.frames.low01PctMs), (Format-Spread $state.frames.gpuBusyP50Ms), (Format-Spread $state.frames.cpuBusyP50Ms))
        if ($hasSystemCpu) { $cells += Format-Spread $state.systemCpuBusyPct }
        , $cells
    }
    $md.AddRange([string[]]@(Format-MarkdownTable -Header $frameHeader -Rows @($frameRows)))
    $md.Add('')
    $md.Add('## Drivers')
    $md.Add('')
    $md.Add(('Every driver whose median ISR plus DPC time is at least {0} ms/s in any state. Median [min-max] over the boots of each state.' -f (Format-Rounded $driverFloorMsPerSecond)))
    $md.Add('')
    $driverRows = foreach ($name in $listed) {
        foreach ($state in $states) {
            $row = $state.drivers | Where-Object { $_.driver -eq $name }
            , @($name, $state.label, (Format-Spread $row.metrics.isrPerSecond), (Format-Spread $row.metrics.isrMeanUs), (Format-Spread $row.metrics.isrMsPerSecond), (Format-Spread $row.metrics.dpcPerSecond), (Format-Spread $row.metrics.dpcMeanUs), (Format-Spread $row.metrics.dpcP99Us), (Format-Spread $row.metrics.dpcMsPerSecond), $(if ($row.cpu.Count) { $row.cpu -join ', ' } else { '-' }))
        }
    }
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'Driver', 'State', 'ISR/s', 'ISR mean (us)', 'ISR (ms/s)', 'DPC/s', 'DPC mean (us)', 'DPC p99 (us)', 'DPC (ms/s)', 'CPU of the ISR' -Rows @($driverRows)))
    $md.Add('')
    $md.Add('## Probes')
    $md.Add('')
    $probeRows = foreach ($state in $states) {
        foreach ($probe in $state.probes) {
            , @($state.label, $probe.cpu, (Format-Spread $probe.stalledPct), (Format-Spread $probe.gapP50Us), (Format-Spread $probe.gapP999Us))
        }
    }
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'State', 'Probe CPU', 'Stalled (%)', 'Gap p50 (us)', 'Gap p99.9 (us)' -Rows @($probeRows)))
    $md.Add('')
    $md.Add(('## Runs with a gap of {0} ms or more' -f (Format-Rounded ($longGapUs / 1000))))
    $md.Add('')
    $gapRows = foreach ($state in $states) {
        $detail = ($state.longGapRuns | ForEach-Object {
                $run = $_
                'boot {0}: {1}' -f $run.boot, (($run.gaps | ForEach-Object { 'cpu {0} at {1} ms ({2} us)' -f $_.cpu, (Format-Rounded $_.offsetMs), (Format-Rounded $_.gapUs) }) -join ', ')
            }) -join '; '
        , @($state.label, "$($state.longGapRuns.Count) of $($state.boots.Count)", $(if ($detail) { $detail } else { '-' }))
    }
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'State', 'Runs with such a gap', 'Offsets from the start of the stall timeline' -Rows @($gapRows)))
    $md.Add('')
    if (@($plan.background) -contains 'usb-read') {
        $md.Add('## USB reads')
        $md.Add('')
        $md.AddRange([string[]]@(Format-MarkdownTable -Header 'State', 'MiB/s' -Rows @($states | ForEach-Object { , @($_.label, (Format-Spread $_.usbMiBPerSecond)) })))
        $md.Add('')
    }
    $md.Add('## Table to file map')
    $md.Add('')
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'Table', 'File', 'Fields', 'Needs the private runner' -Rows @($fileMap | ForEach-Object { , @($_.table, $_.files, $_.fields, $(if ($_.runner) { 'yes' } else { 'no' })) })))
    $md.Add('')
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'State', 'Boots', 'Bench JSON files' -Rows @($states | ForEach-Object { , @($_.label, ($_.boots -join ', '), ($_.benchFiles -join ', ')) })))

    [pscustomobject]@{ Markdown = ($md -join "`n") + "`n"; Summary = [pscustomobject]$summary }
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

if ($MyInvocation.InvocationName -ne '.') {
    $report = New-SeriesReport -SeriesPath $SeriesPath
    if ($MarkdownPath) { Write-TextFile -Path $MarkdownPath -Text $report.Markdown } else { $report.Markdown }
    if ($SummaryPath) { Write-TextFile -Path $SummaryPath -Text ((ConvertTo-Json -InputObject $report.Summary -Depth 12) + "`n") }
}
