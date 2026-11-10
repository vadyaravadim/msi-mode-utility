@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # This is an interactive TUI script: Write-Host drives the colored
        # console UI on purpose (not a pipeline function), so the "avoid
        # Write-Host" advice does not apply.
        'PSAvoidUsingWriteHost'

        # False positive: $Elevated / $UserSid are read inside the nested
        # Wait-IfElevatedWindow function via parent scope, which PSSA does not
        # trace - it sees the param as unused.
        'PSReviewUnusedParameter'

        # Internal helper functions in a self-contained script; -WhatIf/-Confirm
        # add no value (the script has its own .reg undo mechanism).
        'PSUseShouldProcessForStateChangingFunctions'

        # Plural helper names (ConvertTo-HexPairs, Get-SleepStats) are deliberate
        # - they return collections/sets.
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleTypes  = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
