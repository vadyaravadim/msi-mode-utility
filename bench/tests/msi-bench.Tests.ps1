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
    It 'refuses -ProcessCpu without -Load' {
        { Assert-LoadArgument -SecondsGiven $false -ProcessCpu } | Should -Throw '*-ProcessCpu*'
    }
    It 'accepts -ProcessCpu with -Load' {
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $false -ProcessCpu } | Should -Not -Throw
    }
}

Describe 'Get-IrqMode' {
    It 'reports one message-signaled vector' {
        $mode = Get-IrqMode -Irq @(-5)
        $mode.kind | Should -Be 'message'
        $mode.text | Should -Be 'message-signaled, 1 vector'
    }
    It 'reports several message-signaled vectors' {
        $mode = Get-IrqMode -Irq @(-5, -6, -7)
        $mode.kind | Should -Be 'message'
        $mode.text | Should -Be 'message-signaled, 3 vectors'
    }
    It 'reports a line IRQ' {
        $mode = Get-IrqMode -Irq @(16)
        $mode.kind | Should -Be 'line'
        $mode.text | Should -Be 'line IRQ 16'
    }
    It 'reports a mixed device as line with the non-negative IRQs only' {
        $mode = Get-IrqMode -Irq @(-5, 16)
        $mode.kind | Should -Be 'line'
        $mode.text | Should -Be 'line IRQ 16'
    }
    It 'reports no IRQ for an empty list' {
        $mode = Get-IrqMode -Irq @()
        $mode.kind | Should -Be 'none'
        $mode.text | Should -Be 'no IRQ assigned'
    }
    It 'reports no IRQ for a device missing from the resource table' {
        $mode = Get-IrqMode -Irq $null
        $mode.kind | Should -Be 'none'
        $mode.text | Should -Be 'no IRQ assigned'
    }
}

Describe 'Get-DeviceIrq' {
    BeforeAll {
        function New-AllocatedResource {
            param([string]$ClassName, [string]$DeviceId, [int64]$Irq)
            [pscustomobject]@{
                Antecedent = [pscustomobject]@{
                    CimClass  = [pscustomobject]@{ CimClassName = $ClassName }
                    IRQNumber = $Irq
                }
                Dependent  = [pscustomobject]@{ DeviceID = $DeviceId }
            }
        }
    }
    It 'converts an unsigned message vector to its signed value' {
        Mock Get-CimInstance { New-AllocatedResource 'Win32_IRQResource' 'PCI\DEV_A' 4294967291 }
        $irqs = Get-DeviceIrq
        $irqs['PCI\DEV_A'].Count | Should -Be 1
        $irqs['PCI\DEV_A'][0] | Should -Be -5
    }
    It 'ignores rows whose antecedent is not an IRQ resource' {
        Mock Get-CimInstance { New-AllocatedResource 'Win32_DeviceMemoryAddress' 'PCI\DEV_A' 16 }
        (Get-DeviceIrq).Count | Should -Be 0
    }
    It 'keeps two IRQs of one device' {
        Mock Get-CimInstance {
            New-AllocatedResource 'Win32_IRQResource' 'PCI\DEV_A' 16
            New-AllocatedResource 'Win32_IRQResource' 'PCI\DEV_A' 17
        }
        $irqs = Get-DeviceIrq
        @($irqs['PCI\DEV_A']) | Should -Be @(16, 17)
    }
}

Describe 'Assert-LoadArgument background pairing' {
    It 'accepts a load with both loads and the file' {
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $false -Background @('tone', 'usb-read') -UsbReadFile 'F:\x.bin' } | Should -Not -Throw
    }
    It 'accepts the tone alone' {
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $false -Background @('tone') } | Should -Not -Throw
    }
    It 'refuses -Background without -Load' {
        { Assert-LoadArgument -SecondsGiven $false -Background @('tone') } | Should -Throw '*-Background needs -Load*'
    }
    It 'refuses usb-read without -UsbReadFile' {
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $false -Background @('usb-read') } | Should -Throw '*-UsbReadFile*'
    }
    It 'refuses -UsbReadFile without usb-read' {
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $false -Background @('tone') -UsbReadFile 'F:\x.bin' } | Should -Throw '*-UsbReadFile needs*'
        { Assert-LoadArgument -Load 'superposition' -PresentMon 'pm.exe' -SecondsGiven $false -UsbReadFile 'F:\x.bin' } | Should -Throw '*-UsbReadFile needs*'
    }
    It 'refuses a name outside the ValidateSet' {
        $attribute = (Get-Command $script:benchScript).Parameters['Background'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        @($attribute.ValidValues) | Should -Be @('tone', 'usb-read')
    }
}

