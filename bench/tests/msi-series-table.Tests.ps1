BeforeAll {
    $script:tool = Join-Path $PSScriptRoot '..\tools\Get-MsiSeriesTable.ps1'
    . $script:tool -SeriesPath 'unit-test'

    $script:audioOne = 'PCI\VEN_AAAA&DEV_0001\1'
    $script:audioTwo = 'PCI\VEN_AAAA&DEV_0002\2'

    function New-DriverRow {
        param([string]$Name, [double]$IsrUs, [double]$DpcUs, [int]$Cpu = 2)
        [ordered]@{
            driver = $Name; isrPlain = 100; isrMessage = 0; isrPerCpu = @([ordered]@{ cpu = $Cpu; isr = 100 })
            vectors = ''; isrMaxUs = 9; isrMeanUs = 1.5; isrTotalUs = $IsrUs
            dpcCount = 200; dpcMaxUs = 20; dpcP99Us = 9; dpcMeanUs = 3; dpcTotalUs = $DpcUs
        }
    }

    function New-DeviceRows {
        param([bool]$OneMsi, [bool]$TwoMsi)
        $rows = @()
        if ($OneMsi) { $rows += [ordered]@{ Device = 'Audio One'; Class = 'System'; MSISupported = 'on'; Mode = 'message-signaled, 1 vector'; SharedWith = '' } }
        if ($TwoMsi) { $rows += [ordered]@{ Device = 'Audio Two'; Class = 'System'; MSISupported = 'on'; Mode = 'message-signaled, 1 vector'; SharedWith = '' } }
        $lineShared = (-not $OneMsi) -and (-not $TwoMsi)
        if (-not $OneMsi) { $rows += [ordered]@{ Device = 'Audio One'; Class = 'System'; MSISupported = 'off'; Mode = 'line IRQ 17'; SharedWith = $(if ($lineShared) { 'Audio Two' } else { '' }) } }
        if (-not $TwoMsi) { $rows += [ordered]@{ Device = 'Audio Two'; Class = 'System'; MSISupported = 'off'; Mode = 'line IRQ 17'; SharedWith = $(if ($lineShared) { 'Audio One' } else { '' }) } }
        $rows += [ordered]@{ Device = 'Other'; Class = 'Net'; MSISupported = 'on'; Mode = 'message-signaled, 4 vectors'; SharedWith = '' }
        $rows
    }

    function New-Series {
        param(
            [string]$Root,
            [string[]]$Layout = @('S', 'M', 'S', 'M'),
            [scriptblock]$Mutate = {},
            [scriptblock]$MutateJournal = {},
            [scriptblock]$MutatePlan = {}
        )
        $null = New-Item -ItemType Directory -Path $Root -Force
        $states = @{
            S = @{ name = 'stock'; one = 0; two = 0; oneShared = @('Audio Two'); twoShared = @('Audio One') }
            M = @{ name = 'mobo-audio-msi'; one = 1; two = 0; oneShared = @(); twoShared = @() }
        }
        $planBoots = foreach ($label in $Layout) {
            [ordered]@{
                label  = $states[$label].name
                states = @([ordered]@{
                        kind = 'msi'; step = 'msi'
                        devices = @(
                            [ordered]@{ instanceId = $script:audioOne; deviceName = 'Audio One'; msiSupported = $states[$label].one; sharedWith = $states[$label].oneShared }
                            [ordered]@{ instanceId = $script:audioTwo; deviceName = 'Audio Two'; msiSupported = $states[$label].two; sharedWith = $states[$label].twoShared }
                        )
                    })
            }
        }
        $plan = [ordered]@{ series = 'fixture'; settleSeconds = 300; background = @('tone', 'usb-read'); toneController = $script:audioOne; boots = @($planBoots) }
        $journal = New-Object System.Collections.Generic.List[object]
        $journal.Add([ordered]@{ event = 'start'; boots = $Layout.Count; services = 2; tasks = 3; startup = 0 })
        for ($boot = 0; $boot -lt $Layout.Count; $boot++) {
            $label = $Layout[$boot]
            $name = ('boot{0:00}-state00' -f $boot)
            $benchName = "msi-bench-$name.json"
            $wrapperName = "$name-msi.json"
            $bench = [ordered]@{
                phase = $name
                devices = @(New-DeviceRows -OneMsi ($states[$label].one -eq 1) -TwoMsi ($states[$label].two -eq 1))
                probes = @(
                    [ordered]@{ cpu = 0; devices = @('dxgkrnl.sys'); gapP50Us = 3 + $boot; gapP99Us = 300; gapP999Us = 600; stalledPct = 5 + $boot }
                    [ordered]@{ cpu = 1; devices = @('HDAudBus.sys', 'Wdf01000.sys'); gapP50Us = 4; gapP99Us = 20; gapP999Us = 700; stalledPct = 6 }
                )
                trace = [ordered]@{
                    seconds = 10
                    drivers = @(
                        (New-DriverRow 'loud.sys' (4000 + 1000 * $boot) 1000)
                        (New-DriverRow 'edge.sys' 4000 1000)
                        (New-DriverRow 'quiet.sys' 3000 1999)
                        (New-DriverRow 'HDAudBus.sys' 1000 1000)
                    )
                }
                frames = [ordered]@{
                    avgFps = 100 + 10 * $boot; p50Ms = 8; low1PctMs = 9; low01PctMs = 10; gpuBusyP50Ms = 7; cpuBusyP50Ms = 6
                    presentModes = @('Hardware: Independent Flip'); refreshHz = 180
                }
                background = [ordered]@{
                    tone = [ordered]@{ frequencyHz = 440; controllerInstanceId = $script:audioOne }
                    usbRead = [ordered]@{ bytes = 1; mibPerSecond = 150 + $boot; error = $null }
                }
                load = [ordered]@{ name = 'superposition'; build = '1.1'; videoConfig = [ordered]@{ found = $true; mismatchedKeys = @() } }
                presentMon = [ordered]@{ sha256 = 'bbbb'; overflowedPresents = 0 }
                rejected = ''
                metadata = [ordered]@{
                    os = [ordered]@{ build = '26300'; displayVersion = 'X'; ubr = 100 }
                    power = [ordered]@{
                        schemeGuid = 'scheme-1'
                        processorSettings = @([ordered]@{ guid = 'g1'; ac = 5; dc = 6 }, [ordered]@{ guid = 'g2'; ac = 7; dc = 8 })
                    }
                    presentMonVersion = '2.6.0'
                    benchScript = [ordered]@{ name = 'msi-bench.ps1'; sha256 = 'aaaa' }
                }
            }
            $wrapper = [ordered]@{
                series = 'fixture'; boot = $boot; stateIndex = 0
                bench = [ordered]@{ exitCode = 0; resultFile = $benchName; files = @($benchName, "msi-bench-$name-stalls.csv") }
                environment = [ordered]@{
                    cpu = [ordered]@{ name = 'Test CPU' }
                    bios = [ordered]@{ board = 'Test board'; version = '1.0' }
                    hvciEnabled = 0
                    microcodeRaw = '01-02-03'
                    clockFlags = [ordered]@{ useplatformclock = 'not set'; disabledynamictick = 'Yes' }
                    drivers = [ordered]@{
                        gpu = @([ordered]@{ device = 'GPU'; version = '1.2.3' })
                        audio = @([ordered]@{ device = 'Audio'; version = '4.5.6' })
                    }
                    powerExplicit = @([ordered]@{ setting = 'x'; ac = 1 })
                }
            }
            $stalls = @('cpu,offsetMs,gapUs', '0,100.5,1200', '1,200.25,4999.5')
            $ctx = @{ Boot = $boot; Label = $label; Bench = $bench; Wrapper = $wrapper; Stalls = [System.Collections.Generic.List[string]]$stalls }
            & $Mutate $ctx
            ConvertTo-Json -InputObject $ctx.Bench -Depth 12 | Set-Content -LiteralPath (Join-Path $Root $benchName) -Encoding UTF8
            ConvertTo-Json -InputObject $ctx.Wrapper -Depth 12 | Set-Content -LiteralPath (Join-Path $Root $wrapperName) -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $Root "msi-bench-$name-stalls.csv") -Value $ctx.Stalls -Encoding UTF8
            $journal.Add([ordered]@{ event = 'boot'; index = $boot; outcome = 'success'; states = @([ordered]@{ index = 0; kind = 'msi'; status = 'ok'; result = $wrapperName }) })
        }
        $journalList = [System.Collections.Generic.List[object]]$journal
        & $MutateJournal $journalList
        & $MutatePlan $plan
        ConvertTo-Json -InputObject $plan -Depth 12 | Set-Content -LiteralPath (Join-Path $Root 'plan.json') -Encoding UTF8
        $journalList | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 8 -Compress } | Set-Content -LiteralPath (Join-Path $Root 'journal.jsonl') -Encoding UTF8
        $Root
    }

    function Get-State {
        param($Report, [string]$Label)
        $Report.Summary.states | Where-Object { $_.label -eq $Label }
    }
}

