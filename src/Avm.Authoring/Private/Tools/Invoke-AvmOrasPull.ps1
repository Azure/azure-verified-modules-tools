function Invoke-AvmOrasPull {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Reference,

        [Parameter(Mandatory)]
        [ValidateSet(
            'windows-amd64',
            'windows-arm64',
            'linux-amd64',
            'linux-arm64',
            'darwin-amd64',
            'darwin-arm64'
        )]
        [string] $Platform,

        [Parameter(Mandatory)]
        [string] $Destination
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Reference -cnotmatch '^[a-z0-9][a-z0-9.-]*(?::[0-9]+)?/[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$') {
        throw [System.ArgumentException]::new(
            "ORAS reference must use an immutable lowercase sha256 digest: '$Reference'.",
            'Reference')
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new(
            "ORAS pull destination does not exist: '$Destination'.")
    }

    $os, $arch = $Platform.Split('-', 2)
    $oras = Resolve-AvmTool -Name 'oras'
    Invoke-AvmProcess `
        -FilePath $oras.Path `
        -ArgumentList @('pull', '--platform', "$os/$arch", '--output', $Destination, $Reference) `
        -WorkingDirectory $Destination `
        -RetryNetworkFailure `
        -Label ("ORAS pull {0} ({1}/{2})" -f $Reference, $os, $arch)
}
