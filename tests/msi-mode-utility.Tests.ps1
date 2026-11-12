BeforeDiscovery {
    $script:isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\msi-mode-utility.ps1'
    $script:scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    function Find-ScriptNode([scriptblock]$Predicate) {
        $scriptAst.Find($Predicate, $true)
    }
}

Describe 'PSScriptInfo version placeholder' {
    It 'is exactly .VERSION 0.0.0, the line release.yml stamps' {
        $lines = @(Select-String -LiteralPath $scriptPath -Pattern '^\.VERSION\b' | ForEach-Object Line)
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly '.VERSION 0.0.0'
    }
}

Describe 'the irm | iex rerun forwards a single mode switch to powershell.exe -File' {
    BeforeAll {
        $forwarder = Find-ScriptNode { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ForwardedSwitchList' }
        $bootstrap = Find-ScriptNode { param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '-not $PSCommandPath' }
        $rerun = @($bootstrap.Clauses[0].Item2.Statements | Where-Object { $_.Extent.Text -match '^(\$fwd\s*=|powershell\s)' })
        $rerun.Count | Should -Be 2
        $script:stub = Join-Path $TestDrive 'rerun-stub.ps1'
        Set-Content -LiteralPath $stub -Value 'param([switch]$ShowAll, [switch]$Disable, [switch]$Status) "ShowAll=$ShowAll Disable=$Disable Status=$Status"' -Encoding Ascii
        $code = @('param($ShowAll, $Disable, $Status, $saved)', $forwarder.Extent.Text) + @($rerun | ForEach-Object { $_.Extent.Text })
        $script:rerunScript = [scriptblock]::Create($code -join "`n")
    }

    It 'binds -Status in the rerun when it is the only forwarded switch' {
        & $rerunScript $false $false $true $stub | Should -Be 'ShowAll=False Disable=False Status=True'
    }

    It 'binds -Disable in the rerun when it is the only forwarded switch' {
        & $rerunScript $false $true $false $stub | Should -Be 'ShowAll=False Disable=True Status=False'
    }
}

Describe 'Get-ForwardedSwitchList' {
    It 'forwards every documented switch and never the internal -Elevated' {
        $help = $scriptAst.GetHelpContent()
        if (-not $help) { throw 'GetHelpContent() returned $null: the PSScriptInfo block before the help block hides the help' }
        $documented = @($help.Parameters.Keys)
        $switchNames = @($scriptAst.ParamBlock.Parameters | Where-Object { $_.StaticType -eq [switch] } | ForEach-Object { $_.Name.VariablePath.UserPath })
        $expected = @($switchNames | Where-Object { $documented -contains $_ } | ForEach-Object { "-$_" } | Sort-Object)
        $expected.Count | Should -BeGreaterThan 0
        $expected | Should -Not -Contain '-Elevated'
        $forwarder = Find-ScriptNode { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ForwardedSwitchList' }
        $code = @($switchNames | ForEach-Object { "`$$_ = `$true" }) + $forwarder.Extent.Text + 'Get-ForwardedSwitchList'
        $actual = @(& ([scriptblock]::Create($code -join "`n")) | Sort-Object)
        $actual | Should -Be $expected
    }
}

Describe 'a run that picks devices in the grid' {
    BeforeAll {
        $script:copy = Join-Path $TestDrive 'msi-mode-utility.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $copy
        Mock Get-CimInstance { 'mock reached' } -ParameterFilter { $ClassName -eq 'Win32_PesterMockProbe' }
        $probe = Join-Path $TestDrive 'mock-probe.ps1'
        Set-Content -LiteralPath $probe -Value 'Get-CimInstance Win32_PesterMockProbe -ErrorAction SilentlyContinue' -Encoding Ascii
        $probeResult = $null
        try { $probeResult = & $probe } catch { $probeResult = $null }
        if ($probeResult -ne 'mock reached') {
            throw 'Pester mocks do not reach a script run with &: the whole-script tests would touch this machine'
        }
    }

    BeforeEach {
        Mock Out-GridView { $InputObject }
        Mock Read-Host { 'n' }
        Mock Start-Process { }
        Mock Invoke-RestMethod { }
        Mock New-Item { }
        Mock New-ItemProperty { }
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
        Mock Set-Content { }
        Mock Start-Sleep { }
        Mock Write-Host { }
        Mock Get-CimInstance { }
        Mock Get-PnpDevice { [pscustomobject]@{ InstanceId = 'PCI\VEN_FAKE&DEV_0001\0'; FriendlyName = 'Fake NIC'; ClassGuid = '{4d36e972-e325-11ce-bfc1-08002be10318}'; Service = 'fakenic' } }
        Mock Test-Path { $true } -ParameterFilter { "$Path" -like 'Registry::*' }
        Mock Get-ItemProperty { [pscustomobject]@{ MSISupported = 0 } } -ParameterFilter { $Name -eq 'MSISupported' }
    }

    It 'stops before the scan on Windows Server Core' -Skip:(-not $isAdmin) {
        Mock Get-ItemProperty { [pscustomobject]@{ ServerCore = 1 } } -ParameterFilter { "$Path$LiteralPath" -like '*\Windows NT\CurrentVersion\Server\ServerLevels' }
        & $copy
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Out-GridView is not available*' }
        Should -Invoke Get-PnpDevice -Times 0 -Exactly -Because 'Server Core has no desktop for the grid, so the scan is pointless'
    }

    It 'does not ask for a reboot when every registry write failed' -Skip:(-not $isAdmin) {
        Mock New-ItemProperty { throw 'registry write denied' }
        & $copy
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { "$Object" -like 'Out-GridView is not available*' } -Because 'the runner is not Server Core, so the real ServerLevels read must say so'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Done. 0 of 1*' }
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { "$Object" -like 'REBOOT REQUIRED*' } -Because 'nothing was changed, so there is nothing to reboot for'
    }

    It 'asks before changing a storage controller and changes nothing on a no' -Skip:(-not $isAdmin) {
        Mock Get-PnpDevice { [pscustomobject]@{ InstanceId = 'PCI\VEN_FAKE&DEV_0002\0'; FriendlyName = 'Fake NVMe controller'; ClassGuid = '{4d36e97b-e325-11ce-bfc1-08002be10318}'; Service = 'stornvme' } }
        & $copy -ShowAll
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { "$Prompt" -like 'Continue anyway*' }
        Should -Invoke Set-Content -Times 0 -Exactly -Because 'a declined run writes no undo file'
        Should -Invoke New-ItemProperty -Times 0 -Exactly -Because 'a declined run changes nothing'
    }

    It 'changes a storage controller after a yes' -Skip:(-not $isAdmin) {
        Mock Get-PnpDevice { [pscustomobject]@{ InstanceId = 'PCI\VEN_FAKE&DEV_0002\0'; FriendlyName = 'Fake NVMe controller'; ClassGuid = '{4d36e97b-e325-11ce-bfc1-08002be10318}'; Service = 'stornvme' } }
        Mock Read-Host { 'y' }
        & $copy -ShowAll
        Should -Invoke Read-Host -Times 1 -Exactly -ParameterFilter { "$Prompt" -like 'Continue anyway*' }
        Should -Invoke New-ItemProperty -Times 1 -Exactly
    }

    It 'does not ask when no storage controller is picked' -Skip:(-not $isAdmin) {
        & $copy
        Should -Invoke Read-Host -Times 0 -Exactly -ParameterFilter { "$Prompt" -like 'Continue anyway*' }
        Should -Invoke New-ItemProperty -Times 1 -Exactly
    }
}

Describe 'PSScriptInfo metadata for the PowerShell Gallery' {
    BeforeAll {
        $script:infoValue = {
            param([string]$Key)
            $line = @(Select-String -LiteralPath $scriptPath -Pattern "^\.$Key\b" | ForEach-Object Line)
            $line.Count | Should -Be 1 -Because "PSScriptInfo has exactly one .$Key line"
            ($line[0] -replace "^\.$Key\s*", '').Trim()
        }
    }

    It 'PSScriptInfo copyright is the LICENSE copyright line' {
        $license = Join-Path $PSScriptRoot '..\LICENSE'
        & $infoValue 'COPYRIGHT' | Should -BeExactly (Get-Content -LiteralPath $license)[2]
    }

    It 'PSScriptInfo tags list PSEdition_Desktop and PSEdition_Core' {
        $tags = (& $infoValue 'TAGS') -split '\s+'
        $tags | Should -Contain 'PSEdition_Desktop'
        $tags | Should -Contain 'PSEdition_Core'
    }

    It 'PSScriptInfo release notes are the CHANGELOG of .PROJECTURI' {
        & $infoValue 'RELEASENOTES' | Should -BeExactly ((& $infoValue 'PROJECTURI') + '/blob/main/CHANGELOG.md')
    }
}
