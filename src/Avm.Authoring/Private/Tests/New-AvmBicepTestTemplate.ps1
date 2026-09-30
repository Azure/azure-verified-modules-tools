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
        [System.Collections.Generic.Dictionary[string, string]] $Tokens
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

    $content = Resolve-AvmBicepTestToken -Content ([string]$build.StdOut) `
        -SourcePath $SourcePath -Tokens $Tokens

    $template = $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
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

    if (-not $PSCmdlet.ShouldProcess($DestinationPath, 'Write temporary ARM test template')) {
        throw [AvmConfigurationException]::new("Temporary ARM test template creation was declined: $DestinationPath")
    }
    [System.IO.File]::WriteAllText($DestinationPath, $content, [System.Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Path     = $DestinationPath
        Scope    = $scope
        Template = $template
    }
}