Describe 'background load constants' {
    It 'pins the tone, the reader and the file minimum' {
        $toneFrequencyHz | Should -Be 440
        $toneDbfs | Should -Be -40
        $toneSampleRate | Should -Be 48000
        $toneSeconds | Should -Be 1
        $usbReadBlockBytes | Should -Be 64KB
        $usbReadStopTimeoutMs | Should -Be 10000
        $usbReadMinBytes | Should -Be 1GB
        $processCpuMinSeconds | Should -Be 0.05
    }
}

Describe 'tone wave' {
    BeforeAll {
        $script:wave = [ToneWave]::Build($toneFrequencyHz, $toneDbfs, $toneSampleRate, $toneSeconds)
        $count = ($script:wave.Length - 44) / 2
        $script:samples = New-Object 'int16[]' $count
        [System.Buffer]::BlockCopy($script:wave, 44, $script:samples, 0, $count * 2)
    }

    It 'writes a 16-bit mono PCM header for the configured rate and length' {
        $wave = $script:wave
        [System.Text.Encoding]::ASCII.GetString($wave, 0, 4) | Should -Be 'RIFF'
        [System.Text.Encoding]::ASCII.GetString($wave, 8, 4) | Should -Be 'WAVE'
        [System.Text.Encoding]::ASCII.GetString($wave, 12, 4) | Should -Be 'fmt '
        [System.Text.Encoding]::ASCII.GetString($wave, 36, 4) | Should -Be 'data'
        [BitConverter]::ToUInt16($wave, 20) | Should -Be 1
        [BitConverter]::ToUInt16($wave, 22) | Should -Be 1
        [BitConverter]::ToUInt32($wave, 24) | Should -Be 48000
        [BitConverter]::ToUInt16($wave, 34) | Should -Be 16
        $wave.Length | Should -Be (44 + 48000 * 2)
        [BitConverter]::ToUInt32($wave, 4) | Should -Be ($wave.Length - 8)
        [BitConverter]::ToUInt32($wave, 40) | Should -Be ($wave.Length - 44)
    }

    It 'peaks at -40 dBFS' {
        $peak = ($script:samples | ForEach-Object { [math]::Abs([int]$_) } | Measure-Object -Maximum).Maximum
        $expected = 32767 * [math]::Pow(10, -40 / 20)
        $peak | Should -BeGreaterOrEqual ([math]::Floor($expected) - 1)
        $peak | Should -BeLessOrEqual ([math]::Ceiling($expected) + 1)
    }

    It 'holds exactly the configured number of cycles, so the loop has no click' {
        $rising = 0
        for ($i = 1; $i -lt $script:samples.Length; $i++) { if ($script:samples[$i - 1] -lt 0 -and $script:samples[$i] -ge 0) { $rising++ } }
        $rising | Should -BeIn @(439, 440)
        [math]::Abs([int]$script:samples[0]) | Should -BeLessOrEqual 1
    }
}

