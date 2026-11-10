BeforeAll {
    $script:tool = Join-Path $PSScriptRoot '..\tools\Get-MsiSeriesTable.ps1'
    . $script:tool -SeriesPath 'unit-test'

    function New-Boot {
        param(
            [int]$Boot,
            [string]$Label,
            [double]$DxStalled = 1,
            [double]$DxGap = 100,
            [double]$UsbStalled = 2,
            [double]$UsbGap = 50,
            [int]$DxCpu = 1,
            [int]$UsbCpu = 11,
            [double]$Low1 = 9,
            [double]$AvgFps = 120,
            [System.Collections.IDictionary]$DriverMs = @{},
            [object[]]$Drivers,
            [string]$Load = 'superposition',
            [object[]]$Probes
        )
        if (-not $Probes) {
            $Probes = @(
                [ordered]@{ cpu = $DxCpu; devices = @('dxgkrnl.sys'); stalledPct = $DxStalled; gapP99Us = $DxGap }
                [ordered]@{ cpu = $UsbCpu; devices = @('HDAudBus.sys', 'Wdf01000.sys'); stalledPct = $UsbStalled; gapP99Us = $UsbGap }
            )
        }
        if (-not $Drivers) { $Drivers = @(foreach ($name in $DriverMs.Keys) { [ordered]@{ driver = $name; isrTotalUs = 10000 * $DriverMs[$name]; dpcTotalUs = 0 } }) }
        $bench = [ordered]@{
            probes = @($Probes)
            trace  = [ordered]@{ seconds = 10; drivers = @($Drivers) }
            frames = [ordered]@{ low1PctMs = $Low1; avgFps = $AvgFps }
            load   = [ordered]@{ name = $Load }
        }
        [pscustomobject]@{ Boot = $Boot; Label = $Label; Bench = (ConvertTo-Json -InputObject $bench -Depth 8 | ConvertFrom-Json); Stalls = @() }
    }

    function New-StateBoots {
        param([object[]]$Boots)
        $map = [ordered]@{}
        foreach ($boot in $Boots) {
            if (-not $map.Contains($boot.Label)) { $map[$boot.Label] = @() }
            $map[$boot.Label] += $boot
        }
        $map
    }

    function Invoke-Analysis {
        param([object[]]$Boots)
        $map = New-StateBoots -Boots $Boots
        Get-SeriesAnalysis -Labels @($map.Keys) -StateBoots $map
    }

    function Get-Test {
        param($Analysis, [string]$State, [string]$Metric)
        $Analysis.tests | Where-Object { $_.state -eq $State -and $_.metric -eq $Metric }
    }
}

Describe 'Get-DoubledMidRank' {
    It 'gives tied values the doubled mean of their ranks' {
        Get-DoubledMidRank -Values @(1, 2, 2, 2, 3, 3) | Should -Be @(2, 6, 6, 6, 11, 11)
    }
    It 'ranks a double and a decimal of the same recorded value as a tie' {
        Get-DoubledMidRank -Values @([double]8.95, [decimal]8.95, 9) | Should -Be @(3, 3, 6)
    }
}

Describe 'Get-RankSumTest' {
    It 'gives p = 0.1 for a complete separation of 3 against 3' {
        $test = Get-RankSumTest -Stock @(1, 2, 3) -State @(4, 5, 6)
        $test.rankSum | Should -Be 30
        $test.expected | Should -Be 21
        $test.extreme | Should -Be 2
        $test.permutations | Should -Be 20
        $test.direction | Should -Be 1
    }
    It 'gives the same p with the direction reversed' {
        $test = Get-RankSumTest -Stock @(4, 5, 6) -State @(1, 2, 3)
        $test.rankSum | Should -Be 12
        $test.extreme | Should -Be 2
        $test.direction | Should -Be -1
    }
    It 'counts the subsets of tied ranks exactly' {
        $test = Get-RankSumTest -Stock @(1, 2, 2) -State @(2, 3, 3)
        $test.rankSum | Should -Be 28
        $test.extreme | Should -Be 6
        $test.permutations | Should -Be 20
    }
    It 'gives p = 1 when every value is tied' {
        $test = Get-RankSumTest -Stock @(5, 5, 5) -State @(5, 5, 5)
        $test.extreme | Should -Be 20
        $test.permutations | Should -Be 20
        $test.direction | Should -Be 0
    }
    It 'handles a tie across the groups' {
        $test = Get-RankSumTest -Stock @(10, 11, 12, 13) -State @(12, 14, 15, 16)
        $test.rankSum | Should -Be 49
        $test.expected | Should -Be 36
        $test.extreme | Should -Be 6
        $test.permutations | Should -Be 70
    }
    It 'takes the expected rank sum from the state count when the sizes differ' {
        $test = Get-RankSumTest -Stock @(1, 2, 3, 4, 5) -State @(6, 7)
        $test.rankSum | Should -Be 26
        $test.expected | Should -Be 16
        $test.extreme | Should -Be 2
        $test.permutations | Should -Be 21
    }
    It 'counts 12 against 12 exactly' {
        $test = Get-RankSumTest -Stock @(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) -State @(1..12)
        $test.rankSum | Should -Be 444
        $test.expected | Should -Be 300
        $test.extreme | Should -Be 2
        $test.permutations | Should -Be 2704156
    }
}

