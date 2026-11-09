function Test-AvmMcrRepository {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $Repository
    )

    Set-StrictMode -Version 3.0
    $uriProperty = $Repository.PSObject.Properties['Uri']
    if ($null -eq $uriProperty -or [string]::IsNullOrWhiteSpace([string]$uriProperty.Value)) {
        return $false
    }

    $uri = $null
    if (-not [uri]::TryCreate([string]$uriProperty.Value, [UriKind]::Absolute, [ref]$uri)) {
        return $false
    }

    return $uri.Scheme -ceq 'https' -and
    $uri.Host -ceq 'mcr.microsoft.com' -and
    $uri.IsDefaultPort -and
    $uri.AbsolutePath -in @('', '/') -and
    [string]::IsNullOrEmpty($uri.Query) -and
    [string]::IsNullOrEmpty($uri.Fragment) -and
    [string]::IsNullOrEmpty($uri.UserInfo)
}

function Get-AvmMcrAuthoringVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [switch] $Refresh
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Refresh) {
        $script:AvmMcrAuthoringVersion = $null
        $script:AvmMcrAuthoringVersionCheckCompleted = $false
    }

    if ($env:AVM_SKIP_MCR_VERSION_CHECK -eq '1') {
        Write-AvmLog 'MCR version lookup: skipped by AVM_SKIP_MCR_VERSION_CHECK=1' -Level Verbose
        return
    }
    if ($env:AVM_OFFLINE -eq '1') {
        Write-AvmLog 'MCR version lookup: skipped by AVM_OFFLINE=1' -Level Verbose
        return
    }

    $repositories = @(Get-PSResourceRepository -ErrorAction Stop)
    if (@($repositories | Where-Object { Test-AvmMcrRepository -Repository $_ }).Count -gt 0) {
        Write-AvmLog 'MCR version lookup: skipped because MCR is already registered' -Level Verbose
        return
    }

    if ($script:AvmMcrAuthoringVersionCheckCompleted) {
        return $script:AvmMcrAuthoringVersion
    }

    $uri = 'https://mcr.microsoft.com/v2/psresource/avm.authoring/tags/list'
    $response = Invoke-AvmWebRequest -Uri $uri -Headers @{ Accept = 'application/json' } `
        -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 20 `
        -RetryMaxAttempts (Get-AvmNetworkRetryPolicy).AdvisoryMaxAttempts `
        -Label 'MCR Avm.Authoring tag-list request'
    if ([int]$response.StatusCode -ne 200) {
        throw [AvmGalleryLookupException]::new(
            "MCR Avm.Authoring tag-list request returned HTTP $($response.StatusCode).")
    }

    $document = $null
    try {
        $document = [System.Text.Json.JsonDocument]::Parse([string]$response.Content)
        $root = $document.RootElement
        $name = [System.Text.Json.JsonElement]::new()
        $tags = [System.Text.Json.JsonElement]::new()
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
            -not $root.TryGetProperty('name', [ref]$name) -or
            $name.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            $name.GetString() -cne 'psresource/avm.authoring' -or
            -not $root.TryGetProperty('tags', [ref]$tags) -or
            $tags.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
            throw [AvmGalleryLookupException]::new(
                'MCR Avm.Authoring tag-list response does not contain the expected repository and tags.')
        }

        $versions = [System.Collections.Generic.List[version]]::new()
        $seenTags = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($tag in $tags.EnumerateArray()) {
            $version = $null
            if ($tag.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                $tag.GetString() -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$' -or
                -not [version]::TryParse($tag.GetString(), [ref]$version) -or
                -not $seenTags.Add($tag.GetString())) {
                throw [AvmGalleryLookupException]::new(
                    'MCR Avm.Authoring tag-list response contains an invalid or duplicate version tag.')
            }
            $versions.Add($version)
        }
        if ($versions.Count -eq 0) {
            throw [AvmGalleryLookupException]::new(
                'MCR Avm.Authoring tag-list response contains no stable version tags.')
        }

        $script:AvmMcrAuthoringVersion = $versions | Sort-Object -Descending | Select-Object -First 1
        $script:AvmMcrAuthoringVersionCheckCompleted = $true
        return $script:AvmMcrAuthoringVersion
    }
    catch [System.Text.Json.JsonException] {
        throw [AvmGalleryLookupException]::new(
            'MCR Avm.Authoring tag-list response is not valid JSON.',
            $_.Exception)
    }
    finally {
        if ($null -ne $document) {
            $document.Dispose()
        }
    }
}