Describe 'unbuffered USB reader' {
    BeforeEach {
        $script:file = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.bin')
        $bytes = New-Object byte[] (2MB)
        for ($i = 0; $i -lt $bytes.Length; $i += 4096) { $bytes[$i] = [byte]($i / 4096 % 251) }
        [System.IO.File]::WriteAllBytes($file, $bytes)
        $script:block = 512KB
    }

    It 'reads past the end of the file by wrapping, with live byte counts and no error' {
        $reader = New-BenchUsbReader -Path $file -BlockBytes $block
        $reader.Start()
        $deadline = (Get-Date).AddSeconds(15)
        while ($reader.BytesRead -le 5MB -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
        $live = $reader.BytesRead
        $stats = $reader.Stop(5000)
        $live | Should -BeGreaterThan 5MB
        $stats.Error | Should -BeNullOrEmpty
        $stats.Wraps | Should -BeGreaterOrEqual 2
        $stats.BytesRead | Should -BeGreaterOrEqual $live
        ($stats.BytesRead % $block) | Should -Be 0
        $stats.Seconds | Should -BeGreaterThan 0
    }

    It 'stops without an error and a second Stop returns the same totals' {
        $reader = New-BenchUsbReader -Path $file -BlockBytes $block
        $reader.Start()
        Start-Sleep -Milliseconds 100
        $first = $reader.Stop(5000)
        $second = $reader.Stop(5000)
        $first.Error | Should -BeNullOrEmpty
        $second.BytesRead | Should -Be $first.BytesRead
    }

    It 'is unbuffered: a block size that is not sector aligned fails the read' {
        $reader = New-BenchUsbReader -Path $file -BlockBytes 1000
        $reader.Start()
        Start-Sleep -Milliseconds 300
        $stats = $reader.Stop(5000)
        $stats.Error | Should -Not -BeNullOrEmpty
        $stats.BytesRead | Should -Be 0
    }

    It 'throws from Start when the file cannot be opened' {
        $reader = New-BenchUsbReader -Path (Join-Path $TestDrive 'nowhere.bin') -BlockBytes $block
        { $reader.Start() } | Should -Throw '*cannot open*nowhere.bin*'
    }

    It 'reports an empty file as an error instead of spinning' {
        $empty = Join-Path $TestDrive 'empty.bin'
        [System.IO.File]::WriteAllBytes($empty, (New-Object byte[] 0))
        $reader = New-BenchUsbReader -Path $empty -BlockBytes $block
        $reader.Start()
        Start-Sleep -Milliseconds 300
        $stats = $reader.Stop(5000)
        $stats.Error | Should -Match 'empty'
    }
}

Describe 'starting and stopping the background loads' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[string]
        $calls = $script:calls
        $script:readerStats = [pscustomobject]@{ BytesRead = 100MB; Wraps = 3; Seconds = 4.0; Error = $null }
        $stats = $script:readerStats
        $script:readerFails = @{ value = $false }
        $fails = $script:readerFails
        Mock Get-PlaybackDevice { $calls.Add('device'); [pscustomobject]@{ deviceName = 'Speakers'; controllerInstanceId = 'PCI\VEN_8086&DEV_7A50\1' } }.GetNewClosure()
        Mock Start-BenchTonePlayback { param($Wave) $calls.Add("tone-start $($Wave.Length)"); [pscustomobject]@{ Id = 'player' } }.GetNewClosure()
        Mock Stop-BenchTonePlayback { $calls.Add('tone-stop') }.GetNewClosure()
        Mock New-BenchUsbReader {
            param($Path, $BlockBytes)
            $calls.Add("reader-new $Path $BlockBytes")
            $reader = [pscustomobject]@{ Calls = $calls; Stats = $stats; Fails = $fails }
            $reader | Add-Member -MemberType ScriptMethod -Name Start -Value { $this.Calls.Add('reader-start'); if ($this.Fails.value) { throw 'cannot open' } }
            $reader | Add-Member -MemberType ScriptMethod -Name Stop -Value { param($timeout) $this.Calls.Add("reader-stop $timeout"); $this.Stats }
            $reader
        }.GetNewClosure()
    }

    It 'starts only the listed loads, tone first' {
        $handle = Start-BenchBackground -Name @('tone', 'usb-read') -UsbReadFile 'F:\x.bin'
        $calls.ToArray() | Should -Be @('device', "tone-start $(44 + 48000 * 2)", 'reader-new F:\x.bin 65536', 'reader-start')
        $handle | Should -Not -BeNullOrEmpty
    }

    It 'starts nothing it was not asked for' {
        Start-BenchBackground -Name @('tone') | Out-Null
        $calls.ToArray() | Should -Be @('device', "tone-start $(44 + 48000 * 2)")
        $calls.Clear()
        Start-BenchBackground -Name @('usb-read') -UsbReadFile 'F:\x.bin' | Out-Null
        $calls.ToArray() | Should -Be @('reader-new F:\x.bin 65536', 'reader-start')
    }

    It 'stops the tone when the reader fails to start, and rethrows' {
        $fails.value = $true
        { Start-BenchBackground -Name @('tone', 'usb-read') -UsbReadFile 'F:\x.bin' } | Should -Throw '*cannot open*'
        $calls | Should -Contain 'tone-stop'
    }

    It 'returns the record of exactly the loads that ran' {
        $handle = Start-BenchBackground -Name @('tone', 'usb-read') -UsbReadFile 'F:\x.bin'
        $calls.Clear()
        $result = Stop-BenchBackground -Handle $handle
        $calls.ToArray() | Should -Be @('reader-stop 10000', 'tone-stop')
        @($result.Keys) | Should -Be @('tone', 'usbRead')
        @($result.tone.Keys) | Should -Be @('frequencyHz', 'dbfs', 'sampleRate', 'deviceName', 'controllerInstanceId')
        $result.tone.frequencyHz | Should -Be 440
        $result.tone.dbfs | Should -Be -40
        $result.tone.sampleRate | Should -Be 48000
        $result.tone.deviceName | Should -Be 'Speakers'
        $result.tone.Contains('deviceInstanceId') | Should -BeFalse
        $result.tone.controllerInstanceId | Should -Be 'PCI\VEN_8086&DEV_7A50\1'
        @($result.usbRead.Keys) | Should -Be @('bytesRead', 'wraps', 'seconds', 'mibPerSecond', 'blockBytes', 'error')
        $result.usbRead.bytesRead | Should -Be 100MB
        $result.usbRead.wraps | Should -Be 3
        $result.usbRead.seconds | Should -Be 4
        $result.usbRead.mibPerSecond | Should -Be 25
        $result.usbRead.blockBytes | Should -Be 65536
        $result.usbRead.error | Should -BeNullOrEmpty
    }

    It 'omits the loads that did not run from the record' {
        $handle = Start-BenchBackground -Name @('tone')
        @((Stop-BenchBackground -Handle $handle).Keys) | Should -Be @('tone')
        $handle = Start-BenchBackground -Name @('usb-read') -UsbReadFile 'F:\x.bin'
        @((Stop-BenchBackground -Handle $handle).Keys) | Should -Be @('usbRead')
    }

    It 'carries the reader error into the record' {
        $readerStats.Error = 'ReadFile failed'
        $handle = Start-BenchBackground -Name @('usb-read') -UsbReadFile 'F:\x.bin'
        (Stop-BenchBackground -Handle $handle).usbRead.error | Should -Be 'ReadFile failed'
    }

    It 'rejects the run on a reader error and on nothing else' {
        Get-BackgroundRejection -Background ([ordered]@{ usbRead = [ordered]@{ error = 'ReadFile failed' } }) | Should -Match 'ReadFile failed'
        Get-BackgroundRejection -Background ([ordered]@{ usbRead = [ordered]@{ error = $null } }) | Should -BeNullOrEmpty
        Get-BackgroundRejection -Background ([ordered]@{ tone = [ordered]@{ frequencyHz = 440 } }) | Should -BeNullOrEmpty
        Get-BackgroundRejection -Background $null | Should -BeNullOrEmpty
    }
}

