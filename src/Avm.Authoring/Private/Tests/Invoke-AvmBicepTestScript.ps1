function Invoke-AvmBicepTestScript {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [hashtable] $Parameters = @{},

        [hashtable] $EnvVars = @{}
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not $PSCmdlet.ShouldProcess($Path, 'Run Bicep test script in the current PowerShell process')) {
        throw [AvmConfigurationException]::new('Bicep test script execution was declined.')
    }
    $location = Get-Location
    $saved = @{}
    foreach ($name in $EnvVars.psbase.Keys) { $saved[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process') }
    $exitVariable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $savedExitCode = if ($null -ne $exitVariable) { $exitVariable.Value } else { $null }
    try {
        foreach ($name in $EnvVars.psbase.Keys) {
            if ($null -eq $EnvVars[$name]) {
                [System.Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
            }
            else { [System.Environment]::SetEnvironmentVariable($name, [string]$EnvVars[$name], 'Process') }
        }
        Set-Location -LiteralPath $WorkingDirectory
        $global:LASTEXITCODE = 0
        $output = @(& $Path @Parameters)
        $exitCode = $global:LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }
    catch {
        if ((Get-AvmBicepDeploymentErrorKind -ErrorRecord $_) -eq 'Cancellation') { throw }
        throw [AvmProcessException]::new("Bicep test script failed: '$([System.IO.Path]::GetFileName($Path))'.")
    }
    finally {
        foreach ($name in $saved.psbase.Keys) {
            if ($null -eq $saved[$name]) {
                [System.Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
            }
            else { [System.Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
        if ($null -eq $exitVariable) { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        else { $global:LASTEXITCODE = $savedExitCode }
        Set-Location -LiteralPath $location.Path
    }
}
