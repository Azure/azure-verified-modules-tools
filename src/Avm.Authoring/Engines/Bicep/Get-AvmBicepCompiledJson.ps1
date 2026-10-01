function Get-AvmBicepCompiledJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $ToolPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $arguments = @('build', '--stdout', $SourcePath)
    if ($env:AVM_OFFLINE -eq '1') {
        $arguments += '--no-restore'
    }
    $result = Invoke-AvmProcess -FilePath $ToolPath -ArgumentList $arguments
    if ($result.ExitCode -ne 0) {
        $message = Add-AvmProcessFailureDetail `
            -Message "Bicep build failed for '$SourcePath' (exit $($result.ExitCode))." `
            -StdOut $result.StdOut `
            -StdErr $result.StdErr
        throw [AvmConfigurationException]::new(
            $message)
    }
    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        throw [AvmConfigurationException]::new("Bicep build returned no compiled JSON for '$SourcePath'.")
    }

    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 1024
    try {
        $document = [System.Text.Json.JsonDocument]::Parse($result.StdOut, $options)
    }
    catch [System.Text.Json.JsonException] {
        throw [AvmConfigurationException]::new(
            "Bicep build returned invalid JSON for '$SourcePath': $($_.Exception.Message)")
    }
    try {
        $schema = [System.Text.Json.JsonElement]::new()
        $version = [System.Text.Json.JsonElement]::new()
        $resources = [System.Text.Json.JsonElement]::new()
        $root = $document.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
            -not $root.TryGetProperty('$schema', [ref]$schema) -or
            $schema.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            [string]::IsNullOrWhiteSpace($schema.GetString()) -or
            -not $root.TryGetProperty('contentVersion', [ref]$version) -or
            $version.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or
            -not $root.TryGetProperty('resources', [ref]$resources)) {
            throw [AvmConfigurationException]::new(
                "Bicep build returned JSON without the required ARM template fields for '$SourcePath'.")
        }
        $validResources = $resources.ValueKind -eq [System.Text.Json.JsonValueKind]::Array
        if ($resources.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            $languageVersion = [System.Text.Json.JsonElement]::new()
            $validResources = $root.TryGetProperty('languageVersion', [ref]$languageVersion) -and
            $languageVersion.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and
            $languageVersion.GetString() -ceq '2.0'
        }
        if (-not $validResources) {
            throw [AvmConfigurationException]::new(
                "Bicep build returned JSON without the required ARM template fields for '$SourcePath'.")
        }
    }
    finally {
        $document.Dispose()
    }

    return $result.StdOut
}