Describe 'the USB read file check' {
    It 'throws when the file is missing' {
        { Assert-UsbReadFile -Path (Join-Path $TestDrive 'absent.bin') } | Should -Throw '*absent.bin*is missing*'
    }
    It 'throws one byte under the minimum' {
        $file = Join-Path $TestDrive 'small.bin'
        [System.IO.File]::WriteAllBytes($file, (New-Object byte[] 4095))
        { Assert-UsbReadFile -Path $file -MinBytes 4096 } | Should -Throw '*smaller than 4096*'
    }
    It 'accepts a file at the minimum' {
        $file = Join-Path $TestDrive 'ok.bin'
        [System.IO.File]::WriteAllBytes($file, (New-Object byte[] 4096))
        { Assert-UsbReadFile -Path $file -MinBytes 4096 } | Should -Not -Throw
    }
    It 'defaults the minimum to 1 GiB' {
        $file = Join-Path $TestDrive 'default.bin'
        [System.IO.File]::WriteAllBytes($file, (New-Object byte[] 4096))
        { Assert-UsbReadFile -Path $file } | Should -Throw "*smaller than $(1GB)*"
    }
}

Describe 'the playback device record' {
    It 'walks the parents to the first PCI ancestor' {
        Mock Get-ParentInstanceId {
            switch ($InstanceId) {
                'SWD\MMDEVAPI\e' { 'HDAUDIO\FUNC_01\1' }
                'HDAUDIO\FUNC_01\1' { 'PCI\VEN_8086&DEV_7A50\a' }
                'PCI\VEN_8086&DEV_7A50\a' { 'PCI\ROOT\b' }
            }
        }
        Find-PciAncestor -InstanceId 'SWD\MMDEVAPI\e' | Should -Be 'PCI\VEN_8086&DEV_7A50\a'
    }
    It 'returns null when the chain ends before a PCI device' {
        Mock Get-ParentInstanceId { if ($InstanceId -eq 'a') { 'ROOT\b' } }
        Find-PciAncestor -InstanceId 'a' | Should -BeNullOrEmpty
    }
    It 'stops after the depth limit' {
        Mock Get-ParentInstanceId { 'ROOT\loop' }
        Find-PciAncestor -InstanceId 'a' | Should -BeNullOrEmpty
        Should -Invoke Get-ParentInstanceId -Exactly 8
    }
    It 'builds the endpoint instance ID for the controller lookup and returns no endpoint ID' {
        Mock Get-DefaultPlaybackEndpointId { '{0.0.0.00000000}.{abc}' }
        Mock Get-PnpDevice { [pscustomobject]@{ FriendlyName = 'Speakers (Realtek)' } }
        Mock Get-ParentInstanceId { 'PCI\VEN_8086&DEV_7A50\a' }
        $device = Get-PlaybackDevice
        $device.deviceName | Should -Be 'Speakers (Realtek)'
        $device.PSObject.Properties.Name | Should -Not -Contain 'deviceInstanceId'
        $device.controllerInstanceId | Should -Be 'PCI\VEN_8086&DEV_7A50\a'
        Should -Invoke Get-ParentInstanceId -ParameterFilter { $InstanceId -eq 'SWD\MMDEVAPI\{0.0.0.00000000}.{abc}' }
    }
}