Describe 'Get-Median' {
    It 'takes the middle of an odd count' {
        Get-Median -Values @(9, 1, 5) | Should -Be 5
    }
    It 'takes the mean of the two middle values of an even count' {
        Get-Median -Values @(8, 1, 4, 2) | Should -Be 3
    }
    It 'takes the value of a single sample' {
        Get-Median -Values @(7.5) | Should -Be 7.5
    }
    It 'reports min and max next to the median' {
        $spread = Get-Spread -Values @(3, 9, 1, 5)
        $spread.median | Should -Be 4
        $spread.min | Should -Be 1
        $spread.max | Should -Be 9
        $spread.n | Should -Be 4
    }
    It 'formats median [min-max]' {
        Format-Spread (Get-Spread -Values @(100, 120)) | Should -Be '110 [100-120]'
    }
}

Describe 'display rounding is the same in every engine' {
    It 'rounds the double <Value> through decimal' -ForEach @(
        @{ Value = 1.005; Expected = '1' }
        @{ Value = 2.675; Expected = '2.68' }
        @{ Value = 0.285; Expected = '0.28' }
        @{ Value = 1.115; Expected = '1.12' }
        @{ Value = -2.675; Expected = '-2.68' }
    ) {
        Format-Rounded $Value | Should -Be $Expected
    }
    It 'prints a spread whose median is a midpoint: <Expected>' -ForEach @(
        @{ Values = @(2.67, 2.68); Expected = '2.68 [2.67-2.68]' }
        @{ Values = @(1.00, 1.01); Expected = '1 [1-1.01]' }
        @{ Values = @(0.28, 0.29); Expected = '0.28 [0.28-0.29]' }
        @{ Values = @(1.11, 1.12); Expected = '1.12 [1.11-1.12]' }
    ) {
        Format-Spread (Get-Spread -Values $Values) | Should -Be $Expected
    }
    It 'prints the p value midpoint <Value>' -ForEach @(
        @{ Value = 0.0125d; Expected = '0.012' }
        @{ Value = 0.0135d; Expected = '0.014' }
    ) {
        Format-PValue -Value $Value | Should -Be $Expected
    }
    It 'rounds the summary to four digits through decimal' {
        (Get-Spread -Values @(1.00005)).median.ToString($invariant) | Should -Be '1'
        (Get-Spread -Values @(2.00015)).max.ToString($invariant) | Should -Be '2.0002'
    }
}

Describe 'the constants' {
    It 'keeps the driver floor at 0.5 ms/s and the long gap at 5000 us' {
        $driverFloorMsPerSecond | Should -Be 0.5
        $longGapUs | Should -Be 5000
    }
    It 'counts stalls from the same threshold the probe writes the stall file with' {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\msi-bench.ps1') -Raw
        $match = [regex]::Match($text, 'TimelineMinUs\s*=\s*([0-9.]+)')
        $match.Success | Should -BeTrue
        [double]$match.Groups[1].Value | Should -Be $stallFileMinUs
    }
}

