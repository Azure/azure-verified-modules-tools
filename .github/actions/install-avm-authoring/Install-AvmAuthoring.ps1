[CmdletBinding()]
param(
    [version] $Version,
    [ValidateSet('Install', 'Save')]
    [string] $Operation = 'Install',
    [string] $DestinationPath
)

$ErrorActionPreference = 'Stop'

if ($Operation -eq 'Save' -and [string]::IsNullOrWhiteSpace($DestinationPath)) {
    throw [ArgumentException]::new('A destination path is required when saving Avm.Authoring.')
}

function Invoke-AvmAuthoringAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Operation,
        [Parameter(Mandatory)]
        [string] $Description
    )

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return & $Operation
        }
        catch {
            if ($attempt -eq $maxAttempts) {
                throw
            }

            $delaySeconds = 5 * [math]::Pow(2, $attempt - 1)
            Write-Warning "$Description failed on attempt $attempt of ${maxAttempts}: $($_.Exception.Message). Retrying in $delaySeconds seconds."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Initialize-AvmAuthoringPSResourceGet {
    [CmdletBinding()]
    param()

    Invoke-AvmAuthoringAttempt -Description 'PSResourceGet preparation' -Operation {
        if (-not @(Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet |
                Where-Object { $_.Version -ge [version]'1.1.1' }).Count) {
            Install-Module -Name Microsoft.PowerShell.PSResourceGet -MinimumVersion 1.1.1 `
                -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module Microsoft.PowerShell.PSResourceGet -MinimumVersion 1.1.1 -ErrorAction Stop
    } | Out-Null
}

function Get-AvmAuthoringRepository {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $marUri = 'https://mcr.microsoft.com'
    $repositories = @(Get-PSResourceRepository -ErrorAction Stop)
    $hasMar = @($repositories | Where-Object {
            $uriProperty = $_.PSObject.Properties['Uri']
            $uri = if ($null -eq $uriProperty) { '' } else { ([string]$uriProperty.Value).TrimEnd('/') }
            $uri -ieq $marUri
        }).Count -gt 0
    if (-not $hasMar) {
        Register-PSResourceRepository -Name MAR -Uri "$marUri/" -ApiVersion ContainerRegistry -Trusted -ErrorAction Stop
        $repositories = @(Get-PSResourceRepository -ErrorAction Stop)
    }

    $repositories = @($repositories | Sort-Object Priority, Name)
    if ($repositories.Count -eq 0) {
        throw [InvalidOperationException]::new('No PowerShell repositories are configured.')
    }
    return $repositories
}

function Find-AvmAuthoringRelease {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Repository,
        [version] $RequestedVersion
    )

    $hasRequestedVersion = $PSBoundParameters.ContainsKey('RequestedVersion')
    $releases = [Collections.Generic.List[object]]::new()
    $lastFailure = $null
    foreach ($source in $Repository) {
        try {
            $found = Invoke-AvmAuthoringAttempt -Description 'Avm.Authoring discovery' -Operation {
                $parameters = @{
                    Name        = 'Avm.Authoring'
                    Repository  = $source.Name
                    ErrorAction = 'Stop'
                }
                if ($hasRequestedVersion) {
                    $parameters.Version = $RequestedVersion.ToString()
                }
                @(Find-PSResource @parameters)
            }
            foreach ($candidate in $found) {
                [version] $candidateVersion = $null
                if ([version]::TryParse([string]$candidate.Version, [ref]$candidateVersion) -and
                    (-not $hasRequestedVersion -or $candidateVersion -eq $RequestedVersion)) {
                    $releases.Add([pscustomobject]@{
                            Version    = $candidateVersion
                            Repository = $source.Name
                        })
                }
            }
        }
        catch {
            $lastFailure = $_
            Write-Verbose "PowerShell repository '$($source.Name)' could not find Avm.Authoring; trying the next configured repository."
        }
    }

    if ($releases.Count -eq 0) {
        if ($null -ne $lastFailure) {
            throw $lastFailure
        }
        $description = if ($hasRequestedVersion) {
            "Avm.Authoring $RequestedVersion"
        }
        else {
            'a stable Avm.Authoring package'
        }
        throw [InvalidOperationException]::new("No $description was found in the configured PowerShell repositories.")
    }
    return $releases
}

function Invoke-AvmAuthoringOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,
        [Parameter(Mandatory)]
        [version] $SelectedVersion
    )

    Invoke-AvmAuthoringAttempt -Description "Avm.Authoring $Operation from '$Repository'" -Operation {
        $parameters = @{
            Name            = 'Avm.Authoring'
            Version         = $SelectedVersion.ToString()
            Repository      = $Repository
            TrustRepository = $true
            ErrorAction     = 'Stop'
        }
        if ($Operation -eq 'Install') {
            Install-PSResource @parameters -Scope CurrentUser
        }
        else {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            Save-PSResource @parameters -Path $DestinationPath
        }
    } | Out-Null
}

Initialize-AvmAuthoringPSResourceGet
$repositories = @(Get-AvmAuthoringRepository)
$hasVersion = $PSBoundParameters.ContainsKey('Version')

if ($hasVersion) {
    $lastFailure = $null
    foreach ($repository in $repositories) {
        try {
            $release = @(Find-AvmAuthoringRelease -Repository @($repository) -RequestedVersion $Version)
            if ($release.Count -eq 0) {
                continue
            }
            Invoke-AvmAuthoringOperation -Repository $repository.Name -SelectedVersion $Version
            [pscustomobject]@{
                Version         = $Version
                Repository      = $repository.Name
                DestinationPath = $DestinationPath
            }
            return
        }
        catch {
            $lastFailure = $_
            Write-Verbose "PowerShell repository '$($repository.Name)' could not $($Operation.ToLowerInvariant()) Avm.Authoring $Version; trying the next configured repository."
        }
    }
    if ($null -ne $lastFailure) {
        throw $lastFailure
    }
    throw [InvalidOperationException]::new("No Avm.Authoring $Version package was found in the configured PowerShell repositories.")
}

$releases = @(Find-AvmAuthoringRelease -Repository $repositories)
$selectedVersion = @($releases | Sort-Object Version -Descending | Select-Object -First 1).Version
$sourceRepositories = @(
    foreach ($repository in $repositories) {
        if ($repository.Name -in @($releases | Where-Object Version -EQ $selectedVersion | ForEach-Object Repository)) {
            $repository
        }
    }
)
$lastFailure = $null
foreach ($repository in $sourceRepositories) {
    try {
        Invoke-AvmAuthoringOperation -Repository $repository.Name -SelectedVersion $selectedVersion
        [pscustomobject]@{
            Version         = $selectedVersion
            Repository      = $repository.Name
            DestinationPath = $DestinationPath
        }
        return
    }
    catch {
        $lastFailure = $_
        Write-Verbose "PowerShell repository '$($repository.Name)' could not $($Operation.ToLowerInvariant()) Avm.Authoring $selectedVersion; trying the next configured repository."
    }
}

throw $lastFailure
