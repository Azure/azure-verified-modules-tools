function New-AvmBicepTestTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $DestinationPath,

        [Parameter(Mandatory)]
        [string] $BicepPath,

        [Parameter(Mandatory)]
        [System.Collections.Generic.Dictionary[string, string]] $Tokens,

        [System.Collections.Generic.Dictionary[string, string]] $ScopedTokens,

        [switch] $RequireScopedTokens,

        [string] $OwnedGroupRunId,

        [string] $SourceRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $build = Invoke-AvmProcess -FilePath $BicepPath `
        -ArgumentList @('build', '--stdout', $SourcePath) -IgnoreExitCode
    if ($build.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($build.StdOut)) {
        $message = Add-AvmProcessFailureDetail `
            -Message "Bicep test compilation failed for '$SourcePath' (exit $($build.ExitCode))." `
            -StdErr $build.StdErr
        throw [AvmProcessException]::new($message)
    }

    $template = [string]$build.StdOut | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($template -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new("Bicep test compilation did not return an ARM object: $SourcePath")
    }
    $schema = [string]$template['$schema']
    $schemaPrefix = '^https://schema\.management\.azure\.com/schemas/\d{4}-\d{2}-\d{2}/'
    $scope = switch -Regex ($schema) {
        "${schemaPrefix}deploymentTemplate\.json#?$" { 'group'; break }
        "${schemaPrefix}subscriptionDeploymentTemplate\.json#?$" { 'sub'; break }
        "${schemaPrefix}managementGroupDeploymentTemplate\.json#?$" { 'mg'; break }
        "${schemaPrefix}tenantDeploymentTemplate\.json#?$" { 'tenant'; break }
        default {
            throw [AvmConfigurationException]::new(
                "Bicep test '$SourcePath' compiled to an unsupported ARM template schema: $schema")
        }
    }

    if ($RequireScopedTokens -and $scope -ne 'group' -and $null -eq $ScopedTokens) {
        throw [AvmConfigurationException]::new(
            "Bicep e2e test '$SourcePath' requires an explicit GUID -TenantId for $scope scope.")
    }
    $effectiveTokens = if ($scope -ne 'group' -and $null -ne $ScopedTokens) {
        $ScopedTokens
    }
    else {
        $Tokens
    }
    $content = Resolve-AvmBicepTestToken -Content ([string]$build.StdOut) `
        -SourcePath $SourcePath -Tokens $effectiveTokens
    $template = $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $hasGroupDeployment = $false
    if ($scope -eq 'sub' -and -not [string]::IsNullOrWhiteSpace($OwnedGroupRunId)) {
        if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
            throw [AvmConfigurationException]::new(
                'Bicep e2e group staging requires the module source root.')
        }
        $relative = [System.IO.Path]::GetRelativePath(
            [System.IO.Path]::GetFullPath($SourceRoot),
            [System.IO.Path]::GetFullPath($DestinationPath))
        $parentPrefix = '..' + [System.IO.Path]::DirectorySeparatorChar
        if ($relative -eq '.' -or
            (-not [System.IO.Path]::IsPathRooted($relative) -and
            $relative -ne '..' -and
            -not $relative.StartsWith($parentPrefix, [System.StringComparison]::Ordinal))) {
            throw [AvmConfigurationException]::new(
                "Bicep e2e group template must be staged outside module source: $DestinationPath")
        }
        $ownership = Set-AvmBicepTestGroupOwnership -Template $template `
            -RunId $OwnedGroupRunId -SourcePath $SourcePath -Confirm:$false
        $hasGroupDeployment = $ownership.HasGroupDeployment
        if ($ownership.Tagged) {
            $content = ConvertTo-Json -InputObject $template -Depth 100 -Compress `
                -WarningAction Stop -ErrorAction Stop
            $template = $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
    }
    if (-not $PSCmdlet.ShouldProcess($DestinationPath, 'Write temporary ARM test template')) {
        throw [AvmConfigurationException]::new("Temporary ARM test template creation was declined: $DestinationPath")
    }
    [System.IO.File]::WriteAllText($DestinationPath, $content, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Path               = $DestinationPath
        Scope              = $scope
        Template           = $template
        HasGroupDeployment = $hasGroupDeployment
    }
}
