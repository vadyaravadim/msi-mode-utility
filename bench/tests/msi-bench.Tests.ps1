BeforeAll {
    $script:benchScript = Join-Path $PSScriptRoot '..\msi-bench.ps1'
    . $script:benchScript -Phase 'unit-test'
    if (-not ('KernelCsv' -as [type])) { Add-Type -TypeDefinition $msiBenchSource }

    function New-TraceRow {
        param([string]$Name, [string]$Type, [int]$Cpu, [long]$Clock, [string[]]$Data)
        $fixed = @($Name, $Type, '0', '2', '0', '0', '50', '0', '0x0000000000000000', '0xFFFFFFFF', '0xFFFFFFFF', "$Cpu", '', '', '{00000000-0000-0000-0000-000000000000}', '', "$Clock", '0', '0')
        '  ' + ((@($fixed) + @($Data)) -join ', ')
    }
    function New-HeaderRow {
        param([string]$ClockCode)
        $data = @('8192', '83951626', '26300', '32', '1', '156250', '0', '0x2000080', '1497', '1', '8', '0', '1997', '0xA', '0x7', '1', '10000000', '1', $ClockCode, '0', '"NT Kernel Logger"', '"x.etl"')
        New-TraceRow 'EventTrace' 'Header' 0 100 $data
    }
    function New-ImageRow {
        param([string]$Base, [string]$Size, [string]$ProcessId, [string]$Name)
        New-TraceRow 'Image' 'DCStart' 12 100 @($Base, $Size, $ProcessId, '1', '2', '0', '1', '0', '0x0', '0', '0', '0', '0', "`"$Name`"")
    }
    function New-EventRow {
        param([string]$Type, [int]$Cpu, [long]$Us10, [string]$Routine, [int]$Vector = 48)
        $clock = 5000000
        $data = @("$($clock - $Us10)", $Routine)
        if ($Type -like '*ISR*') { $data += @('1', "$Vector", '0') }
        New-TraceRow 'PerfInfo' $Type $Cpu $clock $data
    }
    function Write-TraceCsv {
        param([string]$Path, [string]$ClockCode = '0x1')
        $rows = @(
            '  Event Name,       Type,     Event ID',
            (New-HeaderRow $ClockCode),
            (New-ImageRow '0x0000000000001000' '0x1000' '0' '\SystemRoot\system32\drivers\drv.sys'),
            (New-ImageRow '0x0000000000005000' '0x1000' '0' '\SystemRoot\system32\drivers\other.sys'),
            (New-ImageRow '0x0000000000009000' '0x1000' '4321' 'C:\Users\x\app.exe'),
            (New-EventRow 'ISR' 0 20 '0x0000000000001100'),
            (New-EventRow 'ISR-MSI' 1 20 '0x0000000000001100' 64),
            (New-EventRow 'ISR-MSI' 1 30 '0x0000000000001100' 64),
            (New-EventRow 'ISR' 2 40 '0x0000000000001100'),
            (New-EventRow 'TimerDPC' 0 50 '0x0000000000005100'),
            (New-EventRow 'DPC' 3 70 '0x0000000000005100'),
            (New-EventRow 'ISR' 0 20 '0x0000000000009100'),
            (New-EventRow 'ISR' 0 20 '0x0000000000007000'),
            (New-EventRow 'ISR' 0 -5 '0x0000000000001100'),
            (New-EventRow 'ISR-MSI' 1 20000000 '0x0000000000001100'),
            (New-TraceRow 'Thread' 'Start' 0 100 @('1', '2'))
        )
        [System.IO.File]::WriteAllText($Path, ($rows -join "`r`n") + "`r`n")
    }
    function New-Stat {
        param([string]$Module, [hashtable]$PerCpu)
        $stat = New-Object DriverStat
        $stat.Module = $Module
        foreach ($cpu in $PerCpu.Keys) { $stat.IsrPerCpu[[int]$cpu] = [int]$PerCpu[$cpu] }
        $stat
    }
    function New-StatTable {
        param([object[]]$Stats)
        $table = New-Object 'System.Collections.Generic.Dictionary[string,DriverStat]'
        foreach ($s in $Stats) { $table[$s.Module] = $s }
        $table
    }
}

Describe 'KernelCsv.Parse' {
    BeforeAll {
        $script:csv = Join-Path $TestDrive 'trace.csv'
        Write-TraceCsv -Path $script:csv
        $script:trace = [KernelCsv]::Parse($script:csv)
    }
    It 'counts plain and message ISRs and DPCs' {
        $trace.IsrLine | Should -Be 4
        $trace.IsrMsi | Should -Be 2
        $trace.Dpc | Should -Be 2
    }
    It 'drops events with a negative or over-a-second duration' {
        $trace.Dropped | Should -Be 2
    }
    It 'counts plain and message ISRs per CPU' {
        $trace.IsrPlainPerCpu[0] | Should -Be 3
        $trace.IsrPlainPerCpu[2] | Should -Be 1
        $trace.IsrMessagePerCpu[1] | Should -Be 2
        $trace.IsrMessagePerCpu.ContainsKey(0) | Should -BeFalse
    }
    It 'attributes ISRs to the image holding the routine and counts them per CPU together' {
        $drv = $trace.Stats['drv.sys']
        $drv.IsrLine | Should -Be 2
        $drv.IsrMsi | Should -Be 2
        $drv.IsrPerCpu[0] | Should -Be 1
        $drv.IsrPerCpu[1] | Should -Be 2
        $drv.IsrPerCpu[2] | Should -Be 1
        $drv.Vectors[64] | Should -Be 2
    }
    It 'attributes DPCs and measures the duration in microseconds' {
        $other = $trace.Stats['other.sys']
        $other.DpcCount | Should -Be 2
        ($other.DpcUs | Sort-Object) -join ',' | Should -Be '5,7'
        $trace.Stats['drv.sys'].IsrUs[0] | Should -Be 2
    }
    It 'files user-mode images and unmapped routines under unknown' {
        $trace.Stats['unknown'].IsrLine | Should -Be 2
        $trace.Stats.ContainsKey('app.exe') | Should -BeFalse
    }
    It 'reads the clock type from the EventTrace header' {
        $trace.ClockType | Should -Be 1
        foreach ($code in @(@('0x2', 2), @('0x3', 3))) {
            $path = Join-Path $TestDrive "clock$($code[1]).csv"
            Write-TraceCsv -Path $path -ClockCode $code[0]
            ([KernelCsv]::Parse($path)).ClockType | Should -Be $code[1]
        }
    }
    It 'reports clock type 0 when the header row is missing' {
        $path = Join-Path $TestDrive 'noheader.csv'
        Set-Content -Path $path -Value (Get-Content $script:csv | Where-Object { $_ -notmatch 'EventTrace' })
        ([KernelCsv]::Parse($path)).ClockType | Should -Be 0
    }
}

Describe 'Read-KernelCsv' {
    It 'returns the trace for a perf clock' {
        $path = Join-Path $TestDrive 'perf.csv'
        Write-TraceCsv -Path $path
        (Read-KernelCsv -Path $path).IsrMsi | Should -Be 2
    }
    It 'throws for a cycle or system clock' {
        $path = Join-Path $TestDrive 'cycle.csv'
        Write-TraceCsv -Path $path -ClockCode '0x3'
        { Read-KernelCsv -Path $path } | Should -Throw '*cycle*'
        Write-TraceCsv -Path $path -ClockCode '0x2'
        { Read-KernelCsv -Path $path } | Should -Throw '*system*'
    }
    It 'throws when the clock type is unknown' {
        $path = Join-Path $TestDrive 'unknown.csv'
        Set-Content -Path $path -Value '  Thread, Start, 0'
        { Read-KernelCsv -Path $path } | Should -Throw '*unknown*'
    }
}

Describe 'Get-DeviceCpuPick' {
    It 'picks the CPU with the most ISRs of the driver' {
        $stats = New-StatTable @((New-Stat 'a.sys' @{ 0 = 3; 4 = 9; 7 = 1 }))
        $pick = @(Get-DeviceCpuPick -Stats $stats -Driver 'a.sys')
        $pick.Count | Should -Be 1
        $pick[0].driver | Should -Be 'a.sys'
        $pick[0].cpu | Should -Be 4
        $pick[0].isrOnCpu | Should -Be 9
        $pick[0].isrTotal | Should -Be 13
    }
    It 'matches the driver name case-insensitively and reports the traced name' {
        $stats = New-StatTable @((New-Stat 'HDAudBus.sys' @{ 1 = 5 }))
        $pick = @(Get-DeviceCpuPick -Stats $stats -Driver 'hdaudbus.SYS')
        $pick[0].driver | Should -Be 'HDAudBus.sys'
        $pick[0].cpu | Should -Be 1
    }
    It 'takes the lower CPU on a tie' {
        $stats = New-StatTable @((New-Stat 'a.sys' @{ 6 = 4; 2 = 4; 9 = 4 }))
        (Get-DeviceCpuPick -Stats $stats -Driver 'a.sys').cpu | Should -Be 2
    }
    It 'picks one CPU per driver' {
        $stats = New-StatTable @((New-Stat 'a.sys' @{ 1 = 2 }), (New-Stat 'b.sys' @{ 5 = 2 }))
        $pick = @(Get-DeviceCpuPick -Stats $stats -Driver @('a.sys', 'b.sys'))
        ($pick | ForEach-Object { $_.cpu }) -join ',' | Should -Be '1,5'
    }
    It 'throws naming the drivers that had ISRs when the driver had none' {
        $stats = New-StatTable @((New-Stat 'a.sys' @{ 1 = 2 }), (New-Stat 'dpconly.sys' @{}), (New-Stat 'b.sys' @{ 5 = 2 }))
        { Get-DeviceCpuPick -Stats $stats -Driver 'dpconly.sys' } | Should -Throw '*a.sys*b.sys*'
        { Get-DeviceCpuPick -Stats $stats -Driver 'missing.sys' } | Should -Throw "*missing.sys*"
    }
}

Describe 'ConvertTo-ListArgument' {
    It 'splits comma-joined values and trims them' {
        (ConvertTo-ListArgument 'a, b') -join '|' | Should -Be 'a|b'
        (ConvertTo-ListArgument @('a,b', 'c')) -join '|' | Should -Be 'a|b|c'
    }
    It 'drops empty parts and returns nothing for null' {
        (ConvertTo-ListArgument '1,,2,') -join '|' | Should -Be '1|2'
        @(ConvertTo-ListArgument $null).Count | Should -Be 0
    }
}

Describe 'Get-ProbePlan' {
    It 'sorts and dedupes the explicit CPUs' {
        $plan = @(Get-ProbePlan -Cpu @(5, 0, 5) -Pick @() -ProcessorCount 8 -DefaultCpu 3)
        ($plan | ForEach-Object { $_.cpu }) -join ',' | Should -Be '0,5'
        @($plan[0].devices).Count | Should -Be 0
    }
    It 'unions picked CPUs with the explicit ones and lists the drivers behind each' {
        $picks = @([pscustomobject]@{ driver = 'a.sys'; cpu = 1 }, [pscustomobject]@{ driver = 'b.sys'; cpu = 1 }, [pscustomobject]@{ driver = 'c.sys'; cpu = 5 })
        $plan = @(Get-ProbePlan -Cpu @(5, 2) -Pick $picks -ProcessorCount 8 -DefaultCpu 0)
        ($plan | ForEach-Object { $_.cpu }) -join ',' | Should -Be '1,2,5'
        $plan[0].devices -join ',' | Should -Be 'a.sys,b.sys'
        @($plan[1].devices).Count | Should -Be 0
        $plan[2].devices -join ',' | Should -Be 'c.sys'
    }
    It 'falls back to the default CPU only when nothing was asked for' {
        $plan = @(Get-ProbePlan -Cpu @() -Pick @() -ProcessorCount 8 -DefaultCpu 3)
        $plan.Count | Should -Be 1
        $plan[0].cpu | Should -Be 3
    }
    It 'throws for a CPU that does not exist' {
        { Get-ProbePlan -Cpu @(8) -Pick @() -ProcessorCount 8 -DefaultCpu 0 } | Should -Throw '*8*'
        { Get-ProbePlan -Cpu @(-1) -Pick @() -ProcessorCount 8 -DefaultCpu 0 } | Should -Throw
    }
}

Describe 'Get-StallSummary' {
    It 'totals the stalled time and the share of the span' {
        $s = Get-StallSummary -Gaps ([double[]]@(2.5, 3, 7, 12, 150, 25000)) -SpanSeconds 1 -ThresholdUs 2
        $s.stalledUs | Should -Be 25174.5
        $s.stalledPct | Should -Be 2.52
        $s.gapsPerSecond | Should -Be 6
        $s.gapMaxUs | Should -Be 25000
        $s.gapP50Us | Should -Be 12
    }
    It 'builds 1-2-5 buckets from the threshold with an open last bucket' {
        $s = Get-StallSummary -Gaps ([double[]]@(2.5, 3, 7, 12, 150, 25000)) -SpanSeconds 1 -ThresholdUs 2
        $h = @($s.histogram)
        $h.Count | Should -Be 15
        $h[0].fromUs | Should -Be 2
        $h[0].toUs | Should -Be 5
        $h[14].fromUs | Should -Be 100000
        $h[14].toUs | Should -BeNullOrEmpty
        ($h | ForEach-Object { $_.gaps }) -join ',' | Should -Be '2,1,1,0,0,1,0,0,0,0,0,0,1,0,0'
        $h[0].stalledUs | Should -Be 5.5
        ($h | Measure-Object gaps -Sum).Sum | Should -Be 6
    }
    It 'puts a gap equal to an edge into the bucket that starts there' {
        $s = Get-StallSummary -Gaps ([double[]]@(10)) -SpanSeconds 1 -ThresholdUs 2
        $bucket = @($s.histogram | Where-Object { $_.fromUs -eq 10 })[0]
        $bucket.gaps | Should -Be 1
        $bucket.toUs | Should -Be 20
    }
    It 'starts the first bucket at a threshold above the first edge' {
        $s = Get-StallSummary -Gaps ([double[]]@(11)) -SpanSeconds 1 -ThresholdUs 10
        $h = @($s.histogram)
        $h[0].fromUs | Should -Be 10
        $h[0].toUs | Should -Be 20
        $h[0].gaps | Should -Be 1
        $h.Count | Should -Be 13
    }
    It 'returns zeros and all empty buckets for no gaps' {
        $s = Get-StallSummary -Gaps ([double[]]@()) -SpanSeconds 2 -ThresholdUs 2
        $s.stalledUs | Should -Be 0
        $s.stalledPct | Should -Be 0
        $s.gapsPerSecond | Should -Be 0
        $s.gapMaxUs | Should -Be 0
        $s.gapP99Us | Should -Be 0
        @($s.histogram).Count | Should -Be 15
        (@($s.histogram) | Measure-Object gaps -Sum).Sum | Should -Be 0
    }
    It 'does not reorder the caller array' {
        $gaps = [double[]]@(9, 3, 5)
        $null = Get-StallSummary -Gaps $gaps -SpanSeconds 1 -ThresholdUs 2
        $gaps -join ',' | Should -Be '9,3,5'
    }
}

Describe 'stall timeline' {
    It 'writes the CSV lines for gaps with their offset' {
        $lines = @(Get-StallTimelineLine -Cpu 3 -OffsetsMs ([double[]]@(12.3456, 800)) -GapsUs ([double[]]@(1500.25, 2000)))
        $lines -join '|' | Should -Be '3,12.346,1500.25|3,800,2000'
    }
    It 'returns no lines for an empty timeline' {
        @(Get-StallTimelineLine -Cpu 3 -OffsetsMs ([double[]]@()) -GapsUs ([double[]]@())).Count | Should -Be 0
    }
    It 'records gaps of at least 1 ms with an offset from the window start' {
        $probe = New-Object StallProbe -ArgumentList 0, 1, 2.0
        $probe.Start()
        $span = 0.0
        $gaps = $probe.Stop([ref]$span)
        $offsets = $probe.TimelineOffsetsMs
        $stalls = $probe.TimelineGapsUs
        $span | Should -BeGreaterThan 0.9
        $offsets.Count | Should -Be $stalls.Count
        $expected = @($gaps | Where-Object { $_ -ge [StallProbe]::TimelineMinUs }).Count
        $stalls.Count | Should -Be $expected
        foreach ($g in $stalls) { $g | Should -BeGreaterOrEqual 1000 }
        foreach ($o in $offsets) { $o | Should -BeLessOrEqual ($span * 1000 + 1) }
        foreach ($g in $gaps) { $g | Should -BeGreaterThan 2.0 }
    }
}

Describe 'Assert-LoadArgument' {
    It 'accepts no load with or without -Seconds' {
        { Assert-LoadArgument -SecondsGiven $true } | Should -Not -Throw
        { Assert-LoadArgument -SecondsGiven $false } | Should -Not -Throw
    }
    It 'accepts a load with PresentMon and no -Seconds' {
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $false } | Should -Not -Throw
    }
    It 'requires -PresentMon with -Load' {
        { Assert-LoadArgument -Load 'superposition' -SecondsGiven $false } | Should -Throw '*-PresentMon*'
    }
    It 'requires -Load with -PresentMon' {
        { Assert-LoadArgument -PresentMon 'pm.exe' -SecondsGiven $false } | Should -Throw '*-Load*'
    }
    It 'refuses -Seconds together with -Load because the recipe sets the window' {
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $true } | Should -Throw '*-Seconds*'
    }
}
