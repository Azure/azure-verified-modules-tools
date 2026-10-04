function Save-AvmBicepCleanupState {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State,

        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $Create
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $document = ConvertTo-AvmBicepCleanupState -State $State
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw [AvmConfigurationException]::new("Cleanup state directory does not exist: $parent")
    }
    $exists = Test-Path -LiteralPath $fullPath
    if ($Create -and $exists) {
        throw [AvmConfigurationException]::new("Refusing to overwrite an existing cleanup state file: $fullPath")
    }
    if (-not $Create) {
        if (-not $exists) {
            throw [AvmConfigurationException]::new("Cleanup state disappeared: $fullPath")
        }
        $existing = Read-AvmBicepCleanupState -Path $fullPath
        if ($existing['runId'] -cne $document['runId'] -or
            $existing['tenantId'] -ine $document['tenantId'] -or
            $existing['subscriptionId'] -ine $document['subscriptionId'] -or
            $existing['environment'] -cne $document['environment']) {
            throw [AvmConfigurationException]::new('Refusing to replace cleanup state belonging to another run or Azure target.')
        }
    }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Persist non-secret Bicep cleanup state')) {
        return
    }
    $temporary = Join-Path $parent ('.avm-cleanup-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $options = [System.IO.FileStreamOptions]::new()
        $options.Mode = [System.IO.FileMode]::CreateNew
        $options.Access = [System.IO.FileAccess]::Write
        $options.Share = [System.IO.FileShare]::None
        $options.Options = [System.IO.FileOptions]::WriteThrough
        if (-not $IsWindows) {
            $options.UnixCreateMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        }
        $stream = [System.IO.FileStream]::new($temporary, $options)
        try {
            $json = (ConvertTo-Json -InputObject $document -Depth 10 -Compress -WarningAction Stop) + "`n"
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        [System.IO.File]::Move($temporary, $fullPath, -not $Create)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
        }
    }
}