Describe 'Get-ShiftEstimate' {
    It 'gives the 3 against 3 interval at exactly 0.9' {
        $shift = Get-ShiftEstimate -Stock @(1, 2, 3) -State @(4, 5, 6)
        $shift.shift | Should -Be 3
        $shift.ciLow | Should -Be 1
        $shift.ciHigh | Should -Be 5
        $shift.ciConfidence | Should -Be 0.9d
    }
    It 'takes the critical index from the no-ties distribution with ties present' {
        $shift = Get-ShiftEstimate -Stock @(10, 11, 12, 13) -State @(12, 14, 15, 16)
        $shift.shift | Should -Be 3
        $shift.ciLow | Should -Be 0
        $shift.ciHigh | Should -Be 5
        [math]::Round($shift.ciConfidence, 4) | Should -Be 0.9429d
    }
    It 'gives k = 43 for 12 against 12' {
        $shift = Get-ShiftEstimate -Stock @(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) -State @(1..12)
        $shift.shift | Should -Be 6.5
        $shift.ciLow | Should -Be 4
        $shift.ciHigh | Should -Be 9
        [math]::Round($shift.ciConfidence, 4) | Should -Be 0.9113d
    }
    It 'gives the 5 against 5 interval' {
        $shift = Get-ShiftEstimate -Stock @(5.0d, 5.1d, 5.2d, 5.3d, 5.4d) -State @(6.0d, 6.1d, 6.2d, 6.3d, 6.4d)
        $shift.shift | Should -Be 1
        $shift.ciLow | Should -Be 0.8d
        $shift.ciHigh | Should -Be 1.2d
        [math]::Round($shift.ciConfidence, 4) | Should -Be 0.9048d
    }
    It 'gives an interval for 5 against 2' {
        $shift = Get-ShiftEstimate -Stock @(1, 2, 3, 4, 5) -State @(6, 7)
        $shift.ciLow | Should -Be 1
        $shift.ciHigh | Should -Be 6
        [math]::Round($shift.ciConfidence, 4) | Should -Be 0.9048d
    }
    It 'gives no interval for 4 against 2' {
        $shift = Get-ShiftEstimate -Stock @(1, 2, 3, 4) -State @(6, 7)
        $shift.ciLow | Should -BeNullOrEmpty
        $shift.ciHigh | Should -BeNullOrEmpty
        $shift.ciConfidence | Should -BeNullOrEmpty
    }
    It 'gives no interval for 2 against 2' {
        $shift = Get-ShiftEstimate -Stock @(1, 2) -State @(3, 4)
        $shift.shift | Should -Be 2
        $shift.ciLow | Should -BeNullOrEmpty
    }
}

