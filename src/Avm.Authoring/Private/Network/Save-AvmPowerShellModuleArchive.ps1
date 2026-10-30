function Save-AvmPowerShellModuleArchive {
    [CmdletBinding(DefaultParameterSetName = 'Pinned')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]*$')]
        [string] $Name,
        [Parameter(Mandatory)] [version] $Version,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory, ParameterSetName = 'Pinned')]
        [ValidatePattern('^[0-9a-f]{64}$')]
        [string] $ExpectedSha256,
        [Parameter(Mandatory, ParameterSetName = 'Override')]
        [switch] $UnverifiedToolVersionOverride
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($env:AVM_OFFLINE -eq '1') {
        throw [AvmConfigurationException]::new("AVM_OFFLINE=1: refusing to download $Name $Version from configured PowerShell repositories.")
    }
    if ($PSCmdlet.ParameterSetName -eq 'Override' -and -not $UnverifiedToolVersionOverride) {
        throw [ArgumentException]::new('An unverified download requires an explicit tool version override.')
    }

    $protocols = [Net.SecurityProtocolType]::Tls12
    if ($null -ne [Net.SecurityProtocolType].GetField('Tls13')) {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocols

    $directory = Split-Path -Parent $Destination
    $null = New-Item -ItemType Directory -Path $directory -Force
    $packagePath = "$Destination.nupkg"
    try {
        $source = Invoke-AvmPSRepositoryOperation -Action {
            param($RepositoryName, $Repository)
            $uri = [uri]$Repository.Uri
            if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('https', 'file')) {
                throw [AvmConfigurationException]::new("PowerShell repository '$RepositoryName' must use HTTPS or a local file URI.")
            }
            $temporary = Join-Path $directory ("repository-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $temporary
            try {
                Write-AvmLog "Downloading $Name $Version from configured PowerShell repository '$RepositoryName'." -Level Verbose | Out-Null
                $null = Invoke-AvmRetry -RetryActivity "Downloading $Name $Version from $RepositoryName" -RetryAction {
                    Save-PSResource -Name $Name -Version $Version.ToString() -Repository $RepositoryName `
                        -Path $temporary -AsNupkg -SkipDependencyCheck -TrustRepository -Quiet -ErrorAction Stop
                }
                $packages = @(Get-ChildItem -LiteralPath $temporary -Filter '*.nupkg' -File -Recurse)
                if ($packages.Count -ne 1 -or $packages[0].Name -ine "$Name.$Version.nupkg") {
                    throw [AvmToolException]::new("Repository '$RepositoryName' did not provide exactly one $Name $Version package.", 'AVM1013')
                }
                Move-Item -LiteralPath $packages[0].FullName -Destination $packagePath -Force
                return $uri.AbsoluteUri
            }
            finally {
                Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction Stop -ProgressAction SilentlyContinue
            }
        }

        $verification = @{
            Url         = ([uri]::new([IO.Path]::GetFullPath($packagePath))).AbsoluteUri
            Destination = $Destination
        }
        if ($UnverifiedToolVersionOverride) { $verification.UnverifiedToolVersionOverride = $true }
        else { $verification.ExpectedSha256 = $ExpectedSha256 }
        $null = Invoke-AvmHttp @verification
        return $source
    }
    finally {
        if (Test-Path -LiteralPath $packagePath) {
            Remove-Item -LiteralPath $packagePath -Force -ErrorAction Stop
        }
    }
}
