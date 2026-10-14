function Select-AvmTestSubscription {
    <#
    .SYNOPSIS
        Select a Bicep test subscription using the repository's exact reservation map.

    .DESCRIPTION
        Validates the complete explicit subscription pool and the repository-root
        .reserved-test-subscriptions.json, then selects within the owning module's
        tag using the native seeded, order-independent permutation. Unmapped
        modules use General. A missing tag never falls back to another tag.

        An optional exact example directory or main.test.bicep path is resolved
        through native recursive test discovery. Its owning module, not a parent
        identity root, determines the reservation. Missing, ignored, ambiguous or
        miscased examples fail; short-name aliases and path normalization are not
        used. Without Example, ModulePath is the exact reservation lookup path.

        The returned original pool index and canonical subscription digest allow
        a caller to repeat selection and verify its matrix binding before login.
        This read-only command never compiles, signs in, registers prerequisites,
        prepares infrastructure or deploys. A non-General result does not authorize
        native e2e execution; reserved environments still require their protected
        registry lifecycle. No ambient pool or singleton fallback is read.

    .PARAMETER Path
        Existing filesystem repository root containing the exact reservation map.
        This is authoritative; the command never searches parent directories.

    .PARAMETER ModulePath
        Exact lowercase repository-relative Bicep module path, using forward
        slashes, such as avm/res/storage/storage-account. Reservations are not
        inherited from parent or child paths.

    .PARAMETER Example
        Optional exact module-relative test directory or main.test.bicep path,
        using forward slashes and actual casing. Native discovery determines
        the owning module for nested examples and source-less family roots.

    .PARAMETER TestSubscriptionIds
        Complete nonempty JSON array of id/name objects with optional tag strings.
        Missing tags mean General. The entire pool is validated before filtering,
        including duplicate subscription GUIDs across different tags.

    .PARAMETER RandomSeed
        Nonnegative seed for the stable subscription permutation. Defaults to zero.

    .PARAMETER CaseIndex
        Nonnegative round-robin position within the selected tag's permutation.
        This is not an original pool index. Defaults to zero.

    .PARAMETER SkipModuleVersionCheck
        Skip the PowerShell Gallery version check for source or offline callers.
        A warning is written once. Selection itself makes no network calls.

    .EXAMPLE
        PS> Select-AvmTestSubscription -Path $repo -ModulePath 'avm/res/storage/storage-account' -TestSubscriptionIds $pool -RandomSeed 42 -CaseIndex 3 -SkipModuleVersionCheck
        Selects a subscription for the exact module without reading Azure state.

    .EXAMPLE
        PS> Select-AvmTestSubscription -Path $repo -ModulePath 'avm/res/network/virtual-network' -Example 'subnet/tests/e2e/defaults' -TestSubscriptionIds $pool -RandomSeed 42 -SkipModuleVersionCheck
        Uses the discovered subnet module's exact reservation, not its parent's.

    .OUTPUTS
        PSCustomObject with ModulePath, SubscriptionId, Name, Tag, Index and Key.
        ModulePath identifies the owning module. Index is the original zero-based
        pool index. SubscriptionId preserves its supplied spelling; Key is
        lowercase SHA-256 hex over the lowercase canonical GUID D representation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModulePath,

        [ValidateNotNullOrEmpty()]
        [string] $Example,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TestSubscriptionIds,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $RandomSeed = 0,

        [ValidateRange(0, [int]::MaxValue)]
        [int] $CaseIndex = 0,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($root.PSProvider.Name -cne 'FileSystem' -or -not $root.PSIsContainer) {
        throw [AvmConfigurationException]::new('Subscription selection Path must be a filesystem repository directory.')
    }

    $ownerPath = $ModulePath
    if ($PSBoundParameters.ContainsKey('Example')) {
        $null = Get-AvmBicepTestSubscriptionTag -RepositoryRoot $root.FullName -ModulePath $ModulePath
        $context = [pscustomobject]@{
            Root      = [System.IO.Path]::Combine([string[]](@($root.FullName) + $ModulePath.Split('/')))
            Ecosystem = 'bicep'
            Kind      = 'bicep-module'
        }
        $cases = @(Get-AvmBicepTestCase -Context $context -Recurse | Where-Object {
                $_.RelativeDirectory -ceq $Example -or $_.RelativePath -ceq $Example
            })
        if ($cases.Count -ne 1 -or $cases[0].Ignored) {
            throw [AvmConfigurationException]::new(
                'Subscription selection Example must identify exactly one runnable native test by its exact module-relative directory or main.test.bicep path.')
        }
        $ownerPath = [System.IO.Path]::GetRelativePath($root.FullName, $cases[0].ModuleRoot).Replace('\', '/')
    }

    $selected = Select-AvmBicepWorkflowSubscription -PoolJson $TestSubscriptionIds `
        -RepositoryRoot $root.FullName -ModulePath $ownerPath -RandomSeed $RandomSeed -CaseIndex $CaseIndex
    return [pscustomobject]@{
        ModulePath     = $ownerPath
        SubscriptionId = $selected.SubscriptionId
        Name           = $selected.Name
        Tag            = $selected.Tag
        Index          = $selected.Index
        Key            = $selected.Key
    }
}
