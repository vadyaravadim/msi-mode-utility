BeforeAll {
    . (Join-Path $PSScriptRoot '..\bench-env.ps1')
    $script:powercfgSample = @'
Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)
  GUID Alias: SCHEME_BALANCED
  Subgroup GUID: 54533251-82be-4824-96c1-47b60b740d00  (Processor power management)
    GUID Alias: SUB_PROCESSOR
    Power Setting GUID: 0cc5b647-c1df-4637-891a-dec35c318583  (Processor performance core parking min cores)
      GUID Alias: CPMINCORES
      Minimum Possible Setting: 0x00000000
      Maximum Possible Setting: 0x00000064
      Possible Settings units: %
    Current AC Power Setting Index: 0x00000064
    Current DC Power Setting Index: 0x00000032

    Power Setting GUID: 36687f9e-e3a5-4dbf-b1dc-15eb381c6863  (Energy performance preference policy)
      GUID Alias: PERFEPP
      Minimum Possible Setting: 0x00000000
      Maximum Possible Setting: 0x00000064
    Current AC Power Setting Index: 0x00000000
    Current DC Power Setting Index: 0x00000021
'@
    $script:powercfgLocalized = $powercfgSample -replace 'Current AC Power Setting Index', 'Tekushchee AC' -replace 'Current DC Power Setting Index', 'Tekushchee DC'
    function New-FrameRow([double]$Ms, [string]$Sync = '0') {
        [pscustomobject]@{ MsBetweenPresents = $Ms; MsGPUBusy = $Ms / 2; MsCPUBusy = $Ms; SyncInterval = $Sync; PresentMode = 'Hardware: Independent Flip' }
    }
}

Describe 'Get-Percentile' {
    It 'indexes by floor(count * q)' {
        $sorted = [double[]](1..100)
        Get-Percentile $sorted 0.50 | Should -Be 51
        Get-Percentile $sorted 0.99 | Should -Be 100
        Get-Percentile $sorted 0.0 | Should -Be 1
    }
    It 'clamps to the last element and returns 0 for no data' {
        Get-Percentile ([double[]](1, 2, 3)) 0.999 | Should -Be 3
        Get-Percentile ([double[]]@()) 0.5 | Should -Be 0
    }
    It 'rounds to the requested digits' {
        Get-Percentile ([double[]](1.23456)) 0.5 1 | Should -Be 1.2
    }
}

Describe 'Get-FrameStats' {
    It 'computes percentiles and accepts an uncapped run' {
        $rows = 1..1000 | ForEach-Object { New-FrameRow (8 + ($_ % 10) / 10) }
        $stats = $rows | Get-FrameStats -RefreshHz 144
        $stats.frames | Should -Be 1000
        $stats.capped | Should -BeFalse
        $stats.p50Ms | Should -Be 8.5
        $stats.low1PctMs | Should -Be 8.9
        { Assert-LoadCanShowDifference $stats } | Should -Not -Throw
    }
    It 'flags vsync from SyncInterval and rejects the run' {
        $rows = 1..100 | ForEach-Object { New-FrameRow 8 '1' }
        $stats = $rows | Get-FrameStats -RefreshHz 144
        $stats.capped | Should -BeTrue
        { Assert-LoadCanShowDifference $stats } | Should -Throw '*this load cannot show a difference*'
    }
    It 'flags frame times stuck at the monitor refresh period' {
        $rows = 1..100 | ForEach-Object { New-FrameRow (16.667 + (($_ % 3) - 1) * 0.1) }
        $stats = $rows | Get-FrameStats -RefreshHz 60
        $stats.capped | Should -BeTrue
        $stats.cappedReason | Should -Match 'refresh period'
    }
    It 'does not flag a run well below the refresh period' {
        $rows = 1..100 | ForEach-Object { New-FrameRow 1.7 }
        ($rows | Get-FrameStats -RefreshHz 60).capped | Should -BeFalse
    }
    It 'refuses a CSV without the PresentMon 2.x columns' {
        { [pscustomobject]@{ MsBetweenPresents = 8 } | Get-FrameStats -RefreshHz 60 } | Should -Throw '*lacks column*'
    }
}

Describe 'ConvertFrom-PowercfgQuery' {
    It 'reads AC and DC as the last two hex values of each setting' {
        $settings = @(ConvertFrom-PowercfgQuery -Text $powercfgSample)
        $settings.Count | Should -Be 2
        $settings[0].alias | Should -Be 'CPMINCORES'
        $settings[0].ac | Should -Be 100
        $settings[0].dc | Should -Be 50
        $settings[1].alias | Should -Be 'PERFEPP'
        $settings[1].dc | Should -Be 33
    }
    It 'does not depend on the localized labels' {
        $settings = @(ConvertFrom-PowercfgQuery -Text $powercfgLocalized)
        $settings.Count | Should -Be 2
        $settings[0].ac | Should -Be 100
        $settings[0].dc | Should -Be 50
    }
}