Describe 'the report of a clean series' {
    BeforeAll {
        $script:report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'clean'))
    }
    It 'groups the boots by the plan label in plan order' {
        @($report.Summary.states | ForEach-Object { $_.label }) | Should -Be @('stock', 'mobo-audio-msi')
        (Get-State $report 'stock').boots | Should -Be @(0, 2)
        (Get-State $report 'mobo-audio-msi').boots | Should -Be @(1, 3)
    }
    It 'takes the median of an even count of boots for frames' {
        $fps = (Get-State $report 'stock').frames.avgFps
        $fps.median | Should -Be 110
        $fps.min | Should -Be 100
        $fps.max | Should -Be 120
        (Get-State $report 'mobo-audio-msi').frames.avgFps.median | Should -Be 120
    }
    It 'reports the other frame metrics and the CPU busy p50' {
        $frames = (Get-State $report 'stock').frames
        $frames.p50Ms.median | Should -Be 8
        $frames.low1PctMs.median | Should -Be 9
        $frames.low01PctMs.median | Should -Be 10
        $frames.gpuBusyP50Ms.median | Should -Be 7
        $frames.cpuBusyP50Ms.median | Should -Be 6
    }
    It 'computes ms per second as (microseconds / 1000) / window seconds' {
        $loud = (Get-State $report 'stock').drivers | Where-Object { $_.driver -eq 'loud.sys' }
        $loud.metrics.isrMsPerSecond.median | Should -Be 0.5
        $loud.metrics.dpcMsPerSecond.median | Should -Be 0.1
        $loud.metrics.isrPerSecond.median | Should -Be 10
        $loud.metrics.dpcPerSecond.median | Should -Be 20
        $loud.metrics.isrMeanUs.median | Should -Be 1.5
        $loud.metrics.dpcMeanUs.median | Should -Be 3
        $loud.metrics.dpcP99Us.median | Should -Be 9
        $loud.cpu | Should -Be @(2)
    }
    It 'lists a driver whose median total is exactly at the floor' {
        @((Get-State $report 'stock').drivers | ForEach-Object { $_.driver }) | Should -Contain 'edge.sys'
        ((Get-State $report 'stock').drivers | Where-Object { $_.driver -eq 'edge.sys' }).totalMsPerSecond.median | Should -Be $driverFloorMsPerSecond
    }
    It 'leaves out a driver one microsecond under the floor' {
        @((Get-State $report 'stock').drivers | ForEach-Object { $_.driver }) | Should -Not -Contain 'quiet.sys'
        $report.Markdown | Should -Not -Match 'quiet\.sys'
    }
    It 'lists the driver in every state once it passes the floor in any state' {
        $report.Markdown | Should -Match '\| loud\.sys \| stock \|'
        $report.Markdown | Should -Match '\| loud\.sys \| mobo-audio-msi \|'
    }
    It 'reports the probes per CPU' {
        $probe = (Get-State $report 'stock').probes | Where-Object { $_.cpu -eq 0 }
        $probe.stalledPct.median | Should -Be 6
        $probe.gapP50Us.median | Should -Be 4
        $probe.gapP999Us.median | Should -Be 600
        $probe.gapP99Us.median | Should -Be 300
        $probe.devices | Should -Be @('dxgkrnl.sys')
        ((Get-State $report 'stock').probes | Where-Object { $_.cpu -eq 1 }).devices | Should -Be @('HDAudBus.sys', 'Wdf01000.sys')
    }
    It 'counts the rows of the stall file per probe CPU' {
        $probe = (Get-State $report 'stock').probes | Where-Object { $_.cpu -eq 1 }
        $probe.stallCount.median | Should -Be 1
        $probe.stallCount.n | Should -Be 2
    }
    It 'shows the drivers, gap p99 and stall count in the probes table' {
        $report.Markdown | Should -Match '\| State \| Probe CPU \| Drivers on the core \| Stalled \(%\) \| Gap p50 \(us\) \| Gap p99 \(us\) \| Gap p99\.9 \(us\) \| Stalls of 1 ms or more \|'
        $report.Markdown | Should -Match '\| stock \| 1 \| HDAudBus\.sys, Wdf01000\.sys \| 6 \[6-6\] \| 4 \[4-4\] \| 20 \[20-20\] \| 700 \[700-700\] \| 1 \[1-1\] \|'
    }
    It 'places the pre-registered tests between the checks and the frames' {
        $checks = $report.Markdown.IndexOf('## Checks that passed')
        $tests = $report.Markdown.IndexOf('## Pre-registered tests')
        $frames = $report.Markdown.IndexOf('## Frames')
        $tests | Should -BeGreaterThan $checks
        $frames | Should -BeGreaterThan $tests
        @($report.Summary.fileMap | Where-Object { $_.table -eq 'Pre-registered tests' }).Count | Should -Be 1
    }
    It 'lists the runs with a gap of 5 ms or more and their offsets, not the 4999.5 us one' {
        (Get-State $report 'stock').longGapRuns | Should -BeNullOrEmpty
    }
    It 'reports USB MiB/s' {
        (Get-State $report 'stock').usbMiBPerSecond.median | Should -Be 151
    }
    It 'takes the testbed from the data' {
        $report.Summary.testbed['Windows'] | Should -Be 'X build 26300.100'
        $report.Summary.testbed['CPU'] | Should -Be 'Test CPU'
        $report.Summary.testbed['GPU driver'] | Should -Be 'GPU 1.2.3'
        $report.Summary.testbed['Power scheme'] | Should -Be 'scheme-1'
        $report.Summary.testbed['Disabled services'] | Should -Be '2'
        $report.Summary.testbed['Disabled tasks'] | Should -Be '3'
        $report.Summary.testbed['Disabled startup'] | Should -Be '0'
        $report.Summary.testbed['Boots'] | Should -Be '4'
    }
    It 'marks the checks that need the private runner' {
        $driverCheck = $report.Summary.checks | Where-Object { $_.name -like 'GPU and audio driver*' }
        $driverCheck.benchJson | Should -BeFalse
        ($report.Summary.checks | Where-Object { $_.name -like 'OS build*' }).benchJson | Should -BeTrue
        $report.Markdown | Should -Match 'no, needs the private runner'
    }
    It 'omits the system CPU column when no boot records systemCpu' {
        $report.Markdown | Should -Not -Match 'System CPU busy'
        (Get-State $report 'stock').PSObject.Properties['systemCpuBusyPct'] | Should -BeNullOrEmpty
        ($report.Summary.fileMap | Where-Object { $_.table -eq 'Frames' }).fields | Should -Be 'frames.*'
    }
    It 'maps every table to a file' {
        foreach ($table in 'Frames', 'Drivers', 'Probes', 'USB reads') {
            @($report.Summary.fileMap | Where-Object { $_.table -eq $table }).Count | Should -Be 1
        }
        $report.Markdown | Should -Match '## Table to file map'
    }
}

Describe 'the report with an odd count of boots' {
    It 'takes the middle boot' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'odd') -Layout @('S', 'M', 'S', 'M', 'S'))
        $fps = (Get-State $report 'stock').frames.avgFps
        $fps.median | Should -Be 120
        $fps.min | Should -Be 100
        $fps.max | Should -Be 140
    }
}

