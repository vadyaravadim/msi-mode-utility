BeforeDiscovery {
    $script:seriesNames = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\results') -Directory | ForEach-Object { $_.Name })
}

BeforeAll {
    $script:results = Join-Path $PSScriptRoot '..\results'
    . (Join-Path $PSScriptRoot '..\tools\Get-MsiSeriesTable.ps1') -SeriesPath 'unit-test'

    function Read-ResultText {
        param([Parameter(Mandatory)][string]$Name)
        [System.IO.File]::ReadAllText((Join-Path $script:results $Name)).Replace("`r`n", "`n")
    }

    function Get-TableBlock {
        param([Parameter(Mandatory)][string]$Markdown, [Parameter(Mandatory)][string]$FirstCell)
        $lines = $Markdown.Replace("`r`n", "`n") -split "`n"
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].StartsWith("| $FirstCell |")) { $start = $i; break }
        }
        if ($start -lt 0) { throw "no table starts with the cells '$FirstCell'" }
        $end = $start
        while ($end + 1 -lt $lines.Count -and $lines[$end + 1].StartsWith('|')) { $end++ }
        $lines[$start..$end] -join "`n"
    }

    function ConvertTo-CanonicalText {
        param($Value)
        if ($null -eq $Value) { return 'null' }
        if ($Value -is [string]) { return '"' + $Value + '"' }
        if ($Value -is [bool]) { return [string]$Value }
        if ($Value -is [System.ValueType]) { return ([double]$Value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($Value -is [System.Collections.IEnumerable]) { return '[' + ((@($Value) | ForEach-Object { ConvertTo-CanonicalText $_ }) -join ',') + ']' }
        '{' + ((@($Value.PSObject.Properties) | ForEach-Object { $_.Name + ':' + (ConvertTo-CanonicalText $_.Value) }) -join ',') + '}'
    }

    $script:reports = @{}
    foreach ($directory in @(Get-ChildItem -LiteralPath $script:results -Directory)) {
        $script:reports[$directory.Name] = New-SeriesReport -SeriesPath $directory.FullName
    }
    $script:readme = Read-ResultText 'README.md'
}

Describe 'the published series' {
    It 'has at least one series folder' {
        $script:reports.Count | Should -BeGreaterThan 0
    }

    It 'the committed tables of <_> are what the table script writes from the committed files' -ForEach $seriesNames {
        $script:reports[$_].Markdown.Replace("`r`n", "`n") | Should -BeExactly (Read-ResultText "$_.tables.md")
    }

    It 'the committed summary of <_> holds the numbers the table script computes from the committed files' -ForEach $seriesNames {
        $computed = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $script:reports[$_].Summary -Depth 12)
        $committed = ConvertFrom-Json -InputObject (Read-ResultText "$_.summary.json")
        ConvertTo-CanonicalText $computed | Should -BeExactly (ConvertTo-CanonicalText $committed)
    }

    It 'the README quotes the pre-registered tests of <_> verbatim' -ForEach $seriesNames {
        $block = Get-TableBlock -Markdown $script:reports[$_].Markdown -FirstCell 'State | Metric'
        $script:readme.Contains("`n`n" + $block + "`n`n") | Should -BeTrue
    }

    It 'the README quotes the frames table of <_> verbatim' -ForEach $seriesNames {
        $block = Get-TableBlock -Markdown $script:reports[$_].Markdown -FirstCell 'State | Boots | Avg FPS'
        $script:readme.Contains("`n`n" + $block + "`n`n") | Should -BeTrue
    }

    It 'the README links the folder and the tables of <_>' -ForEach $seriesNames {
        $script:readme.Contains("]($_.tables.md)") | Should -BeTrue
        $script:readme.Contains("]($_/)") | Should -BeTrue
    }
}
