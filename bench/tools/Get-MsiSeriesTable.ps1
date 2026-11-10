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
$stallFileMinUs = 1000
$referenceState = 'stock'
$alpha = 0.05d
$confidence = 0.9d
$fpsLoadLimitPct = 1d
$pValueDigits = 6
$pDisplayDigits = 3
$marginRules = [ordered]@{
    superposition = [ordered]@{
        stalledPct        = [ordered]@{ absolute = 0.3d }
        gapP99Us          = [ordered]@{ shareOfStockMedian = 0.1d }
        low1PctMs         = [ordered]@{ absolute = 0.3d }
        isrDpcMsPerSecond = [ordered]@{ absolute = 0.5d }
    }
    cs2           = [ordered]@{
        stalledPct        = [ordered]@{ absolute = 0.3d }
        gapP99Us          = [ordered]@{ shareOfStockMedian = 0.1d }
        low1PctMs         = [ordered]@{ shareOfStockMedian = 0.033d }
        isrDpcMsPerSecond = [ordered]@{ absolute = 0.5d }
    }
}
$changedDrivers = [ordered]@{
    'audio-msi'      = @('HDAudBus.sys')
    'mobo-audio-msi' = @('HDAudBus.sys')
    'gpu-audio-msi'  = @('HDAudBus.sys')
    'gpu-line'       = @('dxgkrnl.sys', 'amdkmdag.sys')
    'usb-line'       = @('Wdf01000.sys')
}
$testMetrics = @(
    [ordered]@{ key = 'dxgkrnlStalledPct'; source = 'probe'; driver = 'dxgkrnl.sys'; field = 'stalledPct'; margin = 'stalledPct'; cannotShowOn = $null; label = 'Stalled (%), dxgkrnl.sys core' }
    [ordered]@{ key = 'dxgkrnlGapP99Us'; source = 'probe'; driver = 'dxgkrnl.sys'; field = 'gapP99Us'; margin = 'gapP99Us'; cannotShowOn = $null; label = 'Gap p99 (us), dxgkrnl.sys core' }
    [ordered]@{ key = 'wdf01000StalledPct'; source = 'probe'; driver = 'Wdf01000.sys'; field = 'stalledPct'; margin = 'stalledPct'; cannotShowOn = $null; label = 'Stalled (%), Wdf01000.sys core' }
    [ordered]@{ key = 'wdf01000GapP99Us'; source = 'probe'; driver = 'Wdf01000.sys'; field = 'gapP99Us'; margin = 'gapP99Us'; cannotShowOn = $null; label = 'Gap p99 (us), Wdf01000.sys core' }
    [ordered]@{ key = 'low1PctMs'; source = 'frames'; driver = $null; field = 'low1PctMs'; margin = 'low1PctMs'; cannotShowOn = 'gpu'; label = '1% low (ms)' }
    [ordered]@{ key = 'changedDriverMsPerSecond'; source = 'driver'; driver = $null; field = $null; margin = 'isrDpcMsPerSecond'; cannotShowOn = $null; label = 'ISR+DPC of the changed driver (ms/s)' }
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'bench-env.ps1')

function Get-Median {
    param([Parameter(Mandatory)][decimal[]]$Values)
    $sorted = [decimal[]]$Values.Clone()
    [Array]::Sort($sorted)
    $middle = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$middle] }
    ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function Get-Spread {
    param([Parameter(Mandatory)][double[]]$Values)
    $sorted = @($Values | Sort-Object)
    [pscustomobject]@{
        median = [math]::Round([double](Get-Median -Values $Values), $summaryDigits)
        min    = [math]::Round([double]$sorted[0], $summaryDigits)
        max    = [math]::Round([double]$sorted[-1], $summaryDigits)
        n      = $sorted.Count
    }
}

