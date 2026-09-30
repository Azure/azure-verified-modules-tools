#Requires -Version 7.4

function Read-AvmStandardGitHubLabels {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $catalog = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -AsHashtable -Depth 5
    if ($catalog -isnot [System.Collections.IDictionary] -or
        @($catalog.Keys | Where-Object { $_ -cne 'labels' }).Count -gt 0 -or
        $catalog['labels'] -isnot [array] -or $catalog['labels'].Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('The standard labels catalog must contain a nonempty labels array.')
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $catalog['labels']) {
        if ($entry -isnot [System.Collections.IDictionary] -or
            @($entry.Keys | Where-Object { $_ -cnotin @('name', 'description', 'color', 'githubDescription') }).Count -gt 0) {
            throw [System.IO.InvalidDataException]::new('Each label must have only name, description, color, and optional githubDescription fields.')
        }
        foreach ($key in @('name', 'description', 'color')) {
            if ($entry[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry[$key])) {
                throw [System.IO.InvalidDataException]::new("Each label requires a nonempty $key string.")
            }
        }

        $name = [string] $entry['name']
        $description = [string] $entry['description']
        $color = [string] $entry['color']
        $githubDescription = if ($entry.Contains('githubDescription')) {
            if ($entry['githubDescription'] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry['githubDescription'])) {
                throw [System.IO.InvalidDataException]::new("Label '$name' has an invalid githubDescription.")
            }
            [string] $entry['githubDescription']
        }
        else {
            $description
        }
        $githubDescription = $githubDescription.Trim()

        if ($name -cne $name.Trim() -or $name.Length -gt 50 -or
            $color -cnotmatch '^[0-9A-Fa-f]{6}$' -or $githubDescription.Length -gt 100 -or
            -not $names.Add($name)) {
            throw [System.IO.InvalidDataException]::new("Label '$name' has an invalid or duplicate name, color, or GitHub description.")
        }

        [pscustomobject]@{
            Name              = $name
            Description       = $description
            GitHubDescription = $githubDescription
            Color             = $color
        }
    }
}

function ConvertTo-AvmStandardGitHubLabelsCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]] $Labels)

    if ($Labels.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('Cannot publish an empty standard labels catalog.')
    }
    $rows = foreach ($label in $Labels) {
        [pscustomobject][ordered]@{
            Name        = $label.Name
            Description = $label.Description
            HEX         = $label.Color
        }
    }
    return ((@($rows | ConvertTo-Csv -NoTypeInformation -UseQuotes AsNeeded) -join "`n") + "`n")
}

function Get-AvmStandardGitHubLabelChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Labels,
        [Parameter(Mandatory)][object[]] $ExistingLabels
    )

    $existingByName = @{}
    foreach ($existing in $ExistingLabels) {
        if ($existing.PSObject.Properties['name'] -eq $null -or
            [string]::IsNullOrWhiteSpace([string] $existing.name) -or
            $existing.PSObject.Properties['color'] -eq $null -or
            $existingByName.ContainsKey([string] $existing.name)) {
            throw [System.IO.InvalidDataException]::new('GitHub returned an invalid or duplicate label.')
        }
        $existingByName[[string] $existing.name] = $existing
    }

    foreach ($label in $Labels) {
        if (-not $existingByName.ContainsKey($label.Name)) {
            [pscustomobject]@{ Action = 'Create'; Label = $label }
            continue
        }
        $existing = $existingByName[$label.Name]
        if ($existing.PSObject.Properties['description'] -eq $null) {
            throw [System.IO.InvalidDataException]::new("GitHub returned label '$($label.Name)' without a description field.")
        }
        if ([string] $existing.description -cne $label.GitHubDescription -or
            [string] $existing.color -ine $label.Color) {
            [pscustomobject]@{ Action = 'Update'; Label = $label }
        }
    }
}

function Invoke-AvmStandardLabelProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $ArgumentList
    )

    $module = Get-Module -Name Avm.Authoring
    if ($null -eq $module) {
        throw [System.InvalidOperationException]::new('Import the trusted local Avm.Authoring module before invoking GitHub.')
    }
    return & $module {
        param($Arguments)
        Invoke-AvmProcess @Arguments
    } @{ FilePath = $FilePath; ArgumentList = $ArgumentList; TimeoutSec = 300 }
}

function Assert-AvmStandardLabelPublicationCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $PullRequest,
        [Parameter(Mandatory)][object[]] $Files,
        [Parameter(Mandatory)][object[]] $Commits,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $BotLogin
    )

    if ($PullRequest['user']['login'] -cne $BotLogin -or
        $PullRequest['head']['repo']['full_name'] -cne $Repository -or
        $PullRequest['base']['ref'] -cne 'main' -or
        $PullRequest['head']['ref'] -cnotmatch '^automation/avm-labels-[0-9]+-[0-9]+$' -or
        $Files.Count -ne 1 -or $Files[0]['filename'] -cne $Path -or
        $Commits.Count -eq 0 -or
        @($Commits | Where-Object { $_['author']['login'] -cne $BotLogin }).Count -gt 0) {
        throw [System.Security.SecurityException]::new(
            "Refusing to update a labels publication not solely owned by $BotLogin in $Repository."
        )
    }
}
