BeforeAll {
    . (Join-Path $PSScriptRoot '..\bench-env.ps1')
    . (Join-Path $PSScriptRoot '..\tools\series-lib.ps1')
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

Describe 'Get-DoubledMidRank' {
    It 'gives tied values the doubled mean of their ranks' {
        Get-DoubledMidRank -Values @(1, 2, 2, 2, 3, 3) | Should -Be @(2, 6, 6, 6, 11, 11)
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

Describe 'Get-Verdict -SameSide' {
    It 'reads cannot tell instead of no difference when the two sides are the same' {
        Get-Verdict -Significant $false -Direction 1 -CiLow -0.29 -CiHigh 0.29 -Margin 0.3 | Should -Be 'no difference'
        Get-Verdict -Significant $false -Direction 1 -CiLow -0.29 -CiHigh 0.29 -Margin 0.3 -SameSide | Should -Be 'cannot tell'
    }
    It 'keeps helped or hurt for a significant test' {
        Get-Verdict -Significant $true -Direction 1 -CiLow 1 -CiHigh 2 -Margin 0.3 -SameSide | Should -Be 'hurt'
        Get-Verdict -Significant $true -Direction -1 -CiLow -2 -CiHigh -1 -Margin 0.3 -SameSide | Should -Be 'helped'
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
    It 'prints a value that rounds to zero without a sign' {
        Format-Rounded -0.004 | Should -Be '0'
        (ConvertTo-OutputNumber -0.00001).ToString($invariant) | Should -Be '0'
    }
}