Describe 'the gap threshold' {
    It 'lists a gap of exactly 5000 us with its offset and leaves 4999.5 us out' {
        $root = New-Series -Root (Join-Path $TestDrive 'gaps') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 2) { $ctx.Stalls.Add('1,3210.5,5000'); $ctx.Stalls.Add('0,3300,6100.25') }
        }
        $report = New-SeriesReport -SeriesPath $root
        $runs = @((Get-State $report 'stock').longGapRuns)
        $runs.Count | Should -Be 1
        $runs[0].boot | Should -Be 2
        @($runs[0].gaps | ForEach-Object { $_.offsetMs }) | Should -Be @(3210.5, 3300)
        @($runs[0].gaps | ForEach-Object { $_.gapUs }) | Should -Be @(5000, 6100.25)
        (Get-State $report 'mobo-audio-msi').longGapRuns | Should -BeNullOrEmpty
        $report.Markdown | Should -Match '1 of 2'
    }
}

Describe 'the driver floor on the median' {
    It 'uses the median of the boots, not one boot' {
        $root = New-Series -Root (Join-Path $TestDrive 'median-floor') -Layout @('S', 'S', 'S') -Mutate {
            param($ctx)
            $row = $ctx.Bench.trace.drivers | Where-Object { $_.driver -eq 'quiet.sys' }
            $row.isrTotalUs = @(1000, 3001, 9000)[$ctx.Boot]
        }
        $report = New-SeriesReport -SeriesPath $root
        $quiet = (Get-State $report 'stock').drivers | Where-Object { $_.driver -eq 'quiet.sys' }
        $quiet | Should -Not -BeNullOrEmpty
        $quiet.totalMsPerSecond.median | Should -Be 0.5
        $quiet.totalMsPerSecond.max | Should -Be 1.0999
    }
}

Describe 'a driver missing from one boot' {
    It 'counts the missing boot as zero' {
        $root = New-Series -Root (Join-Path $TestDrive 'absent') -Layout @('S', 'S', 'S') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 1) { $ctx.Bench.trace.drivers = @($ctx.Bench.trace.drivers | Where-Object { $_.driver -ne 'loud.sys' }) }
        }
        $report = New-SeriesReport -SeriesPath $root
        $loud = (Get-State $report 'stock').drivers | Where-Object { $_.driver -eq 'loud.sys' }
        $loud.totalMsPerSecond.min | Should -Be 0
        $loud.totalMsPerSecond.max | Should -Be 0.7
        $loud.totalMsPerSecond.median | Should -Be 0.5
    }
}

Describe 'the pre-registered tests end to end' {
    BeforeAll {
        $root = New-Series -Root (Join-Path $TestDrive 'tests-e2e') -Layout @('S', 'M', 'S', 'M', 'S', 'M', 'S', 'M', 'S', 'M') -Mutate {
            param($ctx)
            $step = [int][math]::Floor($ctx.Boot / 2)
            $ctx.Bench.probes[0].stalledPct = if ($ctx.Label -eq 'S') { @(5.0, 5.1, 5.2, 5.3, 5.4)[$step] } else { @(6.0, 6.1, 6.2, 6.3, 6.4)[$step] }
        }
        $script:e2e = New-SeriesReport -SeriesPath $root
        $script:e2eTests = @($e2e.Summary.analysis.tests)
    }
    It 'tests the one state against stock in a family of 6' {
        $e2e.Summary.analysis.family | Should -Be 6
        @($e2eTests | ForEach-Object { $_.state } | Sort-Object -Unique) | Should -Be @('mobo-audio-msi')
    }
    It 'reads hurt for the dxgkrnl stall shift after Holm' {
        $test = $e2eTests | Where-Object { $_.metric -eq 'dxgkrnlStalledPct' }
        $test.extreme | Should -Be 2
        $test.permutations | Should -Be 252
        $test.p | Should -Be 0.007937
        $test.pHolm | Should -Be 0.047619
        $test.verdict | Should -Be 'hurt'
        $test.stockCpu | Should -Be @(0)
        $test.stateCpu | Should -Be @(0)
    }
    It 'reads no difference for the tied metrics and cannot show for the 1% low under a GPU-bound load' {
        foreach ($metric in 'dxgkrnlGapP99Us', 'wdf01000StalledPct', 'wdf01000GapP99Us', 'changedDriverMsPerSecond') {
            $test = $e2eTests | Where-Object { $_.metric -eq $metric }
            $test.p | Should -Be 1
            $test.ciLow | Should -Be 0
            $test.ciHigh | Should -Be 0
            $test.verdict | Should -Be 'no difference' -Because $metric
        }
        ($e2eTests | Where-Object { $_.metric -eq 'wdf01000GapP99Us' }).stockCpu | Should -Be @(1)
        ($e2eTests | Where-Object { $_.metric -eq 'changedDriverMsPerSecond' }).drivers | Should -Be @('HDAudBus.sys')
        ($e2eTests | Where-Object { $_.metric -eq 'low1PctMs' }).verdict | Should -Be 'cannot show'
    }
    It 'flags the load from the average fps and keeps the verdicts' {
        $load = $e2e.Summary.analysis.load[0]
        $load.stockMedian | Should -Be 140
        $load.stateMedian | Should -Be 150
        $load.differencePct | Should -Be 7.1429
        $load.differs | Should -BeTrue
        @($e2eTests | Where-Object { -not $_.loadDiffers }).Count | Should -Be 0
    }
    It 'prints the verdict rows and the load table' {
        $e2e.Markdown | Should -Match '\| mobo-audio-msi \| Stalled \(%\), dxgkrnl\.sys core \| 0 / 0 \| 5\.2 \| 6\.2 \| 1 \| 19\.23 \| \[0\.8, 1\.2\] \| \+/-0\.3 \| 0\.048 \| hurt \| load differs \|'
        $e2e.Markdown | Should -Match '\| mobo-audio-msi \| 1% low \(ms\) \| - \| 9 \| 9 \| 0 \| 0 \| \[0, 0\] \| - \| 1 \| cannot show \| load differs \|'
        ($e2eTests | Where-Object { $_.metric -eq 'low1PctMs' }).margin | Should -BeNullOrEmpty
        ($e2eTests | Where-Object { $_.metric -eq 'dxgkrnlStalledPct' }).margin | Should -Be 0.3
        $e2e.Markdown | Should -Match '\| mobo-audio-msi \| 140 \| 150 \| 7\.14 \| differs \|'
        $e2e.Markdown | Should -Match 'Holm-corrected over the 6 tests'
    }
}