Describe 'Get-HolmAdjusted' {
    It 'steps down and keeps the adjusted values monotone' {
        $holm = @(Get-HolmAdjusted -Extreme @(1, 4, 3, 1) -Permutations @(100, 100, 100, 200))
        @($holm | ForEach-Object { $_.pHolm }) | Should -Be @(0.03, 0.06, 0.06, 0.02)
        @($holm | ForEach-Object { $_.significant }) | Should -Be @($true, $false, $false, $true)
    }
    It 'keeps two equal p at 1' {
        $holm = @(Get-HolmAdjusted -Extreme @(1, 1) -Permutations @(2, 2))
        @($holm | ForEach-Object { $_.pHolm }) | Should -Be @(1, 1)
    }
    It 'caps the adjusted value at 1' {
        $holm = @(Get-HolmAdjusted -Extreme @(1, 1, 1) -Permutations @(2, 2, 2))
        @($holm | ForEach-Object { $_.pHolm }) | Should -Be @(1, 1, 1)
    }
    It 'does not call p = 0.05 significant' {
        $holm = @(Get-HolmAdjusted -Extreme @(1) -Permutations @(20))
        $holm[0].pHolm | Should -Be 0.05
        $holm[0].significant | Should -BeFalse
    }
}

Describe 'Get-Verdict' {
    It 'reads hurt for a significant rise and helped for a significant fall' {
        Get-Verdict -Significant $true -Direction 1 -CiLow 1 -CiHigh 2 -Margin 0.3 | Should -Be 'hurt'
        Get-Verdict -Significant $true -Direction -1 -CiLow -2 -CiHigh -1 -Margin 0.3 | Should -Be 'helped'
    }
    It 'keeps helped or hurt when the interval lies inside the margin' {
        Get-Verdict -Significant $true -Direction 1 -CiLow 0.1 -CiHigh 0.2 -Margin 0.3 | Should -Be 'hurt'
        Get-Verdict -Significant $true -Direction -1 -CiLow -0.2 -CiHigh -0.1 -Margin 0.3 | Should -Be 'helped'
    }
    It 'reads no difference when the interval lies strictly inside the margin' {
        Get-Verdict -Significant $false -Direction 1 -CiLow -0.29 -CiHigh 0.29 -Margin 0.3 | Should -Be 'no difference'
    }
    It 'reads cannot tell for an endpoint on the margin, no interval or a crossing interval' {
        Get-Verdict -Significant $false -Direction 1 -CiLow 0 -CiHigh 0.3 -Margin 0.3 | Should -Be 'cannot tell'
        Get-Verdict -Significant $false -Direction 1 -CiLow -0.3 -CiHigh 0 -Margin 0.3 | Should -Be 'cannot tell'
        Get-Verdict -Significant $false -Direction 0 -CiLow $null -CiHigh $null -Margin 0.3 | Should -Be 'cannot tell'
        Get-Verdict -Significant $false -Direction 1 -CiLow -0.1 -CiHigh 0.5 -Margin 0.3 | Should -Be 'cannot tell'
    }
    It 'reads cannot tell for a zero margin' {
        Get-Verdict -Significant $false -Direction 0 -CiLow 0 -CiHigh 0 -Margin 0 | Should -Be 'cannot tell'
    }
    It 'reads cannot show instead of no difference or cannot tell where the load cannot show it' {
        Get-Verdict -Significant $false -Direction 1 -CiLow -0.1 -CiHigh 0.1 -Margin 0.3 -CannotShow | Should -Be 'cannot show'
        Get-Verdict -Significant $false -Direction 1 -CiLow $null -CiHigh $null -Margin 0.3 -CannotShow | Should -Be 'cannot show'
        Get-Verdict -Significant $true -Direction 1 -CiLow 1 -CiHigh 2 -Margin 0.3 -CannotShow | Should -Be 'hurt'
    }
}

Describe 'the margins in decimal' {
    It 'does not read 8.65 against 8.95 as inside +/-0.3' {
        $shift = Get-ShiftEstimate -Stock @(8.65d, 8.65d, 8.65d) -State @(8.95d, 8.95d, 8.95d)
        $shift.ciLow | Should -Be 0.3d
        $shift.ciHigh | Should -Be 0.3d
        Get-Verdict -Significant $false -Direction 1 -CiLow $shift.ciLow -CiHigh $shift.ciHigh -Margin (Get-MetricMargin -Rule $marginRules.superposition.stalledPct -StockMedian 8.65d) | Should -Be 'cannot tell'
    }
    It 'puts 10% of a 654 us stock median between 719.3 and 719.4' {
        $margin = Get-MetricMargin -Rule $marginRules.superposition.gapP99Us -StockMedian 654d
        $margin | Should -Be 65.4d
        $inside = Get-ShiftEstimate -Stock @(654, 654, 654) -State @(719.3d, 719.3d, 719.3d)
        Get-Verdict -Significant $false -Direction 1 -CiLow $inside.ciLow -CiHigh $inside.ciHigh -Margin $margin | Should -Be 'no difference'
        $edge = Get-ShiftEstimate -Stock @(654, 654, 654) -State @(719.4d, 719.4d, 719.4d)
        Get-Verdict -Significant $false -Direction 1 -CiLow $edge.ciLow -CiHigh $edge.ciHigh -Margin $margin | Should -Be 'cannot tell'
    }
    It 'takes 3.3% of the stock median as the cs2 1% low margin' {
        Get-MetricMargin -Rule $marginRules.cs2.low1PctMs -StockMedian 10 | Should -Be 0.33d
    }
}