Describe 'per-process CPU in the capture window' {
    BeforeAll {
        function New-Snap { param([int]$Id, [string]$Name, [double]$Seconds) [pscustomobject]@{ id = $Id; name = $Name; seconds = $Seconds } }
    }
    It 'keeps a delta at the minimum and drops one just under it' {
        $before = @((New-Snap 1 'at' 0), (New-Snap 2 'under' 0))
        $after = @((New-Snap 1 'at' 0.05), (New-Snap 2 'under' 0.049))
        $rows = @(Get-ProcessCpuDelta -Before $before -After $after)
        $rows.Count | Should -Be 1
        $rows[0].name | Should -Be 'at'
        $rows[0].cpuSeconds | Should -Be 0.05
    }
    It 'sorts descending and writes name, pid and cpuSeconds' {
        $before = @((New-Snap 1 'small' 0), (New-Snap 2 'big' 0))
        $after = @((New-Snap 1 'small' 0.5), (New-Snap 2 'big' 3.25))
        $rows = @(Get-ProcessCpuDelta -Before $before -After $after)
        @($rows.name) | Should -Be @('big', 'small')
        $rows[0].pid | Should -Be 2
        $rows[0].cpuSeconds | Should -Be 3.25
        @($rows[0].PSObject.Properties.Name) | Should -Be @('name', 'pid', 'cpuSeconds')
    }
    It 'counts a process born inside the window in full' {
        $rows = @(Get-ProcessCpuDelta -Before @() -After @((New-Snap 9 'new' 1.5)))
        $rows[0].cpuSeconds | Should -Be 1.5
    }
    It 'does not subtract a different process that reused the PID' {
        $rows = @(Get-ProcessCpuDelta -Before @((New-Snap 5 'old' 100)) -After @((New-Snap 5 'other' 2)))
        $rows[0].cpuSeconds | Should -Be 2
    }
    It 'returns an empty list when nothing used CPU' {
        @(Get-ProcessCpuDelta -Before @((New-Snap 1 'a' 1)) -After @((New-Snap 1 'a' 1))).Count | Should -Be 0
    }
}

Describe 'the processCpu result field' {
    BeforeAll {
        $script:before = @([pscustomobject]@{ id = 5; name = 'a'; seconds = 1.0 })
        $script:after = @([pscustomobject]@{ id = 5; name = 'a'; seconds = 3.0 })
    }
    It 'leaves the field out without -ProcessCpu' {
        $result = [ordered]@{ phase = 'x' }
        Add-ProcessCpuField -Result $result -Before $script:before -After $script:after
        $result.Contains('processCpu') | Should -BeFalse
    }
    It 'adds the field with -ProcessCpu' {
        $result = [ordered]@{ phase = 'x' }
        Add-ProcessCpuField -Result $result -ProcessCpu -Before $script:before -After $script:after
        $result.Contains('processCpu') | Should -BeTrue
        @($result.processCpu).Count | Should -Be 1
    }
}

