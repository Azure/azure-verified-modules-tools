#Requires -Version 7.4

[CmdletBinding()]
param(
    [string[]] $Path
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

function Get-AvmVsCodeExtensionFiles {
    [CmdletBinding()]
    param(
        [string[]] $Path
    )

    if ($null -ne $Path -and $Path.Count -gt 0) {
        return @(Get-Item -LiteralPath $Path)
    }

    return @(
        Get-ChildItem -Path $PWD.Path -Recurse -Force -File |
            Where-Object {
                $_.FullName -notmatch "[\\/]node_modules[\\/]" -and (
                    $_.FullName -match "[\\/]\.vscode[\\/]extensions\.json$" -or
                    $_.Name -eq "devcontainer.json"
                )
            } |
            Sort-Object -Property FullName
    )
}

function Get-AvmVsCodeExtensionIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo] $File
    )

    $content = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
    if ($File.Name -eq "extensions.json") {
        if ($content.PSObject.Properties["recommendations"]) {
            return @($content.recommendations)
        }
        return @()
    }

    if (
        $content.PSObject.Properties["customizations"] -and
        $content.customizations.PSObject.Properties["vscode"] -and
        $content.customizations.vscode.PSObject.Properties["extensions"]
    ) {
        return @($content.customizations.vscode.extensions)
    }

    return @()
}

function Test-AvmVsCodeExtensions {
    [CmdletBinding()]
    param(
        [string[]] $Path
    )

    $extensionSources = @{}
    foreach ($file in @(Get-AvmVsCodeExtensionFiles -Path $Path)) {
        foreach ($extensionId in @(Get-AvmVsCodeExtensionIds -File $file)) {
            if (-not $extensionSources.ContainsKey($extensionId)) {
                $extensionSources[$extensionId] = [System.Collections.Generic.List[string]]::new()
            }
            $extensionSources[$extensionId].Add($file.FullName)
        }
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($extensionId in @($extensionSources.Keys | Sort-Object)) {
        $requestBody = @{
            filters = @(
                @{
                    criteria = @(
                        @{
                            filterType = 7
                            value = $extensionId
                        }
                    )
                }
            )
            flags = 512
        } | ConvertTo-Json -Depth 10 -Compress

        $response = Invoke-RestMethod `
            -Uri "https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery" `
            -Method Post `
            -ContentType "application/json" `
            -Headers @{ Accept = "application/json;api-version=7.1-preview.1" } `
            -Body $requestBody

        $extensions = @($response.results | ForEach-Object { $_.extensions })
        if ($extensions.Count -eq 0) {
            $failures.Add("$extensionId was not found on the VS Code Marketplace.")
            continue
        }

        $extension = $extensions[0]
        $returnedId = "$($extension.publisher.publisherName).$($extension.extensionName)"
        if ($returnedId -ine $extensionId) {
            $failures.Add("$extensionId returned the mismatched ID '$returnedId'.")
            continue
        }

        $publisher = $extension.publisher
        $domain = if ($publisher.PSObject.Properties["domain"]) {
            $publisher.domain
        } else {
            $null
        }
        $isDomainVerified = if ($publisher.PSObject.Properties["isDomainVerified"]) {
            $publisher.isDomainVerified
        } else {
            $false
        }
        if ($domain -eq "https://microsoft.com" -and -not $isDomainVerified) {
            $failures.Add("$extensionId uses microsoft.com without a verified publisher domain.")
            continue
        }

        Write-Host "Validated $extensionId"
    }

    if ($failures.Count -gt 0) {
        throw [System.InvalidOperationException]::new(
            "VS Code extension validation failed:`n$($failures -join "`n")"
        )
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Test-AvmVsCodeExtensions -Path $Path
}