Describe 'Get-LoadCheck' {
    It 'does not flag exactly 1%' {
        $load = Get-LoadCheck -Stock @([double]120, [double]120, [double]120) -State @(121.2d, 121.2d, 121.2d)
        $load.differs | Should -BeFalse
        $load.differencePct | Should -Be 1
    }
    It 'flags more than 1% either way' {
        (Get-LoadCheck -Stock @(120, 120) -State @(121.3d, 121.3d)).differs | Should -BeTrue
        (Get-LoadCheck -Stock @(120, 120) -State @(118.7d, 118.7d)).differs | Should -BeTrue
    }
    It 'gives no percentage for a zero stock median' {
        $load = Get-LoadCheck -Stock @(0, 0) -State @(1, 1)
        $load.differencePct | Should -BeNullOrEmpty
    }
    It 'measures the 1% against the stock median' {
        (Get-LoadCheck -Stock @(100, 100) -State @(101.005d, 101.005d)).differs | Should -BeTrue
    }
    It 'compares medians, not means' {
        $load = Get-LoadCheck -Stock @(100, 100, 130) -State @(100, 100, 100)
        $load.stockMedian | Should -Be 100
        $load.differs | Should -BeFalse
    }
}

Describe 'Format-PValue' {
    It 'prints three decimals or a floor' {
        Format-PValue -Value 0.047619 | Should -Be '0.048'
        Format-PValue -Value 0.0009 | Should -Be '< 0.001'
        Format-PValue -Value 1 | Should -Be '1'
        Format-PValue -Value 0.05 | Should -Be '0.05'
    }
    It 'prints a p of exactly 0.001 as 0.001, not under the floor' {
        Format-PValue -Value 0.001d | Should -Be '0.001'
    }
    It 'adds digits where three would round a p under alpha up to alpha' {
        Format-PValue -Value 0.049759 | Should -Be '0.0498'
        Format-PValue -Value 0.0499996 | Should -Be '0.049999'
    }
}

Describe 'the printed zero' {
    It 'prints a zero shift without a sign' {
        $shift = (Get-ShiftEstimate -Stock @(1, 2) -State @(0.9d, 2.1d)).shift
        $shift | Should -Be 0
        Format-Rounded $shift | Should -Be '0'
        (ConvertTo-OutputNumber $shift).ToString($invariant) | Should -Be '0'
    }
    It 'prints a value that rounds to zero without a sign' {
        Format-Rounded -0.004 | Should -Be '0'
        (ConvertTo-OutputNumber -0.00001).ToString($invariant) | Should -Be '0'
    }
}

