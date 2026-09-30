#Requires -Version 7.4

function Invoke-AvmStandardGitHubLabelSync {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][object[]] $Labels,
        [Parameter(Mandatory)][string] $GitHubPath,
        [Parameter(Mandatory)][string[]] $Repositories,
        [switch] $Apply
    )

    foreach ($repository in $Repositories) {
        $result = Invoke-AvmStandardLabelProcess -FilePath $GitHubPath -ArgumentList @(
            'label', 'list', '--repo', $repository, '--limit', '1000', '--json', 'name,description,color'
        )
        $existing = @(ConvertFrom-Json -InputObject $result.StdOut -ErrorAction Stop)
        if ($existing.Count -eq 0) {
            throw [System.IO.InvalidDataException]::new("GitHub returned no labels for $repository; refusing to treat this as an empty repository.")
        }
        $changes = @(Get-AvmStandardGitHubLabelChanges -Labels $Labels -ExistingLabels $existing)
        Write-Output "$repository needs $($changes.Count) label change(s)."

        $applied = 0
        foreach ($change in $changes) {
            Write-Output "$($change.Action): $($change.Label.Name)"
            if ($Apply -and $PSCmdlet.ShouldProcess("$repository / $($change.Label.Name)", $change.Action)) {
                $null = Invoke-AvmStandardLabelProcess -FilePath $GitHubPath -ArgumentList @(
                    'label', 'create', $change.Label.Name, '--repo', $repository,
                    '--color', $change.Label.Color, '--description', $change.Label.GitHubDescription, '--force'
                )
                $applied++
            }
        }

        if ($applied -gt 0) {
            $result = Invoke-AvmStandardLabelProcess -FilePath $GitHubPath -ArgumentList @(
                'label', 'list', '--repo', $repository, '--limit', '1000', '--json', 'name,description,color'
            )
            $remaining = @(Get-AvmStandardGitHubLabelChanges -Labels $Labels -ExistingLabels @(
                    ConvertFrom-Json -InputObject $result.StdOut -ErrorAction Stop
                ))
            if ($remaining.Count -gt 0) {
                throw [System.InvalidOperationException]::new("$repository still has $($remaining.Count) standard label change(s) after synchronization.")
            }
        }
    }
}
