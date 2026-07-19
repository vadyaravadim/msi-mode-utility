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
}
