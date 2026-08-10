function Resolve-AvmPolicyBundle {
    <#
    .SYNOPSIS
        Materialise a named policy bundle from the pinned policy library.

    .DESCRIPTION
        Projects the 'policyLibrary' section of the pin manifest
        (Resources/avm.pins.jsonc) into the PascalCase descriptor shape that
        Resolve-AvmPinnedAsset consumes, then materialises it.

        No repository configuration is required: the pinned library ships with
        the module, so 'avm check policy' works on a clean checkout.

        Template expansion for urlTemplate and archiveRoot:

          {repository} - e.g. 'Azure/policy-library-avm'
          {ref}        - e.g. 'v1.0.0'
          {version}    - the ref with any leading 'v' stripped, e.g. '1.0.0'

        The GitHub tarball wraps everything in '<repo>-<version>/', and
        Expand-AvmToolArchive does not strip that directory, so the effective
        sub-path handed to Resolve-AvmPinnedAsset is
        '<archiveRoot>/<bundles[Name]>'.

        AVM_POLICY_LIBRARY_REF overrides the pinned ref for testing an
        unreleased policy set. AVM_POLICY_LIBRARY_SHA256 is then mandatory --
        a ref without a matching hash is rejected so there is never an
        unverified download path.

    .PARAMETER Name
        Bundle name, e.g. 'avm-policy-aprl' or 'avm-policy-avmsec'. Must be a
        key of policyLibrary.bundles.

    .PARAMETER Pins
        Pre-loaded pin manifest. Defaults to Read-AvmPins.

    .PARAMETER AllowFileUrls
        Forwarded to Resolve-AvmPinnedAsset for fixtures.

    .OUTPUTS
        The pscustomobject returned by Resolve-AvmPinnedAsset.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [hashtable] $Pins,

        [switch] $AllowFileUrls
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $Pins) { $Pins = Read-AvmPins }

    if (-not $Pins.ContainsKey('policyLibrary')) {
        throw [AvmConfigurationException]::new(
            "avm.pins: the pin manifest has no 'policyLibrary' section, so policy bundle '$Name' cannot be resolved.")
    }

    $library = $Pins['policyLibrary']
    if (-not $library.ContainsKey('bundles') -or -not $library['bundles'].ContainsKey($Name)) {
        $known = if ($library.ContainsKey('bundles')) { ($library['bundles'].Keys | Sort-Object) -join "', '" } else { '' }
        throw [AvmConfigurationException]::new(
            "avm.pins: policy bundle '$Name' is not declared in policyLibrary.bundles (known: '$known').")
    }

    $ref = [string]$library['ref']
    $sha = [string]$library['sha256']

    # Paired override: a ref without its hash would mean an unverified download.
    $refOverride = $env:AVM_POLICY_LIBRARY_REF
    $shaOverride = $env:AVM_POLICY_LIBRARY_SHA256
    if (-not [string]::IsNullOrWhiteSpace($refOverride)) {
        if ([string]::IsNullOrWhiteSpace($shaOverride)) {
            throw [AvmConfigurationException]::new(
                'AVM_POLICY_LIBRARY_REF is set but AVM_POLICY_LIBRARY_SHA256 is not. Both are required so the override archive is still checksum-verified.')
        }
        $ref = $refOverride.Trim()
        $sha = $shaOverride.Trim().ToLowerInvariant()
        Write-AvmLog ("policy-bundle: using AVM_POLICY_LIBRARY_REF override {0}" -f $ref) -Level Verbose | Out-Null
    }
    elseif (-not [string]::IsNullOrWhiteSpace($shaOverride)) {
        throw [AvmConfigurationException]::new(
            'AVM_POLICY_LIBRARY_SHA256 is set but AVM_POLICY_LIBRARY_REF is not. Both are required so the override is unambiguous.')
    }

    $version = $ref -replace '^v', ''
    $expand = {
        param([string] $Template)
        $Template.
        Replace('{repository}', [string]$library['repository']).
        Replace('{ref}', $ref).
        Replace('{version}', $version)
    }

    $source = & $expand ([string]$library['urlTemplate'])
    $archiveRoot = & $expand ([string]$library['archiveRoot'])

    $bundlePath = [string]$library['bundles'][$Name]
    $subPath = if ([string]::IsNullOrWhiteSpace($archiveRoot)) { $bundlePath } else { "$archiveRoot/$bundlePath" }
    Write-AvmLog ("policy-bundle: resolved {0}; ref={1}; source={2}; path={3}" -f $Name, $ref, $source, $subPath) -Level Verbose | Out-Null

    $descriptor = [pscustomobject]@{
        Source = $source
        Ref    = $ref
        Sha256 = $sha
        Path   = $subPath
        Type   = 'archive'
    }

    Resolve-AvmPinnedAsset -Name $Name -Asset $descriptor -AllowFileUrls:$AllowFileUrls
}