Describe 'Get-SeriesAnalysis' {
    It 'reads the dxgkrnl and Wdf01000 metrics from the probe whose devices list the driver' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock'
            New-Boot -Boot 1 -Label 'audio-msi' -Probes @(
                [ordered]@{ cpu = 1; devices = @('dxgkrnl.sys', 'HDAudBus.sys'); stalledPct = 3; gapP99Us = 300 }
                [ordered]@{ cpu = 11; devices = @('WDF01000.SYS'); stalledPct = 4; gapP99Us = 40 }
            )
        )
        $analysis = Invoke-Analysis -Boots $boots
        $usb = Get-Test $analysis 'audio-msi' 'wdf01000StalledPct'
        $usb.stockCpu | Should -Be @(11)
        $usb.stateCpu | Should -Be @(11)
        $usb.stockValues | Should -Be @(2)
        $usb.stateValues | Should -Be @(4)
        $usb.coreNote | Should -BeNullOrEmpty
        $usbGap = Get-Test $analysis 'audio-msi' 'wdf01000GapP99Us'
        $usbGap.stockValues | Should -Be @(50)
        $usbGap.stateValues | Should -Be @(40)
        $usbGap.stateCpu | Should -Be @(11)
        $dx = Get-Test $analysis 'audio-msi' 'dxgkrnlGapP99Us'
        $dx.stockCpu | Should -Be @(1)
        $dx.stateCpu | Should -Be @(1)
        $dx.stateValues | Should -Be @(300)
        (Get-Test $analysis 'audio-msi' 'low1PctMs').stockCpu | Should -BeNullOrEmpty
    }
    It 'notes the boots whose probe core differs' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock'
            New-Boot -Boot 1 -Label 'usb-line'
            New-Boot -Boot 2 -Label 'stock' -UsbCpu 7
            New-Boot -Boot 3 -Label 'usb-line'
        )
        $test = Get-Test (Invoke-Analysis -Boots $boots) 'usb-line' 'wdf01000GapP99Us'
        $test.stockCpu | Should -Be @(7, 11)
        $test.stateCpu | Should -Be @(11)
        $test.coreNote | Should -Be 'stock: CPU 7 (boot 2), CPU 11 (boot 0); usb-line: CPU 11 (boots 1, 3)'
    }
    It 'notes a core that differs between stock and the state' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock'
            New-Boot -Boot 1 -Label 'gpu-line' -DxCpu 2
        )
        (Get-Test (Invoke-Analysis -Boots $boots) 'gpu-line' 'dxgkrnlStalledPct').coreNote | Should -Be 'stock: CPU 1 (boot 0); gpu-line: CPU 2 (boot 1)'
    }
    It 'refuses a boot without a probe listing the driver' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock'
            New-Boot -Boot 1 -Label 'usb-line' -Probes @([ordered]@{ cpu = 1; devices = @('dxgkrnl.sys'); stalledPct = 3; gapP99Us = 300 })
        )
        { Invoke-Analysis -Boots $boots } | Should -Throw '*boot 1 has 0 probes listing Wdf01000.sys, expected 1*'
    }
    It 'refuses a boot with two probes listing the driver' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock' -Probes @(
                [ordered]@{ cpu = 1; devices = @('dxgkrnl.sys', 'Wdf01000.sys'); stalledPct = 3; gapP99Us = 300 }
                [ordered]@{ cpu = 11; devices = @('Wdf01000.sys'); stalledPct = 4; gapP99Us = 40 }
            )
            New-Boot -Boot 1 -Label 'usb-line'
        )
        { Invoke-Analysis -Boots $boots } | Should -Throw '*boot 0 has 2 probes listing Wdf01000.sys, expected 1*'
    }
    It 'tests the per-boot sum of both gpu-line drivers, not the sum of their medians' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock' -DriverMs @{ 'dxgkrnl.sys' = 1; 'amdkmdag.sys' = 1 }
            New-Boot -Boot 1 -Label 'gpu-line' -DriverMs @{ 'dxgkrnl.sys' = 1; 'amdkmdag.sys' = 9 }
            New-Boot -Boot 2 -Label 'gpu-line' -DriverMs @{ 'dxgkrnl.sys' = 2; 'amdkmdag.sys' = 2 }
            New-Boot -Boot 3 -Label 'gpu-line' -DriverMs @{ 'dxgkrnl.sys' = 9; 'amdkmdag.sys' = 1 }
        )
        $test = Get-Test (Invoke-Analysis -Boots $boots) 'gpu-line' 'changedDriverMsPerSecond'
        $test.drivers | Should -Be @('dxgkrnl.sys', 'amdkmdag.sys')
        $test.stateValues | Should -Be @(10, 4, 10)
        $test.stateMedian | Should -Be 10
        $test.stockValues | Should -Be @(2)
    }
    It 'counts a driver missing from a boot as zero' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock' -DriverMs @{ 'dxgkrnl.sys' = 1 }
            New-Boot -Boot 1 -Label 'gpu-line' -DriverMs @{ 'dxgkrnl.sys' = 3; 'amdkmdag.sys' = 2 }
        )
        (Get-Test (Invoke-Analysis -Boots $boots) 'gpu-line' 'changedDriverMsPerSecond').stockValues | Should -Be @(1)
    }
    It 'computes the changed-driver ms/s in decimal from the routine totals' {
        $boot = New-Boot -Boot 0 -Label 'stock'
        $boot.Bench.trace = [pscustomobject]@{ seconds = [double]60.3; drivers = @([pscustomobject]@{ driver = 'HDAudBus.sys'; isrTotalUs = [double]12000.1; dpcTotalUs = [double]0.2 }) }
        (Get-DriverMetric -Boot $boot -Driver 'HDAudBus.sys').isrDpcMsPerSecond | Should -Be (12000.3d / 1000 / 60.3d)
        (Get-DriverMetric -Boot $boot -Driver 'missing.sys').isrDpcMsPerSecond | Should -Be 0
    }
    It 'sizes the family from the labels: 12 for the CS2 shape' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock' -Load 'cs2'
            New-Boot -Boot 1 -Label 'gpu-audio-msi' -Load 'cs2'
            New-Boot -Boot 2 -Label 'gpu-line' -Load 'cs2'
        )
        $analysis = Invoke-Analysis -Boots $boots
        $analysis.family | Should -Be 12
        @($analysis.tests).Count | Should -Be 12
        @($analysis.tests | Where-Object { $_.state -eq 'gpu-audio-msi' } | ForEach-Object { $_.metric }) | Should -Be @($testMetrics | ForEach-Object { $_.key })
        (Get-Test $analysis 'gpu-audio-msi' 'changedDriverMsPerSecond').drivers | Should -Be @('HDAudBus.sys')
        @($analysis.load | ForEach-Object { $_.state }) | Should -Be @('gpu-audio-msi', 'gpu-line')
    }
    It 'refuses a series without a stock state' {
        { Invoke-Analysis -Boots @((New-Boot -Boot 0 -Label 'audio-msi'), (New-Boot -Boot 1 -Label 'gpu-line')) } | Should -Throw '*no stock state*'
    }
    It 'refuses a state without a changed-driver entry' {
        { Invoke-Analysis -Boots @((New-Boot -Boot 0 -Label 'stock'), (New-Boot -Boot 1 -Label 'odd-state')) } | Should -Throw "*state 'odd-state' has no changed-driver entry*"
    }
    It 'refuses a load without margins and names it' {
        { Invoke-Analysis -Boots @((New-Boot -Boot 0 -Label 'stock' -Load 'furmark'), (New-Boot -Boot 1 -Label 'usb-line' -Load 'furmark')) } | Should -Throw "*no margins for load 'furmark'*"
    }
    It 'refuses boots that ran different loads' {
        { Invoke-Analysis -Boots @((New-Boot -Boot 0 -Label 'stock'), (New-Boot -Boot 1 -Label 'usb-line' -Load 'cs2')) } | Should -Throw '*different loads*'
    }
    It 'runs no test on a stock-only series and reads nothing it would test' {
        $boot = New-Boot -Boot 0 -Label 'stock'
        $boot.Bench = [pscustomobject]@{ probes = @([pscustomobject]@{ cpu = 0; stalledPct = 1.5 }) }
        $analysis = Invoke-Analysis -Boots @($boot)
        $analysis.family | Should -Be 0
        @($analysis.tests).Count | Should -Be 0
        @($analysis.load).Count | Should -Be 0
    }
    It 'gives no interval and no verdict word on one boot per state' {
        $boots = @(
            New-Boot -Boot 0 -Label 'stock'
            New-Boot -Boot 1 -Label 'audio-msi' -DxStalled 9
            New-Boot -Boot 2 -Label 'gpu-line' -DxStalled 0
        )
        $analysis = Invoke-Analysis -Boots $boots
        $analysis.family | Should -Be 12
        @($analysis.tests | Where-Object { $null -ne $_.ciLow -or $null -ne $_.ciHigh }).Count | Should -Be 0
        @($analysis.tests | Where-Object { $_.metric -ne 'low1PctMs' } | ForEach-Object { $_.verdict } | Sort-Object -Unique) | Should -Be @('cannot tell')
        @($analysis.tests | Where-Object { $_.metric -eq 'low1PctMs' } | ForEach-Object { $_.verdict } | Sort-Object -Unique) | Should -Be @('cannot show')
    }
    It 'reads the 1% low as cannot show on a GPU-bound load and against its margin on cs2' {
        $make = {
            param([string]$Load)
            @(0..2 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -Low1 10 -Load $Load; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -Low1 10.3 -Load $Load })
        }
        $gpu = Get-Test (Invoke-Analysis -Boots (& $make 'superposition')) 'usb-line' 'low1PctMs'
        $gpu.verdict | Should -Be 'cannot show'
        $gpu.margin | Should -BeNullOrEmpty
        $cpu = Get-Test (Invoke-Analysis -Boots (& $make 'cs2')) 'usb-line' 'low1PctMs'
        $cpu.margin | Should -Be 0.33
        $cpu.ciLow | Should -Be 0.3
        $cpu.verdict | Should -Be 'no difference'
    }
    It 'gives null percentages and cannot tell for a zero stock median' {
        $boots = @(0..2 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -DxGap 0 -AvgFps 0; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -DxGap 0 -AvgFps 0 })
        $analysis = Invoke-Analysis -Boots $boots
        $gap = Get-Test $analysis 'usb-line' 'dxgkrnlGapP99Us'
        $gap.margin | Should -Be 0
        $gap.shiftPctOfStock | Should -BeNullOrEmpty
        $gap.verdict | Should -Be 'cannot tell'
        $analysis.load[0].differencePct | Should -BeNullOrEmpty
    }
    It 'marks every test of a state whose load differs and keeps its verdicts' {
        $boots = @(0..2 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -AvgFps 120; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -AvgFps 130 })
        $analysis = Invoke-Analysis -Boots $boots
        $analysis.load[0].differs | Should -BeTrue
        $analysis.load[0].stockValues | Should -Be @(120, 120, 120)
        $analysis.load[0].stateValues | Should -Be @(130, 130, 130)
        @($analysis.tests | Where-Object { -not $_.loadDiffers }).Count | Should -Be 0
        (Get-Test $analysis 'usb-line' 'dxgkrnlStalledPct').verdict | Should -Be 'no difference'
    }
    It 'applies Holm over the whole family' {
        $boots = @(0..4 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -DxStalled @(5.0, 5.1, 5.2, 5.3, 5.4)[$_]; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -DxStalled @(6.0, 6.1, 6.2, 6.3, 6.4)[$_] })
        $test = Get-Test (Invoke-Analysis -Boots $boots) 'usb-line' 'dxgkrnlStalledPct'
        $test.extreme | Should -Be 2
        $test.permutations | Should -Be 252
        $test.p | Should -Be 0.007937
        $test.pHolm | Should -Be 0.047619
        $test.verdict | Should -Be 'hurt'
        $test.shift | Should -Be 1
        $test.shiftPctOfStock | Should -Be 19.2308
    }
    It 'takes the verdict from the Holm p, not the raw p' {
        $boots = @(0..3 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -DxStalled @(5.0, 5.1, 5.2, 5.3)[$_]; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -DxStalled @(6.0, 6.1, 6.2, 6.3)[$_] })
        $analysis = Invoke-Analysis -Boots $boots
        $analysis.family | Should -Be 6
        $test = Get-Test $analysis 'usb-line' 'dxgkrnlStalledPct'
        $test.p | Should -Be 0.028571
        $test.pHolm | Should -Be 0.171429
        $test.verdict | Should -Be 'cannot tell'
    }
    It 'prints a Holm p just under alpha with the digits that keep it under alpha' {
        $stock = @(1..12)
        $state = @(5.5, 6.5, 7.5, 8.5, 9.5, 10.5, 12.25, 12.5, 13.5, 14.5, 15.5, 16.5)
        $boots = @(0..11 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -DxStalled $stock[$_]; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -DxStalled $state[$_] })
        $analysis = Invoke-Analysis -Boots $boots
        $index = [array]::IndexOf(@($analysis.tests | ForEach-Object { $_.metric }), 'dxgkrnlStalledPct')
        $analysis.tests[$index].pHolm | Should -Be 0.049759
        $analysis.tests[$index].verdict | Should -Be 'hurt'
        Format-PValue -Value $analysis.pHolmExact[$index] | Should -Be '0.0498'
    }
}