Describe 'a stock-only series' {
    It 'runs no test and prints no test section' {
        $root = New-Series -Root (Join-Path $TestDrive 'stock-only') -Layout @('S') -Mutate {
            param($ctx)
            $ctx.Bench.probes = @([ordered]@{ cpu = 0; gapP50Us = 3.8; gapP999Us = 631.9; stalledPct = 1.5 })
            $ctx.Bench.trace.drivers = @($ctx.Bench.trace.drivers | Where-Object { $_.driver -ne 'edge.sys' })
        }
        $report = New-SeriesReport -SeriesPath $root
        $report.Summary.analysis.family | Should -Be 0
        @($report.Summary.analysis.tests).Count | Should -Be 0
        @($report.Summary.analysis.load).Count | Should -Be 0
        $report.Markdown | Should -Not -Match '## Pre-registered tests'
        @($report.Summary.fileMap | Where-Object { $_.table -eq 'Pre-registered tests' }).Count | Should -Be 0
        $report.Markdown | Should -Match '\| stock \| 1 \| 100 \[100-100\] \| 8 \[8-8\] \| 9 \[9-9\] \| 10 \[10-10\] \| 7 \[7-7\] \| 6 \[6-6\] \|'
        $report.Markdown | Should -Match '\| loud\.sys \| stock \| 10 \[10-10\] \|'
        $report.Markdown | Should -Match '\| stock \| 0 of 1 \| - \|'
        $probe = (Get-State $report 'stock').probes[0]
        $probe.gapP99Us | Should -BeNullOrEmpty
        @($probe.devices).Count | Should -Be 0
        $report.Markdown | Should -Match '\| stock \| 0 \| - \| 1\.5 \[1\.5-1\.5\] \| 3\.8 \[3\.8-3\.8\] \| n/a \|'
    }
}

