function Invoke-AvmPSRepositoryOperation {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,
        [switch] $Legacy,
        [switch] $All,
        [string[]] $Repository
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $repositories = @(if ($Legacy) {
            Get-PSRepository -ErrorAction Stop
        }
        else {
            Get-PSResourceRepository -ErrorAction Stop | Sort-Object Priority, Name
        })
    if ($repositories.Count -eq 0) {
        throw [InvalidOperationException]::new('No PowerShell repositories are configured. Register a repository before installing or checking for modules.')
    }

    if ($PSBoundParameters.ContainsKey('Repository')) {
        $repositories = @($repositories | Where-Object { $_.Name -in $Repository })
        if ($repositories.Count -eq 0) {
            throw [InvalidOperationException]::new('None of the selected PowerShell repositories are still configured. Refresh the module version check and try again.')
        }
    }

    $succeeded = $false
    foreach ($configuredRepository in $repositories) {
        try {
            if (-not $All) {
                return & $Action ([string]$configuredRepository.Name) $configuredRepository
            }
            $result = @(& $Action ([string]$configuredRepository.Name) $configuredRepository)
            $succeeded = $true
            $result
        }
        catch [System.OperationCanceledException] {
            throw
        }
        catch {
            $lastFailure = $_
            Write-Verbose "PowerShell repository '$($configuredRepository.Name)' could not complete the operation; trying the next configured repository."
        }
    }
    if (-not $succeeded) {
        throw $lastFailure
    }
}
