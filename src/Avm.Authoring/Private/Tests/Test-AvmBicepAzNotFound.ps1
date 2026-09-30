function Test-AvmBicepAzNotFound {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $StdErr
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    return [regex]::IsMatch(
        $StdErr,
        '^\s*(?:ERROR:\s*)?\((?:ResourceNotFound|DeploymentNotFound|PolicyDefinitionNotFound|PolicySetDefinitionNotFound|RoleDefinitionNotFound|NotFound)\)(?:\s|:)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
