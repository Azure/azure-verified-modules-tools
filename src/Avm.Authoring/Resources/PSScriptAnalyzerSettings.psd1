@{
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true

    # Rule configuration kept minimal until Phase 0 stabilises. Tighten over
    # time rather than disabling default rules.
    Rules               = @{
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
        }
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckSeparator                          = $true
            # Manifest .psd1 and other config-style hashtables align '=' for
            # readability; PSAlignAssignmentStatement enforces that. Tell the
            # whitespace rule to ignore = inside hashtables so the two rules
            # do not contradict each other.
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSUseCorrectCasing         = @{
            Enable = $true
        }
    }

    # The dispatcher's user-facing alias 'avm' is intentionally a non-approved
    # verb shape (it is a unix-style CLI). Exempt the dispatcher file from the
    # noun/verb rules; everything else must comply.
    ExcludeRules        = @()
}
