function Test-AvmModuleVersion {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', 'SkipModuleVersionCheck',
        Justification = 'Retained for backward compatibility after removing runtime module-version enforcement.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', 'SuppressSkipWarning',
        Justification = 'Retained for backward compatibility after removing runtime module-version enforcement.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', 'RefreshLatestVersion',
        Justification = 'Retained for backward compatibility after removing runtime module-version enforcement.')]
    param(
        [switch] $SkipModuleVersionCheck,

        [switch] $SuppressSkipWarning,

        [switch] $RefreshLatestVersion
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
}