Describe 'Get-BenchMetadata' {
    BeforeAll {
        $script:script = Join-Path $TestDrive 'some-bench.ps1'
        [System.IO.File]::WriteAllText($script, 'param()')
        Mock powercfg { if ($args[0] -eq '/getactivescheme') { 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)' } else { $script:powercfgSample } }
        Mock Get-RegistryValue {
            switch ($Name) {
                'CurrentBuild' { '26300' }
                'DisplayVersion' { '26H2' }
                'UBR' { 9818 }
            }
        }
        $script:meta = Get-BenchMetadata -BenchScript $script -Load 'cs2' -PresentMonVersion '2.6.0'
    }
    It 'names the bench script and records its SHA256' {
        $meta.benchScript.name | Should -Be 'some-bench.ps1'
        $meta.benchScript.sha256 | Should -Be (Get-FileHash -Path $script -Algorithm SHA256).Hash.ToLower()
    }
    It 'records the OS build, display version and update revision' {
        $meta.os.build | Should -Be '26300'
        $meta.os.displayVersion | Should -Be '26H2'
        $meta.os.ubr | Should -Be 9818
    }
    It 'records the power scheme GUID with every processor setting for AC and DC' {
        $meta.power.schemeGuid | Should -Be '381b4222-f694-41f0-9685-ff5bb260df2e'
        $meta.power.processorSettings.Count | Should -Be 2
        $meta.power.processorSettings[0].ac | Should -Be 100
        $meta.power.processorSettings[0].dc | Should -Be 50
    }
    It 'records the load name and the PresentMon version, or none' {
        $meta.load | Should -Be 'cs2'
        $meta.presentMonVersion | Should -Be '2.6.0'
        $bare = Get-BenchMetadata -BenchScript $script
        $bare.load | Should -Be 'none'
        $bare.presentMonVersion | Should -BeNullOrEmpty
    }
    It 'holds nothing that identifies the user or the machine' {
        $json = $meta | ConvertTo-Json -Depth 8
        $json | Should -Not -Match ([regex]::Escape($env:USERNAME))
        $json | Should -Not -Match ([regex]::Escape($env:COMPUTERNAME))
        $meta.PSObject.Properties.Name | Should -Be @('benchScript', 'os', 'power', 'load', 'presentMonVersion')
    }
}

Describe 'Write-BenchResult' {
    It 'writes the object as UTF-8 JSON without a BOM' {
        $path = Join-Path $TestDrive 'result.json'
        Write-BenchResult -Object ([pscustomobject]@{ phase = 'stock'; value = 1.5 }) -Path $path
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be ([byte][char]'{')
        ($bytes | Where-Object { $_ -gt 127 }) | Should -BeNullOrEmpty
        (Get-Content -Raw $path | ConvertFrom-Json).value | Should -Be 1.5
    }
    It 'does not rewrite the content' {
        $path = Join-Path $TestDrive 'raw.json'
        Write-BenchResult -Object ([pscustomobject]@{ path = 'C:\Users\someone\x' }) -Path $path
        (Get-Content -Raw $path | ConvertFrom-Json).path | Should -Be 'C:\Users\someone\x'
    }
}

Describe 'Invoke-PresentMonCapture' {
    BeforeAll {
        $script:fakePm = Join-Path $TestDrive 'PresentMon-fake.cmd'
        [System.IO.File]::WriteAllText($script:fakePm, "@echo off`r`necho MsBetweenPresents> %4`r`n")
        $script:fakeSha = (Get-FileHash -Path $script:fakePm -Algorithm SHA256).Hash.ToLower()
    }
    It 'requires the PresentMon path' {
        { Invoke-PresentMonCapture -PresentMonPath $null -ProcessName 'x.exe' -OutputFile (Join-Path $TestDrive 'a.csv') } | Should -Throw
    }
    It 'records the version field and the SHA256 of the PresentMon it ran' {
        $out = Join-Path $TestDrive 'frames.csv'
        $capture = Invoke-PresentMonCapture -PresentMonPath $fakePm -ProcessName 'x.exe' -OutputFile $out -Seconds 1 -ExpectedSha256 $fakeSha
        $capture.presentMonSha256 | Should -Be $fakeSha
        $capture.csv | Should -Be $out
        $capture.PSObject.Properties.Name | Should -Contain 'presentMonVersion'
        Test-Path $out | Should -BeTrue
    }
    It 'refuses a PresentMon whose hash is not the pinned one' {
        { Invoke-PresentMonCapture -PresentMonPath $fakePm -ProcessName 'x.exe' -OutputFile (Join-Path $TestDrive 'b.csv') -ExpectedSha256 ('0' * 64) } | Should -Throw '*SHA256*Use the pinned release*'
    }
}