Describe 'the bench JSON numbers as written' {
    It 'reads a stall share recorded 0.3 above stock as on the +/-0.3 margin' {
        $boots = @(0..2 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -DxStalled 8.65; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -DxStalled 8.95 })
        (Get-Test (Invoke-Analysis -Boots $boots) 'usb-line' 'dxgkrnlStalledPct').verdict | Should -Be 'cannot tell'
    }
    It 'reads a gap p99 recorded 10% above a 654 us stock median as on the margin' {
        $boots = @(0..2 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -DxGap 654; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -DxGap 719.4 })
        (Get-Test (Invoke-Analysis -Boots $boots) 'usb-line' 'dxgkrnlGapP99Us').verdict | Should -Be 'cannot tell'
    }
    It 'reads a cs2 1% low recorded 3.3% above stock as on the margin' {
        $boots = @(0..2 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -Load 'cs2' -Low1 11; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -Load 'cs2' -Low1 11.363 })
        (Get-Test (Invoke-Analysis -Boots $boots) 'usb-line' 'low1PctMs').verdict | Should -Be 'cannot tell'
    }
    It 'does not flag an average fps recorded exactly 1% off stock either way' {
        $boots = @(0..2 | ForEach-Object { New-Boot -Boot (3 * $_) -Label 'stock' -AvgFps 120; New-Boot -Boot (3 * $_ + 1) -Label 'usb-line' -AvgFps 121.2; New-Boot -Boot (3 * $_ + 2) -Label 'gpu-line' -AvgFps 118.8 })
        $analysis = Invoke-Analysis -Boots $boots
        @($analysis.load | ForEach-Object { $_.differs }) | Should -Be @($false, $false)
    }
    It 'ties boots whose recorded ISR and DPC totals add up to the same time' {
        $stock = @([ordered]@{ driver = 'Wdf01000.sys'; isrTotalUs = 12000.1; dpcTotalUs = 0.2 })
        $state = @([ordered]@{ driver = 'Wdf01000.sys'; isrTotalUs = 12000.3; dpcTotalUs = 0 })
        $boots = @(0..2 | ForEach-Object { New-Boot -Boot (2 * $_) -Label 'stock' -Drivers $stock; New-Boot -Boot (2 * $_ + 1) -Label 'usb-line' -Drivers $state })
        (Get-Test (Invoke-Analysis -Boots $boots) 'usb-line' 'changedDriverMsPerSecond').extreme | Should -Be 20
    }
}

