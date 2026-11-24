$summaryDigits = 4
$displayDigits = 2
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$alpha = 0.05d
$pValueDigits = 6
$pDisplayDigits = 3
$stableDoubleFormat = 'G15'
$displayFormat = '0.##'

function Get-Median {
    param([Parameter(Mandatory)][decimal[]]$Values)
    $sorted = [decimal[]]$Values.Clone()
    [Array]::Sort($sorted)
    $middle = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return $sorted[$middle] }
    ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function ConvertTo-DisplayDecimal {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [decimal]) { return $Value }
    [decimal]::Parse(([double]$Value).ToString($stableDoubleFormat, $invariant), [System.Globalization.NumberStyles]::Float, $invariant)
}

function Get-Spread {
    param([Parameter(Mandatory)][double[]]$Values)
    $sorted = [decimal[]]@($Values | ForEach-Object { ConvertTo-DisplayDecimal $_ })
    [Array]::Sort($sorted)
    [pscustomobject]@{
        median = ConvertTo-OutputNumber (Get-Median -Values $sorted)
        min    = ConvertTo-OutputNumber $sorted[0]
        max    = ConvertTo-OutputNumber $sorted[-1]
        n      = $sorted.Count
    }
}

function Format-Rounded {
    param([Parameter(Mandatory)]$Value)
    $rounded = [math]::Round((ConvertTo-DisplayDecimal $Value), $displayDigits)
    if ($rounded -eq 0) { $rounded = [decimal]0 }
    $rounded.ToString($displayFormat, $invariant)
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
    param([bool]$Significant, [int]$Direction, $CiLow, $CiHigh, $Margin, [switch]$CannotShow, [switch]$Colocated, [switch]$SameSide)
    if ($Colocated) { return 'cannot tell' }
    if ($Significant -and $Direction -gt 0) { return 'hurt' }
    if ($Significant -and $Direction -lt 0) { return 'helped' }
    if ($CannotShow) { return 'cannot show' }
    if ($SameSide) { return 'cannot tell' }
    if ($null -ne $CiLow -and $null -ne $CiHigh -and $null -ne $Margin -and -[decimal]$Margin -lt [decimal]$CiLow -and [decimal]$CiHigh -lt [decimal]$Margin) { return 'no difference' }
    'cannot tell'
}

function Get-PercentOf {
    param([Parameter(Mandatory)][decimal]$Value, [Parameter(Mandatory)][decimal]$Reference)
    if ($Reference -eq 0) { return $null }
    $Value / $Reference * 100
}

function ConvertTo-OutputNumber {
    param($Value, [int]$Digits = $summaryDigits)
    if ($null -eq $Value) { return $null }
    $rounded = [math]::Round((ConvertTo-DisplayDecimal $Value), $Digits)
    if ($rounded -eq 0) { return 0.0 }
    [double]$rounded
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

function Format-MarkdownTable {
    param([Parameter(Mandatory)][string[]]$Header, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('| ' + ($Header -join ' | ') + ' |')
    $lines.Add('| ' + (($Header | ForEach-Object { '---' }) -join ' | ') + ' |')
    foreach ($row in $Rows) { $lines.Add('| ' + (@($row) -join ' | ') + ' |') }
    $lines
}

function Write-TextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}