function Format-Rounded {
    param([Parameter(Mandatory)][double]$Value)
    $rounded = [math]::Round($Value, $displayDigits)
    if ($rounded -eq 0) { $rounded = 0.0 }
    $rounded.ToString('0.##', $invariant)
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
    if (@(Get-OptionalField $Boot.Wrapper 'environment.drivers.audio' | Where-Object { $null -ne $_ }).Count -eq 0) { throw "$where wrapper field environment.drivers.audio is empty, the plan plays the tone" }
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
    $secondsRecorded = Get-Field $Boot.Bench 'trace.seconds' $where
    $seconds = [double]$secondsRecorded
    $row = @(Get-Field $Boot.Bench 'trace.drivers' $where) | Where-Object { $_.driver -eq $Driver } | Select-Object -First 1
    if (-not $row) {
        return [pscustomobject]@{ isrPerSecond = 0.0; isrMeanUs = 0.0; isrMsPerSecond = 0.0; dpcPerSecond = 0.0; dpcMeanUs = 0.0; dpcP99Us = 0.0; dpcMsPerSecond = 0.0; isrDpcMsPerSecond = 0d; cpu = $null }
    }
    $rowWhere = "$where driver $Driver"
    $isrRecorded = Get-Field $row 'isrTotalUs' $rowWhere
    $dpcRecorded = Get-Field $row 'dpcTotalUs' $rowWhere
    $isrTotal = [double]$isrRecorded
    $dpcTotal = [double]$dpcRecorded
    $cpus = @($row.isrPerCpu | Sort-Object -Property @{ Expression = { -[double]$_.isr } }, @{ Expression = { [int]$_.cpu } })
    [pscustomobject]@{
        isrPerSecond   = ([double]$row.isrPlain + [double]$row.isrMessage) / $seconds
        isrMeanUs      = [double]$row.isrMeanUs
        isrMsPerSecond = $isrTotal / 1000 / $seconds
        dpcPerSecond   = [double]$row.dpcCount / $seconds
        dpcMeanUs      = [double]$row.dpcMeanUs
        dpcP99Us       = [double]$row.dpcP99Us
        dpcMsPerSecond = $dpcTotal / 1000 / $seconds
        isrDpcMsPerSecond = ((ConvertTo-WrittenDecimal $isrRecorded) + (ConvertTo-WrittenDecimal $dpcRecorded)) / 1000 / (ConvertTo-WrittenDecimal $secondsRecorded)
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
    $probes = foreach ($boot in $Boots) {
        foreach ($probe in @(Get-Field $boot.Bench probes "boot $($boot.Boot)")) { [pscustomobject]@{ Probe = $probe; Stalls = $boot.Stalls } }
    }
    foreach ($group in @($probes | Group-Object -Property { [int]$_.Probe.cpu } | Sort-Object -Property { [int]$_.Name })) {
        $cpu = [int]$group.Name
        $list = @($group.Group | ForEach-Object { $_.Probe })
        $gapP99 = @($list | ForEach-Object { Get-OptionalField $_ 'gapP99Us' })
        [pscustomobject]@{
            cpu        = $cpu
            devices    = @($list | ForEach-Object { @(Get-OptionalField $_ 'devices') } | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            stalledPct = Get-Spread -Values @($list | ForEach-Object { [double]$_.stalledPct })
            gapP50Us   = Get-Spread -Values @($list | ForEach-Object { [double]$_.gapP50Us })
            gapP99Us   = if (@($gapP99 | Where-Object { $null -eq $_ }).Count) { $null } else { Get-Spread -Values @($gapP99 | ForEach-Object { [double]$_ }) }
            gapP999Us  = Get-Spread -Values @($list | ForEach-Object { [double]$_.gapP999Us })
            stallCount = Get-Spread -Values @($group.Group | ForEach-Object { @($_.Stalls | Where-Object { [int]$_.cpu -eq $cpu }).Count })
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

function Get-DoubledMidRank {
    param([Parameter(Mandatory)][decimal[]]$Values)
    foreach ($value in $Values) {
        $below = 0
        $equal = 0
        foreach ($other in $Values) {
            if ($other -lt $value) { $below++ } elseif ($other -eq $value) { $equal++ }
        }
        2 * $below + $equal + 1
    }
}

function Get-RankSumCount {
    param([Parameter(Mandatory)][int[]]$Ranks, [Parameter(Mandatory)][int]$Take)
    $total = 0
    foreach ($rank in $Ranks) { $total += $rank }
    $count = New-Object 'object[]' ($Take + 1)
    for ($j = 0; $j -le $Take; $j++) { $count[$j] = New-Object 'decimal[]' ($total + 1) }
    $count[0][0] = 1d
    $seen = 0
    $reach = 0
    foreach ($rank in $Ranks) {
        $seen++
        $reach += $rank
        for ($j = [math]::Min($seen, $Take); $j -ge 1; $j--) {
            $to = $count[$j]
            $from = $count[$j - 1]
            for ($sum = $reach; $sum -ge $rank; $sum--) {
                $add = $from[$sum - $rank]
                if ($add -ne 0) { $to[$sum] += $add }
            }
        }
    }
    , $count[$Take]
}

function Get-RankSumTest {
    param([Parameter(Mandatory)][decimal[]]$Stock, [Parameter(Mandatory)][decimal[]]$State)
    $all = [decimal[]]@($Stock + $State)
    $ranks = [int[]]@(Get-DoubledMidRank -Values $all)
    $size = $all.Count
    $take = $State.Count
    $rankSum = 0
    for ($i = $Stock.Count; $i -lt $size; $i++) { $rankSum += $ranks[$i] }
    $expected = $take * ($size + 1)
    $observed = [math]::Abs($rankSum - $expected)
    $count = Get-RankSumCount -Ranks $ranks -Take $take
    $extreme = 0d
    $permutations = 0d
    for ($sum = 0; $sum -lt $count.Count; $sum++) {
        if ($count[$sum] -eq 0) { continue }
        $permutations += $count[$sum]
        if ([math]::Abs($sum - $expected) -ge $observed) { $extreme += $count[$sum] }
    }
    [pscustomobject]@{
        rankSum      = $rankSum
        expected     = $expected
        extreme      = $extreme
        permutations = $permutations
        direction    = [math]::Sign($rankSum - $expected)
    }
}

function Get-ShiftEstimate {
    param([Parameter(Mandatory)][decimal[]]$Stock, [Parameter(Mandatory)][decimal[]]$State)
    $differences = [decimal[]]@(foreach ($y in $State) { foreach ($x in $Stock) { $y - $x } })
    [Array]::Sort($differences)
    $result = [ordered]@{ shift = Get-Median -Values $differences; ciLow = $null; ciHigh = $null; ciConfidence = $null }
    $take = $State.Count
    $size = $Stock.Count + $take
    $noTies = Get-RankSumCount -Ranks ([int[]]@(1..$size | ForEach-Object { 2 * $_ })) -Take $take
    $permutations = 0d
    foreach ($value in $noTies) { $permutations += $value }
    $tail = (1d - $confidence) / 2 * $permutations
    $lowest = $take * ($take + 1)
    $cumulative = 0d
    $below = 0d
    $k = 0
    for ($u = 0; $lowest + 2 * $u -lt $noTies.Count; $u++) {
        $cumulative += $noTies[$lowest + 2 * $u]
        if ($cumulative -gt $tail) { break }
        $below = $cumulative
        $k = $u + 1
    }
    if ($k -ge 1) {
        $result.ciLow = $differences[$k - 1]
        $result.ciHigh = $differences[$differences.Count - $k]
        $result.ciConfidence = 1d - 2 * $below / $permutations
    }
    [pscustomobject]$result
}

function Get-HolmAdjusted {
    param([Parameter(Mandatory)][decimal[]]$Extreme, [Parameter(Mandatory)][decimal[]]$Permutations)
    $size = $Extreme.Count
    $order = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $size; $i++) {
        $at = $order.Count
        while ($at -gt 0 -and $Extreme[$i] * $Permutations[$order[$at - 1]] -lt $Extreme[$order[$at - 1]] * $Permutations[$i]) { $at-- }
        $order.Insert($at, $i)
    }
    $adjusted = New-Object 'object[]' $size
    $numerator = 0d
    $denominator = 1d
    for ($rank = 0; $rank -lt $size; $rank++) {
        $i = $order[$rank]
        $stepNumerator = ($size - $rank) * $Extreme[$i]
        if ($stepNumerator * $denominator -gt $numerator * $Permutations[$i]) {
            $numerator = $stepNumerator
            $denominator = $Permutations[$i]
        }
        if ($numerator -gt $denominator) {
            $numerator = 1d
            $denominator = 1d
        }
        $adjusted[$i] = [pscustomobject]@{
            numerator   = $numerator
            denominator = $denominator
            pHolm       = ConvertTo-OutputNumber ($numerator / $denominator) $pValueDigits
            significant = $numerator -lt $alpha * $denominator
        }
    }
    $adjusted
}

function Get-Verdict {
    param([bool]$Significant, [int]$Direction, $CiLow, $CiHigh, $Margin, [switch]$CannotShow)
    if ($Significant -and $Direction -gt 0) { return 'hurt' }
    if ($Significant -and $Direction -lt 0) { return 'helped' }
    if ($CannotShow) { return 'cannot show' }
    if ($null -ne $CiLow -and $null -ne $CiHigh -and $null -ne $Margin -and -[decimal]$Margin -lt [decimal]$CiLow -and [decimal]$CiHigh -lt [decimal]$Margin) { return 'no difference' }
    'cannot tell'
}

function Get-MetricMargin {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Rule, [Parameter(Mandatory)][decimal]$StockMedian)
    if ($Rule.Contains('absolute')) { return [decimal]$Rule.absolute }
    [decimal]$Rule.shareOfStockMedian * $StockMedian
}

function Get-PercentOf {
    param([Parameter(Mandatory)][decimal]$Value, [Parameter(Mandatory)][decimal]$Reference)
    if ($Reference -eq 0) { return $null }
    $Value / $Reference * 100
}

function ConvertTo-OutputNumber {
    param($Value, [int]$Digits = $summaryDigits)
    if ($null -eq $Value) { return $null }
    $rounded = [math]::Round([decimal]$Value, $Digits)
    if ($rounded -eq 0) { return 0.0 }
    [double]$rounded
}

function Get-LoadCheck {
    param([Parameter(Mandatory)][decimal[]]$Stock, [Parameter(Mandatory)][decimal[]]$State)
    $stockMedian = Get-Median -Values $Stock
    $stateMedian = Get-Median -Values $State
    [pscustomobject]@{
        stockMedian   = $stockMedian
        stateMedian   = $stateMedian
        differencePct = Get-PercentOf -Value ($stateMedian - $stockMedian) -Reference $stockMedian
        differs       = [math]::Abs($stateMedian - $stockMedian) * 100 -gt $fpsLoadLimitPct * $stockMedian
    }
}

function Format-PValue {
    param([Parameter(Mandatory)][decimal]$Value)
    $floor = 1d / [decimal][math]::Pow(10, $pDisplayDigits)
    if ($Value -lt $floor) { return '< ' + $floor.ToString($invariant) }
    $digits = $pDisplayDigits
    $shown = [math]::Round($Value, $digits)
    while ($Value -lt $alpha -and $shown -ge $alpha -and $digits -lt $pValueDigits) {
        $digits++
        $shown = [math]::Round($Value, $digits)
    }
    if ($Value -lt $alpha -and $shown -ge $alpha) {
        $scale = [decimal][math]::Pow(10, $digits)
        $shown = [math]::Floor($Value * $scale) / $scale
    }
    $shown.ToString('0.' + ('#' * $digits), $invariant)
}

function Get-ProbeMetricValue {
    param([Parameter(Mandatory)]$Boot, [Parameter(Mandatory)][string]$Driver, [Parameter(Mandatory)][string]$Field)
    $where = "boot $($Boot.Boot)"
    $found = @(@(Get-Field $Boot.Bench 'probes' $where) | Where-Object { @(Get-OptionalField $_ 'devices') -contains $Driver })
    if ($found.Count -ne 1) { throw "$where has $($found.Count) probes listing $Driver, expected 1" }
    $cpu = [int](Get-Field $found[0] 'cpu' "$where probe listing $Driver")
    [pscustomobject]@{ value = ConvertTo-WrittenDecimal (Get-Field $found[0] $Field "$where probe on CPU $cpu"); cpu = $cpu }
}

function Get-MetricValue {
    param([Parameter(Mandatory)]$Metric, [Parameter(Mandatory)]$Boot, [string[]]$Drivers)
    if ($Metric.source -eq 'probe') { return Get-ProbeMetricValue -Boot $Boot -Driver $Metric.driver -Field $Metric.field }
    if ($Metric.source -eq 'frames') { return [pscustomobject]@{ value = ConvertTo-WrittenDecimal (Get-Field $Boot.Bench "frames.$($Metric.field)" "boot $($Boot.Boot)"); cpu = $null } }
    $sum = 0d
    foreach ($driver in $Drivers) { $sum += (Get-DriverMetric -Boot $Boot -Driver $driver).isrDpcMsPerSecond }
    [pscustomobject]@{ value = $sum; cpu = $null }
}

function Get-CoreNote {
    param([Parameter(Mandatory)][object[]]$Sides)
    $cpus = @($Sides | ForEach-Object { $_.Readings | ForEach-Object { $_.cpu } } | Sort-Object -Unique)
    if ($cpus.Count -eq 1) { return $null }
    $parts = foreach ($side in $Sides) {
        $groups = foreach ($group in @($side.Readings | Group-Object -Property { $_.cpu } | Sort-Object -Property { [int]$_.Name })) {
            $boots = @($group.Group | ForEach-Object { $_.boot })
            'CPU {0} ({1} {2})' -f $group.Name, $(if ($boots.Count -eq 1) { 'boot' } else { 'boots' }), ($boots -join ', ')
        }
        '{0}: {1}' -f $side.Label, ($groups -join ', ')
    }
    $parts -join '; '
}

function Get-SeriesLoadName {
    param([Parameter(Mandatory)][object[]]$Boots)
    $names = @($Boots | ForEach-Object { [string](Get-Field $_.Bench 'load.name' "boot $($_.Boot)") } | Sort-Object -Unique)
    if ($names.Count -ne 1) { throw "the boots ran different loads: $($names -join ', ')" }
    $names[0]
}

function Get-SeriesAnalysis {
    param([Parameter(Mandatory)][string[]]$Labels, [Parameter(Mandatory)][System.Collections.IDictionary]$StateBoots)
    if ($Labels -notcontains $referenceState) { throw "the series has no $referenceState state; every pre-registered test compares a state against it" }
    $compared = @($Labels | Where-Object { $_ -ne $referenceState })
    foreach ($label in $compared) {
        if (-not $changedDrivers.Contains($label)) { throw "state '$label' has no changed-driver entry, so its pre-registered tests are not defined" }
    }
    $family = $testMetrics.Count * $compared.Count
    if ($family -eq 0) { return [pscustomobject]@{ family = 0; bottleneck = $null; tests = @(); load = @(); pHolmExact = @() } }

    $loadName = Get-SeriesLoadName -Boots @($Labels | ForEach-Object { $StateBoots[$_] })
    if (-not $marginRules.Contains($loadName)) { throw "no margins for load '$loadName': the pre-registered margins cover $(@($marginRules.Keys) -join ', ')" }
    $bottleneck = [string](Get-LoadRecipe -Name $loadName).bottleneck
    $stockBoots = @($StateBoots[$referenceState])

    $rows = New-Object System.Collections.Generic.List[object]
    $loadRows = New-Object System.Collections.Generic.List[object]
    foreach ($label in $compared) {
        $compareBoots = @($StateBoots[$label])
        $load = Get-LoadCheck -Stock @($stockBoots | ForEach-Object { ConvertTo-WrittenDecimal (Get-Field $_.Bench 'frames.avgFps' "boot $($_.Boot)") }) -State @($compareBoots | ForEach-Object { ConvertTo-WrittenDecimal (Get-Field $_.Bench 'frames.avgFps' "boot $($_.Boot)") })
        $loadRows.Add([pscustomobject]@{
                state         = $label
                stockValues   = @($stockBoots | ForEach-Object { ConvertTo-OutputNumber (Get-Field $_.Bench 'frames.avgFps' "boot $($_.Boot)") })
                stateValues   = @($compareBoots | ForEach-Object { ConvertTo-OutputNumber (Get-Field $_.Bench 'frames.avgFps' "boot $($_.Boot)") })
                stockMedian   = ConvertTo-OutputNumber $load.stockMedian
                stateMedian   = ConvertTo-OutputNumber $load.stateMedian
                differencePct = ConvertTo-OutputNumber $load.differencePct
                differs       = $load.differs
            })
        foreach ($metric in $testMetrics) {
            $isProbe = $metric.source -eq 'probe'
            $drivers = @()
            if ($metric.source -eq 'driver') { $drivers = @($changedDrivers[$label]) }
            $sides = @(
                [pscustomobject]@{ Label = $referenceState; Readings = @($stockBoots | ForEach-Object { $reading = Get-MetricValue -Metric $metric -Boot $_ -Drivers $drivers; [pscustomobject]@{ boot = $_.Boot; value = $reading.value; cpu = $reading.cpu } }) }
                [pscustomobject]@{ Label = $label; Readings = @($compareBoots | ForEach-Object { $reading = Get-MetricValue -Metric $metric -Boot $_ -Drivers $drivers; [pscustomobject]@{ boot = $_.Boot; value = $reading.value; cpu = $reading.cpu } }) }
            )
            $stockValues = [decimal[]]@($sides[0].Readings | ForEach-Object { $_.value })
            $stateValues = [decimal[]]@($sides[1].Readings | ForEach-Object { $_.value })
            $stockMedian = Get-Median -Values $stockValues
            $test = Get-RankSumTest -Stock $stockValues -State $stateValues
            $shift = Get-ShiftEstimate -Stock $stockValues -State $stateValues
            $rowDrivers = $drivers
            $stockCpu = @()
            $stateCpu = @()
            $coreNote = $null
            if ($isProbe) {
                $rowDrivers = @($metric.driver)
                $stockCpu = @($sides[0].Readings | ForEach-Object { $_.cpu } | Sort-Object -Unique)
                $stateCpu = @($sides[1].Readings | ForEach-Object { $_.cpu } | Sort-Object -Unique)
                $coreNote = Get-CoreNote -Sides $sides
            }
            $rows.Add([pscustomobject]@{
                    Metric = $metric
                    Test   = $test
                    Shift  = $shift
                    Margin = Get-MetricMargin -Rule $marginRules[$loadName][$metric.margin] -StockMedian $stockMedian
                    Row    = [ordered]@{
                        state           = $label
                        metric          = $metric.key
                        drivers         = @($rowDrivers)
                        stockCpu        = @($stockCpu)
                        stateCpu        = @($stateCpu)
                        coreNote        = $coreNote
                        stockValues     = @($stockValues | ForEach-Object { ConvertTo-OutputNumber $_ })
                        stateValues     = @($stateValues | ForEach-Object { ConvertTo-OutputNumber $_ })
                        stockMedian     = ConvertTo-OutputNumber $stockMedian
                        stateMedian     = ConvertTo-OutputNumber (Get-Median -Values $stateValues)
                        shift           = ConvertTo-OutputNumber $shift.shift
                        shiftPctOfStock = ConvertTo-OutputNumber (Get-PercentOf -Value $shift.shift -Reference $stockMedian)
                        ciLow           = ConvertTo-OutputNumber $shift.ciLow
                        ciHigh          = ConvertTo-OutputNumber $shift.ciHigh
                        ciConfidence    = ConvertTo-OutputNumber $shift.ciConfidence
                        margin          = $null
                        extreme         = [long]$test.extreme
                        permutations    = [long]$test.permutations
                        p               = ConvertTo-OutputNumber ($test.extreme / $test.permutations) $pValueDigits
                        pHolm           = $null
                        verdict         = $null
                        loadDiffers     = $load.differs
                    }
                })
        }
    }

    $holm = @(Get-HolmAdjusted -Extreme @($rows | ForEach-Object { $_.Test.extreme }) -Permutations @($rows | ForEach-Object { $_.Test.permutations }))
    $tests = for ($i = 0; $i -lt $rows.Count; $i++) {
        $entry = $rows[$i]
        $cannotShow = $null -ne $entry.Metric.cannotShowOn -and $entry.Metric.cannotShowOn -eq $bottleneck
        if (-not $cannotShow) { $entry.Row.margin = ConvertTo-OutputNumber $entry.Margin }
        $entry.Row.pHolm = $holm[$i].pHolm
        $entry.Row.verdict = Get-Verdict -Significant $holm[$i].significant -Direction $entry.Test.direction -CiLow $entry.Shift.ciLow -CiHigh $entry.Shift.ciHigh -Margin $entry.Margin -CannotShow:$cannotShow
        [pscustomobject]$entry.Row
    }
    [pscustomobject]@{
        family     = $family
        bottleneck = $bottleneck
        tests      = @($tests)
        load       = $loadRows.ToArray()
        pHolmExact = @($holm | ForEach-Object { $_.numerator / $_.denominator })
    }
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
        [ordered]@{ name = 'one accepted result per boot'; source = 'private runner journal.jsonl and plan.json'; benchJson = $false; status = 'passed' }
        [ordered]@{ name = 'interrupt mode of every planned device equals its state'; source = 'bench JSON devices[].MSISupported, Mode'; benchJson = $true; status = 'passed' }
        [ordered]@{ name = 'line sharing equals the plan where the plan sets it'; source = 'private runner plan.json sharedWith, bench JSON devices[].SharedWith'; benchJson = $false; status = 'passed' }
        [ordered]@{ name = 'OS build and UBR identical'; source = 'bench JSON metadata.os'; benchJson = $true; status = 'passed' }
        [ordered]@{ name = 'power scheme GUID and processor values identical'; source = 'bench JSON metadata.power'; benchJson = $true; status = 'passed' }
        [ordered]@{ name = 'present mode identical'; source = 'bench JSON frames.presentModes'; benchJson = $true; status = 'passed' }
        [ordered]@{ name = 'GPU and audio driver versions identical'; source = 'private runner wrapper environment.drivers'; benchJson = $false; status = 'passed' }
        [ordered]@{ name = 'explicit power settings identical'; source = 'private runner wrapper environment.powerExplicit'; benchJson = $false; status = $(if ($hasExplicit) { 'passed' } else { 'not recorded' }) }
        [ordered]@{ name = 'bench script, PresentMon, load build, video config and refresh rate identical'; source = 'bench JSON metadata.benchScript, metadata.presentMonVersion, presentMon, load, frames.refreshHz'; benchJson = $true; status = $(if ($benchRecorded) { 'passed' } else { 'not recorded' }) }
        [ordered]@{ name = 'HVCI, BIOS version, microcode and clock flags identical'; source = 'private runner wrapper environment'; benchJson = $false; status = $(if ($wrapperRecorded) { 'passed' } else { 'not recorded' }) }
        [ordered]@{ name = 'tone played on the planned audio controller'; source = 'bench JSON background.tone.controllerInstanceId'; benchJson = $true; status = $(if (@($Plan.background) -contains 'tone') { 'passed' } else { 'not planned' }) }
    )
    $checks | ForEach-Object { [pscustomobject]$_ }
}

function Get-FileMap {
    param([bool]$SystemCpu, [bool]$Tests)
    $rows = @(
        [ordered]@{ table = 'Pre-registered tests'; files = 'msi-bench-bootNN-stateNN.json, bench/loads/<load.name>.json'; fields = 'probes[].devices, probes[].cpu, probes[].stalledPct, probes[].gapP99Us, frames.low1PctMs, frames.avgFps, trace.seconds, trace.drivers[].isrTotalUs, trace.drivers[].dpcTotalUs, load.name; the recipe bottleneck'; runner = $false }
        [ordered]@{ table = 'Frames'; files = 'msi-bench-bootNN-stateNN.json'; fields = $(if ($SystemCpu) { 'frames.*, systemCpu' } else { 'frames.*' }); runner = $false }
        [ordered]@{ table = 'Drivers'; files = 'msi-bench-bootNN-stateNN.json'; fields = 'trace.seconds, trace.drivers[]'; runner = $false }
        [ordered]@{ table = 'Probes'; files = 'msi-bench-bootNN-stateNN.json, msi-bench-bootNN-stateNN-stalls.csv'; fields = 'probes[]; stall file rows per cpu'; runner = $false }
        [ordered]@{ table = 'Runs with a gap of 5 ms or more'; files = 'msi-bench-bootNN-stateNN-stalls.csv'; fields = 'cpu, offsetMs, gapUs'; runner = $false }
        [ordered]@{ table = 'USB reads'; files = 'msi-bench-bootNN-stateNN.json'; fields = 'background.usbRead.mibPerSecond'; runner = $false }
        [ordered]@{ table = 'Testbed: OS, power, present mode, load, PresentMon'; files = 'msi-bench-bootNN-stateNN.json'; fields = 'metadata.*, frames.presentModes, load'; runner = $false }
        [ordered]@{ table = 'Testbed: CPU, BIOS, drivers, explicit power settings'; files = 'bootNN-stateNN-msi.json'; fields = 'environment.*'; runner = $true }
        [ordered]@{ table = 'Testbed: counts of disabled services, tasks and startup items'; files = 'journal.jsonl'; fields = 'start event services, tasks, startup counts'; runner = $true }
        [ordered]@{ table = 'State labels and device modes'; files = 'plan.json'; fields = 'boots[].label, boots[].states[].devices[]'; runner = $true }
    )
    $rows | Where-Object { $Tests -or $_.table -ne 'Pre-registered tests' } | ForEach-Object { [pscustomobject]$_ }
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
            $counts = $start.PSObject.Properties[$key]
            if ($counts) { $rows["Disabled $key"] = [string][int]$counts.Value }
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
    $analysis = Get-SeriesAnalysis -Labels $labels -StateBoots $stateBoots
    $fileMap = @(Get-FileMap -SystemCpu $hasSystemCpu -Tests ($analysis.family -gt 0))

    $summary = [ordered]@{
        series    = [string]$plan.series
        constants = [ordered]@{
            driverFloorMsPerSecond = $driverFloorMsPerSecond
            longGapUs              = $longGapUs
            stallFileMinUs         = $stallFileMinUs
            referenceState         = $referenceState
            alpha                  = $alpha
            confidence             = $confidence
            fpsLoadLimitPct        = $fpsLoadLimitPct
            margins                = $marginRules
            changedDrivers         = $changedDrivers
            metrics                = @($testMetrics | ForEach-Object { $_.key })
        }
        checks    = $checks
        testbed   = $testbed
        analysis  = [ordered]@{ family = $analysis.family; bottleneck = $analysis.bottleneck; tests = $analysis.tests; load = $analysis.load }
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
    if ($analysis.family -gt 0) {
        $md.Add('## Pre-registered tests')
        $md.Add('')
        $md.Add(('Each state against {0}, lower is better for every metric: a two-sided exact permutation test of the rank sum, Holm-corrected over the {1} tests at alpha {2}, and the Hodges-Lehmann shift (state minus {0}) with an interval of at least {3}% confidence.' -f $referenceState, $analysis.family, $alpha.ToString($invariant), ($confidence * 100).ToString('0.##', $invariant)))
        $md.Add(('Verdicts: helped or hurt when the Holm-adjusted p is under {0}; no difference when the whole interval lies strictly inside the margin; cannot tell otherwise. The note names the boots whose probe core differs.' -f $alpha.ToString($invariant)))
        $cannotShowLabels = @($testMetrics | Where-Object { $_.cannotShowOn -and $_.cannotShowOn -eq $analysis.bottleneck } | ForEach-Object { $_.label })
        if ($cannotShowLabels.Count) { $md.Add(('On this {0}-bound load a test that is not significant reads cannot show for: {1}.' -f $analysis.bottleneck, ($cannotShowLabels -join ', '))) }
        $md.Add('')
        $metricLabel = @{}
        foreach ($metric in $testMetrics) { $metricLabel[$metric.key] = $metric.label }
        $testRows = @(for ($i = 0; $i -lt $analysis.tests.Count; $i++) {
                $test = $analysis.tests[$i]
                $notes = @(@($test.coreNote, $(if ($test.loadDiffers) { 'load differs' })) | Where-Object { $_ })
                , @(
                    $test.state
                    $metricLabel[$test.metric]
                    $(if ($test.stockCpu.Count) { '{0} / {1}' -f ($test.stockCpu -join ', '), ($test.stateCpu -join ', ') } else { '-' })
                    (Format-Rounded $test.stockMedian)
                    (Format-Rounded $test.stateMedian)
                    (Format-Rounded $test.shift)
                    $(if ($null -eq $test.shiftPctOfStock) { 'n/a' } else { Format-Rounded $test.shiftPctOfStock })
                    $(if ($null -eq $test.ciLow) { 'none' } else { '[{0}, {1}]' -f (Format-Rounded $test.ciLow), (Format-Rounded $test.ciHigh) })
                    $(if ($null -eq $test.margin) { '-' } else { '+/-{0}' -f (Format-Rounded $test.margin) })
                    (Format-PValue -Value $analysis.pHolmExact[$i])
                    $test.verdict
                    $(if ($notes.Count) { $notes -join '; ' } else { '-' })
                )
            })
        $md.AddRange([string[]]@(Format-MarkdownTable -Header 'State', 'Metric', 'Probe CPU, stock / state', 'Stock median', 'State median', 'Shift', 'Shift (% of stock)', 'Interval', 'Margin', 'p (Holm)', 'Verdict', 'Note' -Rows @($testRows)))
        $md.Add('')
        $md.Add(('Average FPS is a load check only: a state whose median differs from the {0} median by more than {1}% is marked load differs on every row above, and the mark changes no verdict.' -f $referenceState, $fpsLoadLimitPct.ToString($invariant)))
        $md.Add('')
        $loadTableRows = @(foreach ($load in $analysis.load) {
                , @($load.state, (Format-Rounded $load.stockMedian), (Format-Rounded $load.stateMedian), $(if ($null -eq $load.differencePct) { 'n/a' } else { Format-Rounded $load.differencePct }), $(if ($load.differs) { 'differs' } else { 'same' }))
            })
        $md.AddRange([string[]]@(Format-MarkdownTable -Header 'State', 'Avg FPS, stock median', 'Avg FPS, state median', 'Difference (%)', 'Load' -Rows @($loadTableRows)))
        $md.Add('')
    }
    $md.Add('## Frames')
    $md.Add('')
    $md.Add('Median [min-max] over the boots of each state. 1% low and 0.1% low are the 99th and 99.9th percentile frame time.')
    $md.Add('')
    $frameHeader = @('State', 'Boots', 'Avg FPS', 'p50 (ms)', '1% low (ms)', '0.1% low (ms)', 'GPU busy p50 (ms)', 'CPU busy p50 (ms)')
    if ($hasSystemCpu) { $frameHeader += 'System CPU busy (% of the machine)' }
    $frameRows = @(foreach ($state in $states) {
            $cells = @($state.label, $state.boots.Count, (Format-Spread $state.frames.avgFps), (Format-Spread $state.frames.p50Ms), (Format-Spread $state.frames.low1PctMs), (Format-Spread $state.frames.low01PctMs), (Format-Spread $state.frames.gpuBusyP50Ms), (Format-Spread $state.frames.cpuBusyP50Ms))
            if ($hasSystemCpu) { $cells += Format-Spread $state.systemCpuBusyPct }
            , $cells
        })
    $md.AddRange([string[]]@(Format-MarkdownTable -Header $frameHeader -Rows @($frameRows)))
    $md.Add('')
    $md.Add('## Drivers')
    $md.Add('')
    $md.Add(('Every driver whose median ISR plus DPC time is at least {0} ms/s in any state. Median [min-max] over the boots of each state.' -f (Format-Rounded $driverFloorMsPerSecond)))
    $md.Add('')
    $driverRows = @(foreach ($name in $listed) {
            foreach ($state in $states) {
                $row = $state.drivers | Where-Object { $_.driver -eq $name }
                , @($name, $state.label, (Format-Spread $row.metrics.isrPerSecond), (Format-Spread $row.metrics.isrMeanUs), (Format-Spread $row.metrics.isrMsPerSecond), (Format-Spread $row.metrics.dpcPerSecond), (Format-Spread $row.metrics.dpcMeanUs), (Format-Spread $row.metrics.dpcP99Us), (Format-Spread $row.metrics.dpcMsPerSecond), $(if ($row.cpu.Count) { $row.cpu -join ', ' } else { '-' }))
            }
        })
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'Driver', 'State', 'ISR/s', 'ISR mean (us)', 'ISR (ms/s)', 'DPC/s', 'DPC mean (us)', 'DPC p99 (us)', 'DPC (ms/s)', 'CPU of the ISR' -Rows @($driverRows)))
    $md.Add('')
    $md.Add('## Probes')
    $md.Add('')
    $stallHeader = 'Stalls of {0} ms or more' -f (Format-Rounded ($stallFileMinUs / 1000))
    $md.Add(('Median [min-max] over the boots of each state. {0} counts the rows of the stall file on that CPU in one boot.' -f $stallHeader))
    $md.Add('')
    $probeRows = @(foreach ($state in $states) {
            foreach ($probe in $state.probes) {
                , @($state.label, $probe.cpu, $(if ($probe.devices.Count) { $probe.devices -join ', ' } else { '-' }), (Format-Spread $probe.stalledPct), (Format-Spread $probe.gapP50Us), (Format-Spread $probe.gapP99Us), (Format-Spread $probe.gapP999Us), (Format-Spread $probe.stallCount))
            }
        })
    $md.AddRange([string[]]@(Format-MarkdownTable -Header 'State', 'Probe CPU', 'Drivers on the core', 'Stalled (%)', 'Gap p50 (us)', 'Gap p99 (us)', 'Gap p99.9 (us)', $stallHeader -Rows @($probeRows)))
    $md.Add('')
    $md.Add(('## Runs with a gap of {0} ms or more' -f (Format-Rounded ($longGapUs / 1000))))
    $md.Add('')
    $gapRows = @(foreach ($state in $states) {
            $detail = ($state.longGapRuns | ForEach-Object {
                    $run = $_
                    'boot {0}: {1}' -f $run.boot, (($run.gaps | ForEach-Object { 'cpu {0} at {1} ms ({2} us)' -f $_.cpu, (Format-Rounded $_.offsetMs), (Format-Rounded $_.gapUs) }) -join ', ')
                }) -join '; '
            , @($state.label, "$($state.longGapRuns.Count) of $($state.boots.Count)", $(if ($detail) { $detail } else { '-' }))
        })
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