Describe 'the series refusals' {
    It 'refuses a boot with no accepted result' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-none') -MutateJournal { param($j) $j.RemoveAt(3) }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 2 state 0 : expected exactly one accepted result*found 0*'
    }
    It 'refuses a boot with two accepted results' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-two') -MutateJournal { param($j) $j.Add($j[2]) }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 1 state 0 : expected exactly one accepted result*found 2*'
    }
    It 'ignores a failed attempt next to the accepted one' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-failed') -MutateJournal {
            param($j)
            $j.Add([ordered]@{ event = 'boot'; index = 1; outcome = 'failed'; states = @([ordered]@{ index = 0; status = 'failed'; result = 'boot01-state00-msi.json' }) })
        }
        { New-SeriesReport -SeriesPath $root } | Should -Not -Throw
    }
    It 'refuses a boot whose result file is missing' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-nofile')
        Remove-Item -LiteralPath (Join-Path $root 'boot01-state00-msi.json')
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 1 wrapper*is missing*'
    }
    It 'refuses a boot whose stall file is missing' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-nostalls')
        Remove-Item -LiteralPath (Join-Path $root 'msi-bench-boot03-state00-stalls.csv')
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 3 stall file is missing*'
    }
    It 'refuses a rejected bench result' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-rejected') -Mutate { param($ctx) if ($ctx.Boot -eq 1) { $ctx.Bench.rejected = 'the USB read failed' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 1 bench field rejected*'
    }
    It 'refuses a device in MSI mode where the state wants a line' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-mode') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 2) { $ctx.Bench.devices = @(New-DeviceRows -OneMsi $true -TwoMsi $false) }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 (stock) device 'Audio One' field Mode*"
    }
    It 'refuses a device on a line where the state wants MSI' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-mode2') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 1) { $ctx.Bench.devices = @(New-DeviceRows -OneMsi $false -TwoMsi $false) }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 (mobo-audio-msi) device 'Audio One' field Mode*"
    }
    It 'refuses a device the plan says is shared when the bench shows it alone' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-alone') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { foreach ($row in $ctx.Bench.devices) { $row.SharedWith = '' } }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 0 (stock) device 'Audio One' field SharedWith is ''*the plan says 'Audio Two'*"
    }
    It 'refuses a device the plan says is alone when the bench shows it shared' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-extra') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 1) { ($ctx.Bench.devices | Where-Object { $_.Device -eq 'Audio Two' }).SharedWith = 'Stranger' }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 (mobo-audio-msi) device 'Audio Two' field SharedWith is 'Stranger'*the plan says ''*"
    }
    It 'refuses a shared line whose partner is not the one the plan names' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-partner') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { ($ctx.Bench.devices | Where-Object { $_.Device -eq 'Audio One' }).SharedWith = 'Stranger' }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 0 (stock) device 'Audio One' field SharedWith is 'Stranger'*the plan says 'Audio Two'*"
    }
    It 'compares the shared names as a sorted set' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-sorted') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { ($ctx.Bench.devices | Where-Object { $_.Device -eq 'Audio One' }).SharedWith = 'Audio Two; Audio Three' }
        } -MutatePlan {
            param($plan)
            $plan.boots[0].states[0].devices[0].sharedWith = @('Audio Two', 'Audio Three')
        }
        { New-SeriesReport -SeriesPath $root } | Should -Not -Throw
    }
    It 'does not check sharing for a device the plan leaves unset' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-unset') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { foreach ($row in $ctx.Bench.devices) { $row.SharedWith = 'Anything' } }
        } -MutatePlan {
            param($plan)
            foreach ($device in $plan.boots[0].states[0].devices) { $device.Remove('sharedWith') }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Not -Throw
    }
    It 'refuses a plan device without a deviceName' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-noname')
        $plan = Get-Content -LiteralPath (Join-Path $root 'plan.json') -Raw | ConvertFrom-Json
        $plan.boots[0].states[0].devices[0].PSObject.Properties.Remove('deviceName')
        ConvertTo-Json -InputObject $plan -Depth 12 | Set-Content -LiteralPath (Join-Path $root 'plan.json') -Encoding UTF8
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 0 (stock) plan device*has no field deviceName*'
    }
    It 'refuses a device name that matches two bench rows' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-dup') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { $ctx.Bench.devices = @($ctx.Bench.devices) + @($ctx.Bench.devices[0]) }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 0 (stock) bench field devices has 2 rows named*"
    }
    It 'refuses a changed OS build' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-build') -Mutate { param($ctx) if ($ctx.Boot -eq 3) { $ctx.Bench.metadata.os.build = '26301' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 3 field metadata.os.build differs from boot 0*"
    }
    It 'refuses a changed UBR' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-ubr') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.metadata.os.ubr = 101 } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field metadata.os.ubr differs*"
    }
    It 'refuses a changed GPU driver version' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-gpu') -Mutate { param($ctx) if ($ctx.Boot -eq 3) { $ctx.Wrapper.environment.drivers.gpu[0].version = '1.2.4' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 3 field environment.drivers.gpu differs*"
    }
    It 'refuses a changed audio driver version' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-audio') -Mutate { param($ctx) if ($ctx.Boot -eq 1) { $ctx.Wrapper.environment.drivers.audio[0].version = '4.5.7' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 field environment.drivers.audio differs*"
    }
    It 'refuses a changed power scheme GUID' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-scheme') -Mutate { param($ctx) if ($ctx.Boot -eq 1) { $ctx.Bench.metadata.power.schemeGuid = 'scheme-2' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 field metadata.power.schemeGuid differs*"
    }
    It 'refuses a changed processor value' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-proc') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.metadata.power.processorSettings[1].dc = 9 } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field metadata.power.processorSettings differs*"
    }
    It 'refuses changed explicit power settings' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-explicit') -Mutate { param($ctx) if ($ctx.Boot -eq 3) { $ctx.Wrapper.environment.powerExplicit[0].ac = 2 } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 3 field environment.powerExplicit differs*"
    }
    It 'refuses explicit power settings that exist in some boots only' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-explicit-some') -Mutate { param($ctx) if ($ctx.Boot -eq 1) { $ctx.Wrapper.environment.Remove('powerExplicit') } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 field environment.powerExplicit differs*"
    }
    It 'accepts a series that records no explicit power settings at all' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-explicit-none') -Mutate { param($ctx) $ctx.Wrapper.environment.Remove('powerExplicit') }
        $report = New-SeriesReport -SeriesPath $root
        ($report.Summary.checks | Where-Object { $_.name -like 'explicit power*' }).status | Should -Be 'not recorded'
    }
    It 'refuses a changed metadata.benchScript.sha256' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-benchscript') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.metadata.benchScript.sha256 = 'cccc' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field metadata.benchScript.sha256 differs from boot 0*"
    }
    It 'refuses a changed metadata.presentMonVersion' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-pmver') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.metadata.presentMonVersion = '2.7.0' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field metadata.presentMonVersion differs from boot 0*"
    }
    It 'refuses a changed presentMon.sha256' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-pmsha') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.presentMon.sha256 = 'dddd' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field presentMon.sha256 differs from boot 0*"
    }
    It 'refuses a changed load.build' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-build') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.load.build = '1.2' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field load.build differs from boot 0*"
    }
    It 'refuses a changed load.videoConfig' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-video') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.load.videoConfig.mismatchedKeys = @('width') } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field load.videoConfig differs from boot 0*"
    }
    It 'refuses a changed frames.refreshHz' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-hz') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.frames.refreshHz = 144 } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field frames.refreshHz differs from boot 0*"
    }
    It 'refuses a changed environment.hvciEnabled' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-hvci') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Wrapper.environment.hvciEnabled = 1 } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field environment.hvciEnabled differs from boot 0*"
    }
    It 'refuses a changed environment.bios.version' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-bios') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Wrapper.environment.bios.version = '1.1' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field environment.bios.version differs from boot 0*"
    }
    It 'refuses a changed environment.microcodeRaw' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-ucode') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Wrapper.environment.microcodeRaw = '01-02-04' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field environment.microcodeRaw differs from boot 0*"
    }
    It 'refuses a changed environment.clockFlags' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-clock') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Wrapper.environment.clockFlags.useplatformclock = 'Yes' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field environment.clockFlags differs from boot 0*"
    }
    It 'refuses a recorded field that is missing in one boot' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-some') -Mutate { param($ctx) if ($ctx.Boot -eq 1) { $ctx.Bench.frames.Remove('refreshHz') } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 field frames.refreshHz differs from boot 0*"
    }
    It 'reports the fields recorded by no boot as not recorded, not as a mismatch' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-fp-none') -Mutate {
            param($ctx)
            $ctx.Bench.metadata.Remove('benchScript'); $ctx.Bench.metadata.Remove('presentMonVersion'); $ctx.Bench.Remove('presentMon')
            $ctx.Bench.load.Remove('build'); $ctx.Bench.load.Remove('videoConfig'); $ctx.Bench.frames.Remove('refreshHz')
            foreach ($key in 'hvciEnabled', 'microcodeRaw', 'clockFlags') { $ctx.Wrapper.environment.Remove($key) }
            $ctx.Wrapper.environment.bios.Remove('version')
        }
        $report = New-SeriesReport -SeriesPath $root
        ($report.Summary.checks | Where-Object { $_.name -like 'bench script*' }).status | Should -Be 'not recorded'
        ($report.Summary.checks | Where-Object { $_.name -like 'HVCI*' }).status | Should -Be 'not recorded'
    }
    It 'passes the fingerprint checks when the fields are recorded' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'r-fp-all'))
        ($report.Summary.checks | Where-Object { $_.name -like 'bench script*' }).status | Should -Be 'passed'
        ($report.Summary.checks | Where-Object { $_.name -like 'HVCI*' }).status | Should -Be 'passed'
    }
    It 'refuses a changed present mode' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-present') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.frames.presentModes = @('Composed: Flip') } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 field frames.presentModes differs*"
    }
    It 'refuses a tone on another controller' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-tone') -Mutate { param($ctx) if ($ctx.Boot -eq 1) { $ctx.Bench.background.tone.controllerInstanceId = $script:audioTwo } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 bench field background.tone.controllerInstanceId is 'PCI\VEN_AAAA&DEV_0002\2'*"
    }
    It 'refuses a missing tone record when the plan lists the tone' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-notone') -Mutate { param($ctx) if ($ctx.Boot -eq 0) { $ctx.Bench.background.Remove('tone') } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 0 has no field background.tone.controllerInstanceId*'
    }
    It 'refuses an empty audio driver list when the plan plays the tone' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-audio-empty') -Mutate { param($ctx) $ctx.Wrapper.environment.drivers.audio = @() }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 0 wrapper field environment.drivers.audio is empty*'
    }
    It 'refuses a missing audio driver list when the plan plays the tone' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-audio-missing') -Mutate { param($ctx) $ctx.Wrapper.environment.drivers.Remove('audio') }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 0 wrapper field environment.drivers.audio is empty*'
    }
    It 'accepts an empty audio driver list when the plan does not play the tone' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-audio-notone') -Mutate { param($ctx) $ctx.Wrapper.environment.drivers.audio = @() } -MutatePlan { param($plan) $plan.background = @('usb-read') }
        { New-SeriesReport -SeriesPath $root } | Should -Not -Throw
    }
    It 'refuses a USB read error' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-usb') -Mutate { param($ctx) if ($ctx.Boot -eq 2) { $ctx.Bench.background.usbRead.error = 'device lost' } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 bench field background.usbRead.error is 'device lost'*"
    }
    It 'refuses a driver row without the routine totals' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-totals') -Mutate { param($ctx) if ($ctx.Boot -eq 0) { $ctx.Bench.trace.drivers[0].Remove('dpcTotalUs') } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 0 driver loud.sys has no field dpcTotalUs*'
    }
}

