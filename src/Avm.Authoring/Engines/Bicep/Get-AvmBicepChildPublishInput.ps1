function Get-AvmBicepChildPublishInput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Scopes
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $children = @(foreach ($scope in $Scopes) {
            if ($scope.IsTopLevel) { continue }
            $entries = @(Get-ChildItem -LiteralPath $scope.Path -Force -ErrorAction Stop |
                    Where-Object { $_.Name -ieq 'version.json' })
            if ($entries.Count -eq 0) { continue }
            @{
                Scope     = $scope
                Entries   = $entries
                IssuePath = Join-Path $scope.Path 'version.json'
            }
        })
    $allowlist = $null
    $readError = $null
    if ($children.Count -gt 0) {
        try { $allowlist = Get-AvmBicepChildPublishAllowlist -RepositoryRoot $RepositoryRoot }
        catch [AvmConfigurationException] { $readError = $_.Exception.Message }
    }
    return @{
        Children  = $children
        Allowlist = $allowlist
        ReadError = $readError
        IssuePath = Join-Path -Path $RepositoryRoot -ChildPath '.avm' -AdditionalChildPath 'child-module-publish-allowed-list.json'
    }
}
