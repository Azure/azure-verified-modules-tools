function Initialize-AvmTerraformCommand {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        [ValidateSet('pre-commit', 'pr-check')]
        [string] $Command,

        [switch] $AllowPathFallback
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Initialize-AvmTerraformCommand requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $providerCache = Get-AvmTerraformPluginCachePath
    $schemaCache = Join-Path (Get-AvmFolder -Kind Cache) 'mapotf-provider-schema'
    $null = New-Item -ItemType Directory -Path $schemaCache -Force -ErrorAction Stop
    $initialized = [System.Collections.Generic.List[string]]::new()
    $reused = [System.Collections.Generic.List[string]]::new()

    if ($Command -eq 'pr-check') {
        $terraform = Resolve-AvmTool `
            -Name 'terraform' `
            -ModuleRoot $Context.Root `
            -AllowPathFallback:$AllowPathFallback
        $scope = Get-AvmTerraformValidationScope -Root $Context.Root
        $exampleIndex = 0
        foreach ($example in $scope.Examples) {
            $exampleIndex++
            $dataDirectory = Join-Path $example.Path '.terraform'
            $manifestPath = Join-Path -Path $dataDirectory -ChildPath 'modules' -AdditionalChildPath 'modules.json'
            if ((Test-Path -LiteralPath $dataDirectory -PathType Container) -and
                (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                $reused.Add($example.RelativePath)
                Write-AvmLog (
                    'initialize: reusing example {0}/{1}: {2}' -f
                    $exampleIndex,
                    $scope.Examples.Count,
                    $example.RelativePath) -Level Info | Out-Null
                continue
            }

            Write-AvmLog (
                'initialize: preparing example {0}/{1}: {2}' -f
                $exampleIndex,
                $scope.Examples.Count,
                $example.RelativePath) -Level Info | Out-Null
            $null = Invoke-AvmTerraformInit `
                -TerraformPath $terraform.Path `
                -WorkingDirectory $example.Path `
                -EnvVars @{ TF_PLUGIN_CACHE_DIR = $providerCache } `
                -Label ('terraform init {0}' -f $example.RelativePath) `
                -BackendFalse `
                -NoColor `
                -StreamOutput:(Test-AvmVerboseEnabled)
            $initialized.Add($example.RelativePath)
        }
    }

    return [pscustomobject][ordered]@{
        Engine                 = 'terraform'
        Status                 = 'pass'
        ProviderCache          = $providerCache
        MapotfSchemaCache      = $schemaCache
        Initialized            = $initialized.ToArray()
        Reused                 = $reused.ToArray()
        InitializedDirectories = $initialized.Count
        ReusedDirectories      = $reused.Count
    }
}