Describe 'the testbed journal block' {
    It 'prints the start event counts' {
        $root = New-Series -Root (Join-Path $TestDrive 'j-counts') -MutateJournal {
            param($j)
            $j[0] = [ordered]@{ event = 'start'; boots = 4; services = 11; tasks = 2; startup = 0 }
        }
        $testbed = (New-SeriesReport -SeriesPath $root).Summary.testbed
        $testbed['Disabled services'] | Should -Be '11'
        $testbed['Disabled tasks'] | Should -Be '2'
        $testbed['Disabled startup'] | Should -Be '0'
    }
    It 'refuses a start event whose services value is an array of names' {
        $root = New-Series -Root (Join-Path $TestDrive 'j-names') -MutateJournal {
            param($j)
            $j[0] = [ordered]@{ event = 'start'; boots = 4; services = @('svcA', 'svcB'); tasks = 2; startup = 0 }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw
    }
    It 'prints only the counts when the start event carries disabled names' {
        $root = New-Series -Root (Join-Path $TestDrive 'j-both') -MutateJournal {
            param($j)
            $j[0] = [ordered]@{ event = 'start'; boots = 4; services = 9; disabledServices = @('svcA'); tasks = 1; disabledTasks = @([ordered]@{ path = '\'; name = 'taskA' }); startup = 0; disabledStartup = @('startA') }
        }
        $report = New-SeriesReport -SeriesPath $root
        $report.Summary.testbed['Disabled services'] | Should -Be '9'
        $report.Summary.testbed['Disabled tasks'] | Should -Be '1'
        $report.Summary.testbed['Disabled startup'] | Should -Be '0'
        $text = $report.Markdown + ($report.Summary | ConvertTo-Json -Depth 10)
        $text | Should -Not -Match 'svcA|taskA|startA'
    }
}

Describe 'the other drivers on the probe cores' {
    It 'prints the empty line and the section for a clean series' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'co-clean'))
        $report.Markdown | Should -Match '## Other drivers on the probe cores'
        $report.Markdown | Should -Match 'No other driver reached 0\.1% of a probe core\.'
        @($report.Summary.analysis.colocation).Count | Should -Be 0
        $report.Summary.constants.colocationMarginPct | Should -Be 0.1d
    }
    It 'prints the section after the load table and before the frames' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'co-order'))
        $section = $report.Markdown.IndexOf('## Other drivers on the probe cores')
        $section | Should -BeGreaterThan $report.Markdown.IndexOf('## Pre-registered tests')
        $section | Should -BeLessThan $report.Markdown.IndexOf('## Frames')
    }
    It 'names a moved driver in the note, the verdict and the section, and keeps the family' {
        $root = New-Series -Root (Join-Path $TestDrive 'co-moved') -Mutate {
            param($ctx)
            if ($ctx.Label -eq 'M') { $ctx.Bench.trace.drivers = @($ctx.Bench.trace.drivers) + (New-DriverRow 'ndis.sys' 150000 0 -Cpu 0) }
        }
        $report = New-SeriesReport -SeriesPath $root
        $report.Summary.analysis.family | Should -Be 6
        $dx = $report.Summary.analysis.tests | Where-Object { $_.metric -eq 'dxgkrnlStalledPct' }
        $dx.verdict | Should -Be 'cannot tell'
        $dx.colocationNote | Should -Be 'other driver moved on this core: ndis.sys (stock 0, state 1.5 % of the core)'
        $report.Markdown | Should -Match '\| mobo-audio-msi \| Stalled \(%\), dxgkrnl\.sys core \| 0 / 0 \|.* \| cannot tell \| other driver moved on this core: ndis\.sys \(stock 0, state 1\.5 % of the core\); load differs \|'
        $report.Markdown | Should -Match '\| State \| Probe core of \| Driver \| Stock median \(% of the core\) \| State median \| Moved \|'
        $report.Markdown | Should -Match '\| mobo-audio-msi \| dxgkrnl\.sys \| ndis\.sys \| 0 \| 1\.5 \| yes \|'
        $report.Markdown | Should -Not -Match 'No other driver reached'
        ($report.Summary.analysis.tests | Where-Object { $_.metric -eq 'wdf01000StalledPct' }).colocationNote | Should -BeNullOrEmpty
    }
    It 'prints the rule in the verdict sentence' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'co-sentence'))
        $report.Markdown | Should -Match 'cannot tell, whatever its p and interval, when'
    }
    It 'lists the probe-core and ISR fields in the file map' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'co-map'))
        ($report.Summary.fileMap | Where-Object { $_.table -eq 'Pre-registered tests' }).fields | Should -Match 'trace\.drivers\[\]\.isrPlain, trace\.drivers\[\]\.isrMessage, trace\.drivers\[\]\.isrPerCpu'
    }
}