Describe 'the analysis constants' {
    It 'pins the values fixed before the series was read' {
        $referenceState | Should -Be 'stock'
        $alpha | Should -Be 0.05d
        $confidence | Should -Be 0.9d
        $fpsLoadLimitPct | Should -Be 1
        @($marginRules.Keys) | Should -Be @('superposition', 'cs2')
        foreach ($load in 'superposition', 'cs2') {
            $marginRules[$load].stalledPct.absolute | Should -Be 0.3d
            $marginRules[$load].gapP99Us.shareOfStockMedian | Should -Be 0.1d
            $marginRules[$load].isrDpcMsPerSecond.absolute | Should -Be 0.5
        }
        $marginRules.superposition.low1PctMs.absolute | Should -Be 0.3d
        $marginRules.cs2.low1PctMs.shareOfStockMedian | Should -Be 0.033d
        @($changedDrivers.Keys) | Should -Be @('audio-msi', 'mobo-audio-msi', 'gpu-audio-msi', 'gpu-line', 'usb-line')
        $changedDrivers['audio-msi'] | Should -Be @('HDAudBus.sys')
        $changedDrivers['mobo-audio-msi'] | Should -Be @('HDAudBus.sys')
        $changedDrivers['gpu-audio-msi'] | Should -Be @('HDAudBus.sys')
        $changedDrivers['gpu-line'] | Should -Be @('dxgkrnl.sys', 'amdkmdag.sys')
        $changedDrivers['usb-line'] | Should -Be @('Wdf01000.sys')
        @($testMetrics | ForEach-Object { $_.key }) | Should -Be @('dxgkrnlStalledPct', 'dxgkrnlGapP99Us', 'wdf01000StalledPct', 'wdf01000GapP99Us', 'low1PctMs', 'changedDriverMsPerSecond')
    }
    It 'reads the bottleneck of each margin load from its recipe' {
        (Get-LoadRecipe -Name 'superposition').bottleneck | Should -Be 'gpu'
        (Get-LoadRecipe -Name 'cs2').bottleneck | Should -Be 'cpu'
    }
}
