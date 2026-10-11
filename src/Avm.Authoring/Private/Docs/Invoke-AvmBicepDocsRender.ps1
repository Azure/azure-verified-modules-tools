function Invoke-AvmBicepDocsRender {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Values,

        [Parameter(Mandatory)]
        [string] $SourcePath,

        [Parameter(Mandatory)]
        [string] $TemplatePath,

        [Parameter(Mandatory)]
        [string] $ToolPath,

        [Parameter(Mandatory)]
        [string] $WorkingDirectory
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $temporaryPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath (
        'avm-bicep-docs-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $json = ConvertTo-Json -InputObject $Values -Compress -Depth 10
        [System.IO.File]::WriteAllText(
            $temporaryPath, $json, [System.Text.UTF8Encoding]::new($false, $true))
        $arguments = @(
            'docs', 'generate', $SourcePath, '--stdout',
            '--custom-template-value-file-path', $temporaryPath,
            '--template-file', $TemplatePath
        )
        if ($env:AVM_OFFLINE -eq '1') {
            $arguments += '--no-restore'
        }
        return Invoke-AvmProcess -FilePath $ToolPath -ArgumentList $arguments `
            -WorkingDirectory $WorkingDirectory -IgnoreExitCode
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}