Describe 'the enabled network adapters' {
    It 'prints a testbed row when the wrappers record the count' {
        $root = New-Series -Root (Join-Path $TestDrive 'net-row') -Mutate { param($ctx) $ctx.Wrapper.environment.enabledNetworkAdapters = 0 }
        $report = New-SeriesReport -SeriesPath $root
        $report.Summary.testbed['Enabled physical network adapters'] | Should -Be '0'
        $report.Markdown | Should -Match '\| Enabled physical network adapters \| 0 \|'
    }
    It 'prints no row when no wrapper records it' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'net-none'))
        $report.Summary.testbed.Contains('Enabled physical network adapters') | Should -BeFalse
    }
    It 'refuses a changed environment.enabledNetworkAdapters' {
        $root = New-Series -Root (Join-Path $TestDrive 'net-diff') -Mutate { param($ctx) $ctx.Wrapper.environment.enabledNetworkAdapters = if ($ctx.Boot -eq 2) { 1 } else { 0 } }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 2 field environment.enabledNetworkAdapters differs from boot 0*'
    }
    It 'counts the adapters in the wrapper check' {
        $root = New-Series -Root (Join-Path $TestDrive 'net-check') -Mutate { param($ctx) $ctx.Wrapper.environment.enabledNetworkAdapters = 0 }
        $report = New-SeriesReport -SeriesPath $root
        ($report.Summary.checks | Where-Object { $_.name -like 'HVCI*' }).name | Should -Be 'HVCI, BIOS version, microcode, clock flags and enabled network adapters identical'
        ($report.Summary.checks | Where-Object { $_.name -like 'HVCI*' }).status | Should -Be 'passed'
    }
    It 'passes the wrapper check on a wrapper that records only the adapter count' {
        $root = New-Series -Root (Join-Path $TestDrive 'net-only') -Mutate {
            param($ctx)
            foreach ($key in 'hvciEnabled', 'microcodeRaw', 'clockFlags') { $ctx.Wrapper.environment.Remove($key) }
            $ctx.Wrapper.environment.bios.Remove('version')
            $ctx.Wrapper.environment.enabledNetworkAdapters = 0
        }
        $report = New-SeriesReport -SeriesPath $root
        ($report.Summary.checks | Where-Object { $_.name -like 'HVCI*' }).status | Should -Be 'passed'
    }
}
Describe 'the system CPU column' {
    BeforeAll {
        $root = New-Series -Root (Join-Path $TestDrive 'syscpu') -Mutate {
            param($ctx)
            $ctx.Bench.systemCpu = [ordered]@{ windowSeconds = 10; busySeconds = 4 + $ctx.Boot; idleSeconds = 36 - $ctx.Boot; logicalCpus = 4 }
        }
        $script:cpuReport = New-SeriesReport -SeriesPath $root
    }
    It 'reports busy seconds as a percent of window seconds times logical CPUs' {
        $spread = (Get-State $cpuReport 'stock').systemCpuBusyPct
        $spread.median | Should -Be 12.5
        $spread.min | Should -Be 10
        $spread.max | Should -Be 15
        (Get-State $cpuReport 'mobo-audio-msi').systemCpuBusyPct.median | Should -Be 15
    }
    It 'shows the column in the frames table' {
        $cpuReport.Markdown | Should -Match 'System CPU busy'
        $cpuReport.Markdown | Should -Match '12\.5 \[10-15\]'
        ($cpuReport.Summary.fileMap | Where-Object { $_.table -eq 'Frames' }).fields | Should -Match 'systemCpu'
    }
    It 'refuses a record with no capacity' {
        $root = New-Series -Root (Join-Path $TestDrive 'syscpu-zero') -Mutate {
            param($ctx)
            $ctx.Bench.systemCpu = [ordered]@{ windowSeconds = 10; busySeconds = 1; idleSeconds = 0; logicalCpus = 0 }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*systemCpu has no capacity*'
    }
}

Describe 'the script entry point' {
    It 'writes the markdown and summary.json files with the same numbers' {
        $root = New-Series -Root (Join-Path $TestDrive 'entry')
        $md = Join-Path $TestDrive 'out.md'
        $json = Join-Path $TestDrive 'summary.json'
        & $tool -SeriesPath $root -MarkdownPath $md -SummaryPath $json
        $summary = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        $summary.states[0].frames.avgFps.median | Should -Be 110
        $summary.constants.driverFloorMsPerSecond | Should -Be 0.5
        $summary.constants.referenceState | Should -Be 'stock'
        $summary.constants.margins.cs2.low1PctMs.shareOfStockMedian | Should -Be 0.033
        $summary.analysis.family | Should -Be 6
        ($summary.analysis.tests | Where-Object { $_.metric -eq 'dxgkrnlStalledPct' }).verdict | Should -Be 'cannot tell'
        (Get-Content -LiteralPath $md -Raw) | Should -Match '110 \[100-120\]'
    }
    It 'writes the same summary.json bytes from two separate runs' {
        $root = New-Series -Root (Join-Path $TestDrive 'twice')
        $engine = (Get-Process -Id $PID).Path
        $paths = foreach ($run in 1, 2) {
            $json = Join-Path $TestDrive "twice-$run.json"
            & $engine -NoProfile -ExecutionPolicy Bypass -File $tool -SeriesPath $root -MarkdownPath (Join-Path $TestDrive "twice-$run.md") -SummaryPath $json
            $json
        }
        $first = [System.IO.File]::ReadAllBytes($paths[0])
        $first.Count | Should -BeGreaterThan 0
        [System.Convert]::ToBase64String($first) | Should -Be ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($paths[1])))
    }
    It 'writes the same markdown bytes and summary.json numbers under pwsh and Windows PowerShell on midpoint values' {
        $engines = @('pwsh', 'powershell') | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (@($engines).Count -lt 2) { Set-ItResult -Skipped -Because 'one of the two engines is not installed'; return }
        $root = New-Series -Root (Join-Path $TestDrive 'engines') -Mutate {
            param($ctx)
            $ctx.Bench.probes[0].gapP50Us = @(2.67, 2.67, 2.68, 2.68)[$ctx.Boot]
            $ctx.Bench.probes[0].stalledPct = @(1.00, 1.01, 1.115, 1.12)[$ctx.Boot]
            $ctx.Bench.frames.low1PctMs = @(0.285, 0.29, 0.28, 0.285)[$ctx.Boot]
        }
        $bytes = foreach ($engine in $engines) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($engine.Source)
            $md = Join-Path $TestDrive "engines-$name.md"
            $json = Join-Path $TestDrive "engines-$name.json"
            & $engine.Source -NoProfile -ExecutionPolicy Bypass -File $tool -SeriesPath $root -MarkdownPath $md -SummaryPath $json
            [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($md)) + '|' + ((Get-Content -LiteralPath $json -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress) -replace '(\d)\.0(?=[,}\]])', '$1')
        }
        $bytes[0] | Should -Be $bytes[1]
    }
    It 'keeps the field order of the checks and the file map' {
        $report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'field-order'))
        @($report.Summary.checks[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be @('name', 'source', 'benchJson', 'status')
        @($report.Summary.fileMap[0].PSObject.Properties | ForEach-Object { $_.Name }) | Should -Be @('table', 'files', 'fields', 'runner')
    }
    It 'prints the markdown to stdout without -MarkdownPath' {
        $root = New-Series -Root (Join-Path $TestDrive 'stdout')
        (& $tool -SeriesPath $root) -join "`n" | Should -Match '## Frames'
    }
}
