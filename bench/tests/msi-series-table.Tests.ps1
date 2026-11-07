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
            S = @{ one = 0; two = 0; oneShared = @('Audio Two'); twoShared = @('Audio One') }
            M = @{ one = 1; two = 0; oneShared = @(); twoShared = @() }
        }
        $planBoots = foreach ($label in $Layout) {
            [ordered]@{
                label  = $label
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
                    [ordered]@{ cpu = 0; gapP50Us = 3 + $boot; gapP999Us = 600; stalledPct = 5 + $boot }
                    [ordered]@{ cpu = 1; gapP50Us = 4; gapP999Us = 700; stalledPct = 6 }
                )
                trace = [ordered]@{
                    seconds = 10
                    drivers = @(
                        (New-DriverRow 'loud.sys' (4000 + 1000 * $boot) 1000)
                        (New-DriverRow 'edge.sys' 4000 1000)
                        (New-DriverRow 'quiet.sys' 3000 1999)
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

Describe 'the constants' {
    It 'keeps the driver floor at 0.5 ms/s and the long gap at 5000 us' {
        $driverFloorMsPerSecond | Should -Be 0.5
        $longGapUs | Should -Be 5000
    }
}

Describe 'the report of a clean series' {
    BeforeAll {
        $script:report = New-SeriesReport -SeriesPath (New-Series -Root (Join-Path $TestDrive 'clean'))
    }
    It 'groups the boots by the plan label in plan order' {
        @($report.Summary.states | ForEach-Object { $_.label }) | Should -Be @('S', 'M')
        (Get-State $report 'S').boots | Should -Be @(0, 2)
        (Get-State $report 'M').boots | Should -Be @(1, 3)
    }
    It 'takes the median of an even count of boots for frames' {
        $fps = (Get-State $report 'S').frames.avgFps
        $fps.median | Should -Be 110
        $fps.min | Should -Be 100
        $fps.max | Should -Be 120
        (Get-State $report 'M').frames.avgFps.median | Should -Be 120
    }
    It 'reports the other frame metrics and the CPU busy p50' {
        $frames = (Get-State $report 'S').frames
        $frames.p50Ms.median | Should -Be 8
        $frames.low1PctMs.median | Should -Be 9
        $frames.low01PctMs.median | Should -Be 10
        $frames.gpuBusyP50Ms.median | Should -Be 7
        $frames.cpuBusyP50Ms.median | Should -Be 6
    }
    It 'computes ms per second as (microseconds / 1000) / window seconds' {
        $loud = (Get-State $report 'S').drivers | Where-Object { $_.driver -eq 'loud.sys' }
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
        @((Get-State $report 'S').drivers | ForEach-Object { $_.driver }) | Should -Contain 'edge.sys'
        ((Get-State $report 'S').drivers | Where-Object { $_.driver -eq 'edge.sys' }).totalMsPerSecond.median | Should -Be $driverFloorMsPerSecond
    }
    It 'leaves out a driver one microsecond under the floor' {
        @((Get-State $report 'S').drivers | ForEach-Object { $_.driver }) | Should -Not -Contain 'quiet.sys'
        $report.Markdown | Should -Not -Match 'quiet\.sys'
    }
    It 'lists the driver in every state once it passes the floor in any state' {
        $report.Markdown | Should -Match '\| loud\.sys \| S \|'
        $report.Markdown | Should -Match '\| loud\.sys \| M \|'
    }
    It 'reports the probes per CPU' {
        $probe = (Get-State $report 'S').probes | Where-Object { $_.cpu -eq 0 }
        $probe.stalledPct.median | Should -Be 6
        $probe.gapP50Us.median | Should -Be 4
        $probe.gapP999Us.median | Should -Be 600
    }
    It 'lists the runs with a gap of 5 ms or more and their offsets, not the 4999.5 us one' {
        (Get-State $report 'S').longGapRuns | Should -BeNullOrEmpty
    }
    It 'reports USB MiB/s' {
        (Get-State $report 'S').usbMiBPerSecond.median | Should -Be 151
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
        (Get-State $report 'S').PSObject.Properties['systemCpuBusyPct'] | Should -BeNullOrEmpty
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
        $fps = (Get-State $report 'S').frames.avgFps
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
        $runs = @((Get-State $report 'S').longGapRuns)
        $runs.Count | Should -Be 1
        $runs[0].boot | Should -Be 2
        @($runs[0].gaps | ForEach-Object { $_.offsetMs }) | Should -Be @(3210.5, 3300)
        @($runs[0].gaps | ForEach-Object { $_.gapUs }) | Should -Be @(5000, 6100.25)
        (Get-State $report 'M').longGapRuns | Should -BeNullOrEmpty
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
        $quiet = (Get-State $report 'S').drivers | Where-Object { $_.driver -eq 'quiet.sys' }
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
        $loud = (Get-State $report 'S').drivers | Where-Object { $_.driver -eq 'loud.sys' }
        $loud.totalMsPerSecond.min | Should -Be 0
        $loud.totalMsPerSecond.max | Should -Be 0.7
        $loud.totalMsPerSecond.median | Should -Be 0.5
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
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 2 (S) device 'Audio One' field Mode*"
    }
    It 'refuses a device on a line where the state wants MSI' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-mode2') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 1) { $ctx.Bench.devices = @(New-DeviceRows -OneMsi $false -TwoMsi $false) }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 (M) device 'Audio One' field Mode*"
    }
    It 'refuses a device the plan says is shared when the bench shows it alone' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-alone') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { foreach ($row in $ctx.Bench.devices) { $row.SharedWith = '' } }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 0 (S) device 'Audio One' field SharedWith is ''*the plan says 'Audio Two'*"
    }
    It 'refuses a device the plan says is alone when the bench shows it shared' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-extra') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 1) { ($ctx.Bench.devices | Where-Object { $_.Device -eq 'Audio Two' }).SharedWith = 'Stranger' }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 1 (M) device 'Audio Two' field SharedWith is 'Stranger'*the plan says ''*"
    }
    It 'refuses a shared line whose partner is not the one the plan names' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-partner') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { ($ctx.Bench.devices | Where-Object { $_.Device -eq 'Audio One' }).SharedWith = 'Stranger' }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 0 (S) device 'Audio One' field SharedWith is 'Stranger'*the plan says 'Audio Two'*"
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
        { New-SeriesReport -SeriesPath $root } | Should -Throw '*boot 0 (S) plan device*has no field deviceName*'
    }
    It 'refuses a device name that matches two bench rows' {
        $root = New-Series -Root (Join-Path $TestDrive 'r-dup') -Mutate {
            param($ctx)
            if ($ctx.Boot -eq 0) { $ctx.Bench.devices = @($ctx.Bench.devices) + @($ctx.Bench.devices[0]) }
        }
        { New-SeriesReport -SeriesPath $root } | Should -Throw "*boot 0 (S) bench field devices has 2 rows named*"
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

Describe 'the system CPU column' {
    BeforeAll {
        $root = New-Series -Root (Join-Path $TestDrive 'syscpu') -Mutate {
            param($ctx)
            $ctx.Bench.systemCpu = [ordered]@{ windowSeconds = 10; busySeconds = 4 + $ctx.Boot; idleSeconds = 36 - $ctx.Boot; logicalCpus = 4 }
        }
        $script:cpuReport = New-SeriesReport -SeriesPath $root
    }
    It 'reports busy seconds as a percent of window seconds times logical CPUs' {
        $spread = (Get-State $cpuReport 'S').systemCpuBusyPct
        $spread.median | Should -Be 12.5
        $spread.min | Should -Be 10
        $spread.max | Should -Be 15
        (Get-State $cpuReport 'M').systemCpuBusyPct.median | Should -Be 15
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
        (Get-Content -LiteralPath $md -Raw) | Should -Match '110 \[100-120\]'
    }
    It 'prints the markdown to stdout without -MarkdownPath' {
        $root = New-Series -Root (Join-Path $TestDrive 'stdout')
        (& $tool -SeriesPath $root) -join "`n" | Should -Match '## Frames'
    }
}