Describe 'system CPU in the capture window' {
    BeforeAll {
        function New-Times { param([long]$Idle, [long]$Kernel, [long]$User) [pscustomobject]@{ idle = $Idle; kernel = $Kernel; user = $User } }
    }
    It 'counts kernel minus idle plus user as busy, as a delta over all CPUs' {
        $before = New-Times 1000000000 1200000000 300000000
        $after = New-Times 1600000000 2100000000 500000000
        $row = Get-SystemCpuDelta -Before $before -After $after -WindowSeconds 10.1234 -LogicalCpus 8
        $row.idle | Should -BeNullOrEmpty
        $row.idleSeconds | Should -Be 60
        $row.busySeconds | Should -Be 50
        $row.windowSeconds | Should -Be 10.123
        $row.logicalCpus | Should -Be 8
        @($row.Keys) | Should -Be @('windowSeconds', 'busySeconds', 'idleSeconds', 'logicalCpus')
    }
    It 'reports zero busy time for an idle system' {
        $row = Get-SystemCpuDelta -Before (New-Times 0 0 0) -After (New-Times 100000000 100000000 0) -WindowSeconds 1 -LogicalCpus 1
        $row.busySeconds | Should -Be 0
        $row.idleSeconds | Should -Be 10
    }
    It 'reads three increasing counters from the OS' {
        $first = Get-SystemCpuSnapshot
        $second = Get-SystemCpuSnapshot
        $second.kernel | Should -BeGreaterOrEqual $first.kernel
        $first.user | Should -BeGreaterThan 0
    }
}

