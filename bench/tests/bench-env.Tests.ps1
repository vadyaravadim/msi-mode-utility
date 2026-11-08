BeforeDiscovery {
    $script:loadFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '..\loads') -Filter '*.json' -File)
}

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
    It 'sums the frame intervals into the captured span' {
        $rows = 1..1000 | ForEach-Object { New-FrameRow (8 + ($_ % 10) / 10) }
        ($rows | Get-FrameStats -RefreshHz 144).spanSeconds | Should -Be 8.45
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
    It 'writes the refresh rate in the capped reason with a dot on a comma-decimal culture' {
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('ru-RU')
            $rows = 1..100 | ForEach-Object { New-FrameRow 16.667 }
            ($rows | Get-FrameStats -RefreshHz 59.94).cappedReason | Should -Be 'frame times cluster at the 59.9 Hz refresh period'
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved
        }
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
    It 'records the QPC frequency the stall and timing numbers were taken at' {
        $meta.qpcFrequency | Should -Be ([System.Diagnostics.Stopwatch]::Frequency)
        $meta.qpcFrequency | Should -BeGreaterThan 0
    }
    It 'holds nothing that identifies the user or the machine' {
        $json = $meta | ConvertTo-Json -Depth 8
        $json | Should -Not -Match ([regex]::Escape($env:USERNAME))
        $json | Should -Not -Match ([regex]::Escape($env:COMPUTERNAME))
        $meta.PSObject.Properties.Name | Should -Be @('benchScript', 'os', 'power', 'load', 'presentMonVersion', 'qpcFrequency')
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
    It 'records the SHA256 of the PresentMon it ran and no version field (the 2.6.0 exe has no version resource)' {
        $out = Join-Path $TestDrive 'frames.csv'
        $capture = Invoke-PresentMonCapture -PresentMonPath $fakePm -ProcessName 'x.exe' -OutputFile $out -Seconds 1 -ExpectedSha256 $fakeSha
        $capture.presentMonSha256 | Should -Be $fakeSha
        $capture.csv | Should -Be $out
        $capture.PSObject.Properties.Name | Should -Be @('presentMonSha256', 'csv', 'overflowedPresents')
        $capture.overflowedPresents | Should -Be 0
        Test-Path $out | Should -BeTrue
    }
    It 'passes a power-of-two present event circular buffer larger than the PresentMon default' {
        $size = (Get-BenchConfig).PresentMonCircularBufferSize
        $size | Should -BeGreaterThan 2048
        ($size -band ($size - 1)) | Should -Be 0
        $argsFile = Join-Path $TestDrive 'pm-args.txt'
        $pm = Join-Path $TestDrive 'PresentMon-args.cmd'
        [System.IO.File]::WriteAllText($pm, "@echo off`r`necho MsBetweenPresents> %4`r`necho %*> `"$argsFile`"`r`n")
        Invoke-PresentMonCapture -PresentMonPath $pm -ProcessName 'x.exe' -OutputFile (Join-Path $TestDrive 'args.csv') -Seconds 1 | Out-Null
        (Get-Content -Raw $argsFile) | Should -Match "--set_circular_buffer_size $size"
    }
    It 'sums the overflowed present events from every PresentMon stderr line without throwing under Stop' {
        $pm = Join-Path $TestDrive 'PresentMon-overflow.cmd'
        [System.IO.File]::WriteAllText($pm, "@echo off`r`necho MsBetweenPresents> %4``necho 123 overflowed present events detected. This could be due to a high-fps application. 1>&2``necho 7 overflowed present events detected. 1>&2``n")
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Stop'
        try {
            $capture = Invoke-PresentMonCapture -PresentMonPath $pm -ProcessName 'x.exe' -OutputFile (Join-Path $TestDrive 'overflow.csv') -Seconds 1 -WarningAction SilentlyContinue
        } finally { $ErrorActionPreference = $previous }
        $capture.overflowedPresents | Should -Be 130
    }
    It 're-emits PresentMon stderr as warnings' {
        $pm = Join-Path $TestDrive 'PresentMon-warn.cmd'
        [System.IO.File]::WriteAllText($pm, "@echo off`r`necho MsBetweenPresents> %4``necho 5 overflowed present events detected. 1>&2``n")
        $null = Invoke-PresentMonCapture -PresentMonPath $pm -ProcessName 'x.exe' -OutputFile (Join-Path $TestDrive 'warn.csv') -Seconds 1 -WarningVariable pmWarnings -WarningAction SilentlyContinue
        ($pmWarnings -join ' ') | Should -Match '5 overflowed present events'
    }
    It 'refuses a PresentMon whose hash is not the pinned one' {
        { Invoke-PresentMonCapture -PresentMonPath $fakePm -ProcessName 'x.exe' -OutputFile (Join-Path $TestDrive 'b.csv') -ExpectedSha256 ('0' * 64) } | Should -Throw '*SHA256*Use the pinned release*'
    }
}

Describe 'Find-LogMarker' {
    It 'finds the marker only after the offset' {
        $text = "a`n[VProf] VProfLite started.`nb"
        Find-LogMarker -Text $text -Pattern '[VProf] VProfLite started.' | Should -Be 2
        Find-LogMarker -Text $text -Pattern '[VProf] VProfLite started.' -From 5 | Should -Be -1
    }
    It 'treats the pattern as plain text, not a regex' {
        Find-LogMarker -Text 'VProf VProfLite started' -Pattern '[VProf] VProfLite started.' | Should -Be -1
    }
    It 'returns -1 when the log is shorter than the offset' {
        Find-LogMarker -Text 'short' -Pattern 'x' -From 100 | Should -Be -1
    }
}

Describe 'Get-ExtraLaunchFlag' {
    It 'names flags outside the recipe and drops the exe and every value' {
        $cmd = '"D:\Games\cs2.exe" -steam -novid +con_enable 1 -vulkan -console -name "secret"'
        Get-ExtraLaunchFlag -CommandLine $cmd -Expected @('-novid', '+con_enable', '1', '-console') | Should -Be @('-steam', '-vulkan', '-name')
    }
    It 'returns nothing when the command line matches the recipe' {
        Get-ExtraLaunchFlag -CommandLine 'cs2.exe -novid' -Expected @('-novid') | Should -BeNullOrEmpty
    }
}

Describe 'load recipes for -Test game' {
    It 'loads <_.BaseName> and fits the capture inside a workshop route' -ForEach $loadFiles {
        { Get-LoadRecipe -Name $_.BaseName } | Should -Not -Throw
    }
    It 'gives <_.BaseName> a process name and a PresentMon process name' -ForEach $loadFiles {
        $r = Get-LoadRecipe -Name $_.BaseName
        $r.process | Should -Not -BeNullOrEmpty
        $r.presentMonProcess | Should -Be "$($r.process).exe"
    }
    It 'refuses an unknown load and lists the known ones' {
        { Get-LoadRecipe -Name 'nope' } | Should -Throw '*cs2*'
    }
    It 'drops the Steam -applaunch pair from the args the game process sees' {
        $r = Get-LoadRecipe -Name 'cs2'
        $procArgs = Get-RecipeProcessArg -Recipe $r
        $procArgs | Should -Not -Contain '-applaunch'
        $procArgs | Should -Contain '-condebug'
    }
    It 'keeps every arg for a program started directly' {
        $r = Get-LoadRecipe -Name 'superposition'
        (Get-RecipeProcessArg -Recipe $r).Count | Should -Be @($r.launchArgs).Count
    }
}

Describe 'Get-VideoConfigMismatch' {
    BeforeAll {
        $script:shipped = Join-Path $TestDrive 'shipped.txt'
        Set-Content -Path $shipped -Value @('"video.cfg"', '{', "`t`"Version`"`t`t`"16`"", "`t`"VendorID`"`t`t`"4098`"", "`t`"setting.defaultres`"`t`t`"1280`"", "`t`"setting.mat_vsync`"`t`t`"0`"", '}')
    }
    It 'ignores machine keys outside the prefix and accepts equal settings' {
        $mine = Join-Path $TestDrive 'mine-ok.txt'
        Set-Content -Path $mine -Value @('"video.cfg"', '{', "`t`"VendorID`"`t`t`"4318`"", "`t`"setting.defaultres`"`t`t`"1280`"", "`t`"setting.mat_vsync`"`t`t`"0`"", "`t`"setting.extra`"`t`t`"1`"", '}')
        Get-VideoConfigMismatch -Expected $shipped -Installed $mine -KeyPrefix 'setting.' | Should -BeNullOrEmpty
    }
    It 'names each setting that differs or is missing' {
        $mine = Join-Path $TestDrive 'mine-bad.txt'
        Set-Content -Path $mine -Value @('"video.cfg"', '{', "`t`"setting.defaultres`"`t`t`"640`"", '}')
        Get-VideoConfigMismatch -Expected $shipped -Installed $mine -KeyPrefix 'setting.' | Should -Be @('setting.defaultres', 'setting.mat_vsync')
    }
}

Describe 'Get-GameRejection' {
    BeforeAll {
        $script:recipe = [pscustomobject]@{ videoConfig = [pscustomobject]@{ file = 'video.txt' }; timings = [pscustomobject]@{ captureSeconds = 60 } }
        $script:okStats = [pscustomobject]@{ capped = $false; cappedReason = ''; spanSeconds = 59.9 }
    }
    It 'accepts a run with no capped frames and no lost frames' {
        Get-GameRejection -Stats $okStats -Capture ([pscustomobject]@{ overflowedPresents = 0 }) -Video $null -Recipe $recipe | Should -BeNullOrEmpty
    }
    It 'rejects a run that lost frames to a present event buffer overflow' {
        $reason = Get-GameRejection -Stats $okStats -Capture ([pscustomobject]@{ overflowedPresents = 130 }) -Video $null -Recipe $recipe
        $reason | Should -Be 'PresentMon lost 130 frames (present event buffer overflow)'
    }
    It 'rejects a run whose frames do not cover the capture window' {
        $short = [pscustomobject]@{ capped = $false; cappedReason = ''; spanSeconds = 12.8 }
        $reason = Get-GameRejection -Stats $short -Capture ([pscustomobject]@{ overflowedPresents = 0 }) -Video $null -Recipe $recipe
        $reason | Should -Be 'the captured frames cover 12.8 s of the 60 s window (the load stopped presenting or exited)'
    }
    It 'accepts a span at the coverage limit and rejects one just below it' {
        $edge = [pscustomobject]@{ capped = $false; cappedReason = ''; spanSeconds = 57 }
        Get-GameRejection -Stats $edge -Capture ([pscustomobject]@{ overflowedPresents = 0 }) -Video $null -Recipe $recipe | Should -BeNullOrEmpty
        $edge.spanSeconds = 56.9
        Get-GameRejection -Stats $edge -Capture ([pscustomobject]@{ overflowedPresents = 0 }) -Video $null -Recipe $recipe | Should -Match 'cover 56.9 s'
    }
    It 'still rejects a capped run and joins several reasons' {
        $capped = [pscustomobject]@{ capped = $true; cappedReason = 'vsync'; spanSeconds = 59.9 }
        $reason = Get-GameRejection -Stats $capped -Capture ([pscustomobject]@{ overflowedPresents = 2 }) -Video $null -Recipe $recipe
        $reason | Should -Match 'vsync'
        $reason | Should -Match 'lost 2 frames'
    }
}

Describe 'Join-Rejection' {
    It 'joins the game and the background reasons' {
        Join-Rejection -Reason @('a', 'b') | Should -Be 'a; b'
        Join-Rejection -Reason @($null, 'b') | Should -Be 'b'
        Join-Rejection -Reason @($null, $null) | Should -BeNullOrEmpty
    }
}

Describe 'Get-LoadLogPath' {
    It 'resolves the recipe log next to the exe' {
        $recipe = [pscustomobject]@{ startMarker = [pscustomobject]@{ log = '../../csgo/console.log' } }
        $process = [pscustomobject]@{ Path = 'C:\g\game\bin\win64\cs2.exe' }
        Get-LoadLogPath -Recipe $recipe -Process $process | Should -Be 'C:\g\game\csgo\console.log'
    }
}

Describe 'Get-LoadRecord' {
    BeforeAll {
        $script:recordRecipe = [pscustomobject]@{ launchArgs = @('-applaunch', '730', '-novid') ; game = [pscustomobject]@{ steamAppId = 730 } }
    }
    BeforeEach {
        Mock Get-LoadBuild { '1.2.3' }
        Mock Get-VideoConfigCheck { [pscustomobject]@{ found = $true; mismatchedKeys = @() } }
        Mock Get-CimInstance { [pscustomobject]@{ CommandLine = 'cs2.exe -novid -extra +foo' } }
    }
    It 'returns name, build, videoConfig and extraLaunchFlags in that order' {
        $proc = [pscustomobject]@{ Id = 9; Path = 'C:\g\cs2.exe' }
        $record = Get-LoadRecord -Recipe $recordRecipe -Name 'cs2' -Process $proc
        @($record.PSObject.Properties.Name) | Should -Be @('name', 'build', 'videoConfig', 'extraLaunchFlags')
        $record.name | Should -Be 'cs2'
        $record.build | Should -Be '1.2.3'
        $record.videoConfig.found | Should -BeTrue
        @($record.extraLaunchFlags) | Should -Be @('-extra', '+foo')
        Should -Invoke Get-LoadBuild -Times 1 -Exactly -ParameterFilter { $ExePath -eq 'C:\g\cs2.exe' }
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $Filter -eq 'ProcessId = 9' }
    }
    It 'keeps extraLaunchFlags an empty array when the command line matches the recipe' {
        Mock Get-CimInstance { [pscustomobject]@{ CommandLine = 'cs2.exe -novid' } }
        $record = Get-LoadRecord -Recipe $recordRecipe -Name 'cs2' -Process ([pscustomobject]@{ Id = 9; Path = 'C:\g\cs2.exe' })
        @($record.extraLaunchFlags).Count | Should -Be 0
    }
}
