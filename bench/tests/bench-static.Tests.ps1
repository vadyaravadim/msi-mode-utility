BeforeAll {
    $script:benchDir = Join-Path $PSScriptRoot '..'
    $script:scripts = @(Get-ChildItem -Path $benchDir -Filter '*.ps1' -File)
    $script:forbidden = @(
        'powercfg(\.exe)?\s+/set',
        'powercfg(\.exe)?\s+/(import|restoredefaultschemes|delete|duplicatescheme|changename|overlaysetactive)',
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item\s+(-Path\s+)?HK',
        'reg(\.exe)?\s+(add|import|delete)',
        'bcdedit(\.exe)?\s+/(set|deletevalue)',
        'Set-Service', 'Stop-Service', 'Start-Service', 'Restart-Service', 'Stop-Process', 'Disable-ScheduledTask',
        'sc(\.exe)?\s+(config|stop|delete)'
    )
}

Describe 'bench scripts only read the system' {
    It 'finds the bench scripts' {
        $scripts.Count | Should -BeGreaterThan 1
    }
    It 'contains no state-changing command' {
        foreach ($script in $scripts) {
            $text = Get-Content -Path $script.FullName -Raw
            foreach ($pattern in $forbidden) {
                $text | Should -Not -Match "(?im)$pattern" -Because "$($script.Name) must not match $pattern"
            }
        }
    }
    It 'stops only the bench own ETW session' {
        foreach ($script in $scripts) {
            foreach ($stop in @(Select-String -Path $script.FullName -Pattern 'logman\s+stop')) {
                $stop.Line | Should -Match 'logman\s+stop\s+\$traceSession\b' -Because "$($script.Name) line $($stop.LineNumber)"
            }
        }
    }
    It 'starts only the bench own ETW session' {
        foreach ($script in $scripts) {
            foreach ($start in @(Select-String -Path $script.FullName -Pattern 'logman\s+start')) {
                $start.Line | Should -Match 'logman\s+start\s+\$traceSession\b' -Because "$($script.Name) line $($start.LineNumber)"
            }
        }
    }
}

Describe 'bench scripts are importable' {
    It 'dot-sourcing defines functions and runs no measurement' {
        $before = @(Get-ChildItem -Path $benchDir -Filter '*.json' -File).Count
        foreach ($script in $scripts | Where-Object { $_.Name -ne 'bench-env.ps1' }) {
            { . $script.FullName -Phase 'import-test' } | Should -Not -Throw
        }
        @(Get-ChildItem -Path $benchDir -Filter '*.json' -File).Count | Should -Be $before
    }
}