Describe 'the order around the capture window' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[string]
        $calls = $script:calls
        Mock Stop-KernelTrace { $calls.Add('trace-stop') }.GetNewClosure()
        Mock Get-ProcessCpuSnapshot { $calls.Add('cpu-after') }.GetNewClosure()
        Mock Get-SystemCpuSnapshot { $calls.Add('system-after'); [pscustomobject]@{ idle = 1; kernel = 2; user = 3 } }.GetNewClosure()
        $watch = [pscustomobject]@{}
        $watch | Add-Member -MemberType ScriptProperty -Name Elapsed -Value { $calls.Add('watch-read'); [timespan]::FromSeconds(7.5) }.GetNewClosure()
        $script:watch = $watch
        Mock Stop-BenchBackground { $calls.Add('background-stop'); [ordered]@{ tone = 1 } }.GetNewClosure()
        Mock Wait-LoadStart { $calls.Add('load-wait'); [pscustomobject]@{ Id = 1 } }.GetNewClosure()
        Mock Start-BenchBackground { $calls.Add('background-start'); [pscustomobject]@{ h = 1 } }.GetNewClosure()
        Mock Write-Host { $calls.Add('message') }.GetNewClosure()
        Mock Start-Sleep { param($Seconds) $calls.Add("sleep $Seconds") }.GetNewClosure()
    }
    It 'reads the window stopwatch right after the trace stop, before any snapshot or the background stop' {
        $window = Stop-CaptureWindow -Trace $true -Watch $script:watch -Background ([pscustomobject]@{ h = 1 }) -ProcessCpu
        $calls.ToArray() | Should -Be @('trace-stop', 'watch-read', 'system-after', 'cpu-after', 'background-stop')
        $window.Seconds | Should -Be 7.5
        $window.Background.tone | Should -Be 1
    }
    It 'skips the trace stop without a trace and the background stop without a background' {
        $window = Stop-CaptureWindow -Trace $false -Watch $script:watch -Background $null -ProcessCpu
        $calls.ToArray() | Should -Be @('watch-read', 'system-after', 'cpu-after')
        $window.Background | Should -BeNullOrEmpty
    }
    It 'takes no process snapshot without -ProcessCpu' {
        $window = Stop-CaptureWindow -Trace $false -Watch $script:watch -Background $null
        $calls.ToArray() | Should -Be @('watch-read', 'system-after')
        @($window.ProcessCpuAfter).Count | Should -Be 0
    }
    It 'starts the background after the load starts and before the load pause' {
        $recipe = [pscustomobject]@{ timings = [pscustomobject]@{ loadPauseSeconds = 20; captureSeconds = 60 } }
        $started = Start-LoadWithBackground -Recipe $recipe -Background @('tone') -UsbReadFile ''
        $calls.ToArray() | Should -Be @('load-wait', 'background-start', 'message', 'sleep 20')
        $started.Background.h | Should -Be 1
    }
    It 'starts no background when none is asked for' {
        $recipe = [pscustomobject]@{ timings = [pscustomobject]@{ loadPauseSeconds = 20; captureSeconds = 60 } }
        $started = Start-LoadWithBackground -Recipe $recipe
        $calls.ToArray() | Should -Be @('load-wait', 'message', 'sleep 20')
        $started.Background | Should -BeNullOrEmpty
    }
    It 'stops the background when the load pause is interrupted' {
        $recipe = [pscustomobject]@{ timings = [pscustomobject]@{ loadPauseSeconds = 20; captureSeconds = 60 } }
        Mock Start-Sleep { throw 'interrupted' }
        { Start-LoadWithBackground -Recipe $recipe -Background @('tone') -UsbReadFile '' } | Should -Throw 'interrupted'
        Should -Invoke Stop-BenchBackground -Times 1 -Exactly
    }
    It 'stops the background when the kernel trace cannot start' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:benchScript, [ref]$tokens, [ref]$errors)
        $guard = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -like '*InvocationName*' }, $true)
        $body = (@($guard.Clauses[0].Item2.Statements | ForEach-Object { $_.Extent.Text }) -join "`n")
        $body = $body.Replace('$PSCommandPath', '$script:benchScript')
        Mock Assert-LoadArgument {}
        Mock Add-Type {}
        Mock Get-LoadRecipe { [pscustomobject]@{ title = 'x'; consoleLine = $null; timings = [pscustomobject]@{ captureSeconds = 10 }; presentMon = [pscustomobject]@{ version = '1' } } }
        Mock Get-BenchMetadata { @{} }
        Mock Get-InterruptTable { @() }
        Mock Start-LoadWithBackground { [pscustomobject]@{ Process = 1; Background = [pscustomobject]@{ h = 1 } } }
        Mock Get-LoadRecord { @{} }
        Mock Start-KernelTrace { throw 'session held' }
        $run = [scriptblock]::Create('param($OutDir, $Load, $Background, $Device, $SkipTrace, $isAdmin)' + "`n" + $body)
        { & $run -OutDir $TestDrive -Load 'x' -Background @('tone') -Device @() -SkipTrace $false -isAdmin $true } | Should -Throw 'session held'
        Should -Invoke Stop-BenchBackground -Times 1 -Exactly
    }
    It 'decodes the trace only after the capture window is stopped' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:benchScript, [ref]$tokens, [ref]$errors)
        $names = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        $stop = [array]::LastIndexOf($names, 'Stop-CaptureWindow')
        $stop | Should -BeGreaterThan 0
        [array]::LastIndexOf($names, 'Read-KernelTrace') | Should -BeGreaterThan $stop
    }
}

Describe 'Get-DriverRow' {
    BeforeAll {
        $path = Join-Path $TestDrive 'rows.csv'
        Write-TraceCsv -Path $path
        $script:rowTrace = [KernelCsv]::Parse($path)
    }
    It 'totals the ISR durations' {
        $stat = $script:rowTrace.Stats['drv.sys']
        $row = Get-DriverRow -Stat $stat
        $row.isrTotalUs | Should -Be (($stat.IsrUs | Measure-Object -Sum).Sum)
        $row.isrTotalUs | Should -Be 11
    }
    It 'totals the DPC durations' {
        $stat = $script:rowTrace.Stats['other.sys']
        $row = Get-DriverRow -Stat $stat
        $row.dpcTotalUs | Should -Be (($stat.DpcUs | Measure-Object -Sum).Sum)
        $row.dpcTotalUs | Should -Be 12
    }
    It 'reports zero totals for a driver without routines' {
        $row = Get-DriverRow -Stat (New-Object DriverStat)
        $row.isrTotalUs | Should -Be 0
        $row.dpcTotalUs | Should -Be 0
    }
}
