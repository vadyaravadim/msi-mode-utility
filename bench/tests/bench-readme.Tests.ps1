BeforeDiscovery {
    $script:loadFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '..\loads') -Filter '*.json' -File)
}

BeforeAll {
    $script:readme = Get-Content -Path (Join-Path $PSScriptRoot '..\README.md') -Raw
}

Describe 'README matches bench/loads' {
    It 'names the load <_.BaseName> after its file' -ForEach $loadFiles {
        (Get-Content -Path $_.FullName -Raw | ConvertFrom-Json).name | Should -Be $_.BaseName
    }
    It 'quotes the pinned PresentMon version and SHA256 for <_.BaseName>' -ForEach $loadFiles {
        $load = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        $readme | Should -Match ([regex]::Escape($load.presentMon.version))
        $readme | Should -Match ([regex]::Escape($load.presentMon.sha256))
    }
    It 'quotes the timings and the driver switches for <_.BaseName>' -ForEach $loadFiles {
        $load = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        $readme | Should -Match ([regex]::Escape("load pause $($load.timings.loadPauseSeconds) s"))
        $readme | Should -Match ([regex]::Escape("capture $($load.timings.captureSeconds) s"))
        foreach ($item in $load.driverOff) { $readme | Should -Match ([regex]::Escape($item)) }
    }
    It 'quotes the launch arguments for <_.BaseName>' -ForEach $loadFiles {
        $load = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        $line = ($load.launchArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        $readme | Should -Match ([regex]::Escape($line))
    }
    It 'quotes the console line and the workshop id for <_.BaseName>' -ForEach $loadFiles {
        $load = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        if ($load.consoleLine) { $readme | Should -Match ([regex]::Escape($load.consoleLine)) }
        if ($load.workshop) { $readme | Should -Match ([regex]::Escape($load.workshop.id)) }
    }
    It 'ships the video config file of <_.BaseName> and keeps its vsync equal to the load vsync' -ForEach $loadFiles {
        $load = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
        if ($load.videoConfig) {
            $path = Join-Path $_.DirectoryName $load.videoConfig.file
            $path | Should -Exist
            $values = @{}
            foreach ($line in Get-Content -Path $path) {
                if ($line -match '^\s*"([^"]+)"\s+"([^"]*)"\s*$') { $values[$Matches[1]] = $Matches[2] }
            }
            $values['setting.mat_vsync'] | Should -Be ([string]$load.vsync)
            foreach ($key in 'setting.defaultres', 'setting.defaultresheight', 'setting.msaa_samples') {
                $values[$key] | Should -Match '^\d+$' -Because "$($load.videoConfig.file) must define $key"
            }
            $readme | Should -Match ([regex]::Escape($load.videoConfig.location))
        }
    }
}

Describe 'README is generated' {
    It 'equals the output of tools\New-BenchReadme.ps1 (run it with -Write to fix drift)' {
        $generated = (& (Join-Path $PSScriptRoot '..\tools\New-BenchReadme.ps1')) -join "`n"
        $committed = (Get-Content -Path (Join-Path $PSScriptRoot '..\README.md') -Raw) -replace "`r`n", "`n"
        $committed.TrimEnd("`n") | Should -BeExactly $generated.TrimEnd("`n")
    }
}
