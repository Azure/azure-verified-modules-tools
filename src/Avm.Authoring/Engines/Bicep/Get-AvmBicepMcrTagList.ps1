function Get-AvmBicepMcrTagList {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $ModulePath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($ModulePath -cnotmatch '^avm/(?:res|ptn|utl)(?:/[a-z0-9]+(?:-[a-z0-9]+)*){2,}\z') {
        throw [AvmConfigurationException]::new("Invalid Bicep module path for MCR: '$ModulePath'.")
    }
    if ($env:AVM_OFFLINE -eq '1') {
        throw [AvmConfigurationException]::new(
            "AVM_OFFLINE=1: published tags for '$ModulePath' cannot be verified without MCR.")
    }

    $registryName = "bicep/$ModulePath"
    $expectedPath = "/v2/$registryName/tags/list"
    $uri = [uri]::new("https://mcr.microsoft.com$expectedPath")
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $published = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $pageQueryPattern = '^\?(?:(?:n=[1-9][0-9]{0,3}&)?last=(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:&n=[1-9][0-9]{0,3})?)\z'
    $versionPattern = '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z'
    for ($page = 0; $page -lt 100; $page++) {
        if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'mcr.microsoft.com' -or
            -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
            $uri.AbsolutePath -cne $expectedPath -or
            ($page -eq 0 -and $uri.Query) -or
            ($page -gt 0 -and $uri.Query -cnotmatch $pageQueryPattern)) {
            throw [AvmConfigurationException]::new(
                "MCR tag-list page for '$ModulePath' has an unapproved HTTPS host, path, or query.")
        }
        if (-not $seen.Add($uri.AbsoluteUri)) {
            throw [AvmConfigurationException]::new(
                "MCR tag-list pagination repeated a page for '$ModulePath'.")
        }

        try {
            $response = Invoke-WebRequest -Uri $uri -Method Get -Headers @{ Accept = 'application/json' } `
                -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 20 -ErrorAction Stop
        }
        catch [System.Net.Http.HttpRequestException], [System.Net.WebException],
        [System.TimeoutException], [System.Management.Automation.RuntimeException] {
            throw [AvmConfigurationException]::new(
                "Cannot read published tags from '$($uri.AbsoluteUri)': $($_.Exception.Message)")
        }

        if ($null -eq $response.BaseResponse -or
            $null -eq $response.BaseResponse.RequestMessage -or
            $null -eq $response.BaseResponse.RequestMessage.RequestUri -or
            $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri -cne $uri.AbsoluteUri) {
            throw [AvmConfigurationException]::new(
                "MCR tag-list response for '$ModulePath' cannot be attributed to its requested endpoint.")
        }
        if ($response.StatusCode -notin @(200, 404)) {
            throw [AvmConfigurationException]::new(
                "MCR tag-list request for '$ModulePath' returned HTTP $($response.StatusCode); published versions are unknown.")
        }

        $document = $null
        try {
            $document = [System.Text.Json.JsonDocument]::Parse([string]$response.Content)
        }
        catch [System.Text.Json.JsonException] {
            throw [AvmConfigurationException]::new(
                "MCR tag-list response for '$ModulePath' is not valid JSON: $($_.Exception.Message)")
        }
        try {
            $root = $document.RootElement
            $entry = [System.Text.Json.JsonElement]::new()
            if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                throw [AvmConfigurationException]::new(
                    "MCR tag-list response for '$ModulePath' must be a JSON object.")
            }
            if ($response.StatusCode -eq 404) {
                if ($page -ne 0 -or
                    -not $root.TryGetProperty('errors', [ref]$entry) -or
                    $entry.ValueKind -ne [System.Text.Json.JsonValueKind]::Array -or
                    $entry.GetArrayLength() -ne 1) {
                    throw [AvmConfigurationException]::new(
                        "MCR returned HTTP 404 for '$ModulePath' without a single registry not-found error.")
                }
                $registryError = $entry[0]
                $code = [System.Text.Json.JsonElement]::new()
                if ($registryError.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
                    -not $registryError.TryGetProperty('code', [ref]$code) -or
                    $code.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                    $code.GetString() -cne 'NAME_UNKNOWN') {
                    throw [AvmConfigurationException]::new(
                        "MCR returned HTTP 404 for '$ModulePath' without NAME_UNKNOWN.")
                }
                $detail = [System.Text.Json.JsonElement]::new()
                if ($registryError.TryGetProperty('detail', [ref]$detail) -and
                    $detail.ValueKind -ne [System.Text.Json.JsonValueKind]::Null) {
                    $name = [System.Text.Json.JsonElement]::new()
                    if ($detail.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
                        -not $detail.TryGetProperty('name', [ref]$name) -or
                        $name.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                        $name.GetString() -cne $registryName) {
                        throw [AvmConfigurationException]::new(
                            "MCR returned HTTP 404 for a different repository than '$registryName'.")
                    }
                }
                return [pscustomobject]@{ Exists = $false; Tags = $published }
            }

            $name = [System.Text.Json.JsonElement]::new()
            if (-not $root.TryGetProperty('name', [ref]$name) -or
                $name.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                $name.GetString() -cne $registryName -or
                -not $root.TryGetProperty('tags', [ref]$entry) -or
                $entry.ValueKind -ne [System.Text.Json.JsonValueKind]::Array) {
                throw [AvmConfigurationException]::new(
                    "MCR tag-list response for '$ModulePath' lacks the expected repository name and tags array.")
            }
            foreach ($tag in $entry.EnumerateArray()) {
                $parsed = $null
                if ($tag.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
                    $tag.GetString() -cnotmatch $versionPattern -or
                    -not [version]::TryParse($tag.GetString(), [ref]$parsed) -or
                    -not $published.Add($tag.GetString())) {
                    throw [AvmConfigurationException]::new(
                        "MCR tag-list response for '$ModulePath' contains an invalid or duplicate version tag.")
                }
            }
        }
        finally {
            $document.Dispose()
        }

        if ($null -eq $response.Headers) {
            throw [AvmConfigurationException]::new(
                "MCR tag-list response for '$ModulePath' has no inspectable headers.")
        }
        $link = @($response.Headers['Link']) -join ','
        if ([string]::IsNullOrWhiteSpace($link)) {
            return [pscustomobject]@{ Exists = $true; Tags = $published }
        }
        $next = [regex]::Match($link, '^\s*<(?<url>[^<>]+)>;\s*rel="?next"?\s*\z')
        if (-not $next.Success) {
            throw [AvmConfigurationException]::new(
                "MCR tag-list response for '$ModulePath' has an uninspectable pagination link.")
        }
        $uri = [uri]::new($uri, $next.Groups['url'].Value)
    }
    throw [AvmConfigurationException]::new(
        "MCR tag-list response for '$ModulePath' exceeded the page limit; published versions are unknown.")
}
