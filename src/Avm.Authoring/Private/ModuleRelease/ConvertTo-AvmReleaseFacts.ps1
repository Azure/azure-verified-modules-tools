function ConvertTo-AvmReleaseFacts {
    <#
    .SYNOPSIS
        Validate and normalise the facts that the release decision engine reads.

    .DESCRIPTION
        The I/O layer gathers facts from GitHub. This function checks them and returns a normalised copy, so the engine never guesses about malformed input. Timestamps become canonical UTC strings, commit SHAs become lower case, and version labels become lower case.

        Contract violations throw an ArgumentException:

        - A missing or malformed repository, time, or identifier.
        - A pull request, label event, or comment listed twice.
        - An event later than Now.
        - A label present at merge but added after the merge.
        - A changed file without a path, or with a status GitHub does not use.

        A missing Freeze value means the freeze state is unknown, which counts as frozen. A missing Owners value means the owners are unknown, so only the core team is authorised.

    .PARAMETER Facts
        The raw facts. See Get-AvmReleaseDecision for the contract.

    .EXAMPLE
        ConvertTo-AvmReleaseFacts -Facts @{ Repository = 'Azure/terraform-azurerm-avm-res-example'; Now = '2026-09-07T09:00:00Z'; Freeze = 'none' }

        Returns normalised facts with no pull requests, label events, or comments.

    .OUTPUTS
        Ordered dictionary with Repository, Now, LatestVersion, MainHead, Freeze, Authorization, MergedPullRequests, LabelEvents, and Comments.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts names the release engine input contract.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Facts
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($null -eq $Facts) {
        throw [System.ArgumentException]::new('Release facts are required.')
    }
    $policy = Get-AvmReleasePolicy

    $requireText = {
        param([object] $Value, [string] $Name)
        if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
            throw [System.ArgumentException]::new("$Name must be a non-empty string.")
        }
        return $Value.Trim()
    }
    $requireNumber = {
        param([object] $Value, [string] $Name)
        if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 1) {
            throw [System.ArgumentException]::new("$Name must be a positive integer.")
        }
        return [long]$Value
    }
    $optionalText = {
        param([object] $Value, [string] $Name)
        if ($null -eq $Value) {
            return $null
        }
        if ($Value -isnot [string]) {
            throw [System.ArgumentException]::new("$Name must be a string.")
        }
        return $Value
    }
    $list = {
        param([object] $Source, [string] $Name)
        $value = Get-AvmPropertyValue -InputObject $Source -Name $Name -NoEnumerate
        if ($null -eq $value) {
            return , @()
        }
        if ($value -is [string] -or $value -is [System.Collections.IDictionary] -or $value -isnot [System.Collections.IEnumerable]) {
            throw [System.ArgumentException]::new("$Name must be an array.")
        }
        return , @($value)
    }

    $repository = & $requireText -Value (Get-AvmPropertyValue -InputObject $Facts -Name 'Repository') -Name 'Repository'
    if ($repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$') {
        throw [System.ArgumentException]::new("Repository '$repository' must be 'owner/name'.")
    }
    $now = Format-AvmReleaseTimestamp -Value (Get-AvmPropertyValue -InputObject $Facts -Name 'Now') -Name 'Now'

    $latestVersion = & $optionalText -Value (Get-AvmPropertyValue -InputObject $Facts -Name 'LatestVersion') -Name 'LatestVersion'
    $mainHead = & $optionalText -Value (Get-AvmPropertyValue -InputObject $Facts -Name 'MainHead') -Name 'MainHead'
    if ($null -ne $mainHead) {
        $mainHead = $mainHead.Trim().ToLowerInvariant()
    }

    $freeze = Get-AvmPropertyValue -InputObject $Facts -Name 'Freeze'
    if ($null -eq $freeze) {
        $freeze = 'unknown'
    }
    if (@('none', 'active', 'unknown') -cnotcontains $freeze) {
        throw [System.ArgumentException]::new("Freeze '$freeze' must be 'none', 'active', or 'unknown'.")
    }

    $authorization = Get-AvmPropertyValue -InputObject $Facts -Name 'Authorization'
    $owners = $null
    $coreTeam = $policy.CoreTeam
    $actorTeams = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $authorization) {
        $ownersValue = Get-AvmPropertyValue -InputObject $authorization -Name 'Owners' -NoEnumerate
        if ($null -ne $ownersValue) {
            $owners = [string[]]@($ownersValue | ForEach-Object { & $requireText -Value $_ -Name 'Authorization.Owners entry' })
        }
        $coreValue = Get-AvmPropertyValue -InputObject $authorization -Name 'CoreTeam'
        if ($null -ne $coreValue) {
            $coreTeam = & $requireText -Value $coreValue -Name 'Authorization.CoreTeam'
        }
        $teamsValue = Get-AvmPropertyValue -InputObject $authorization -Name 'ActorTeams'
        if ($null -ne $teamsValue) {
            if ($teamsValue -isnot [System.Collections.IDictionary]) {
                throw [System.ArgumentException]::new('Authorization.ActorTeams must map each login to its team slugs.')
            }
            foreach ($login in $teamsValue.Keys) {
                $actorTeams[[string]$login] = [string[]]@($teamsValue[$login] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            }
        }
    }

    $versionLabels = @($policy.VersionLabels)
    $pullRequests = [System.Collections.Generic.List[object]]::new()
    $seenPullRequests = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($item in (& $list -Source $Facts -Name 'MergedPullRequests')) {
        $number = & $requireNumber -Value (Get-AvmPropertyValue -InputObject $item -Name 'Number') -Name 'MergedPullRequests.Number'
        $name = "Pull request #$number"
        if (-not $seenPullRequests.Add($number)) {
            throw [System.ArgumentException]::new("$name is listed more than once.")
        }
        $mergedAt = Format-AvmReleaseTimestamp -Value (Get-AvmPropertyValue -InputObject $item -Name 'MergedAt') -Name "$name MergedAt"
        if ([string]::CompareOrdinal($mergedAt, $now) -gt 0) {
            throw [System.ArgumentException]::new("$name merged after Now.")
        }
        $mergeCommit = (& $requireText -Value (Get-AvmPropertyValue -InputObject $item -Name 'MergeCommit') -Name "$name MergeCommit").ToLowerInvariant()
        if ($mergeCommit -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.ArgumentException]::new("$name MergeCommit must be a 40-character commit SHA.")
        }

        $labels = [System.Collections.Generic.List[object]]::new()
        foreach ($label in (& $list -Source $item -Name 'Labels')) {
            $labelName = & $requireText -Value (Get-AvmPropertyValue -InputObject $label -Name 'Name') -Name "$name label Name"
            $addedAtValue = Get-AvmPropertyValue -InputObject $label -Name 'AddedAt'
            $addedAt = $null
            if ($null -ne $addedAtValue) {
                $addedAt = Format-AvmReleaseTimestamp -Value $addedAtValue -Name "$name label AddedAt"
                if ([string]::CompareOrdinal($addedAt, $mergedAt) -gt 0) {
                    throw [System.ArgumentException]::new("$name label '$labelName' was added after the merge. Labels must be the labels present at merge.")
                }
            }
            $isVersionLabel = $versionLabels -contains $labelName.ToLowerInvariant()
            if ($isVersionLabel) {
                $labelName = $labelName.ToLowerInvariant()
            }
            $labels.Add([ordered]@{
                    Name      = $labelName
                    IsVersion = $isVersionLabel
                    AddedBy   = & $optionalText -Value (Get-AvmPropertyValue -InputObject $label -Name 'AddedBy') -Name "$name label AddedBy"
                    AddedAt   = $addedAt
                })
        }

        $changedFilesValue = Get-AvmPropertyValue -InputObject $item -Name 'ChangedFiles' -NoEnumerate
        $changedFiles = $null
        if ($null -ne $changedFilesValue) {
            $files = [System.Collections.Generic.List[object]]::new()
            foreach ($file in (& $list -Source $item -Name 'ChangedFiles')) {
                $status = & $requireText -Value (Get-AvmPropertyValue -InputObject $file -Name 'Status') -Name "$name changed file Status"
                if (@('added', 'modified', 'changed', 'removed', 'renamed', 'copied') -notcontains $status) {
                    throw [System.ArgumentException]::new("$name changed file Status '$status' is not a GitHub file status.")
                }
                $equivalent = Get-AvmPropertyValue -InputObject $file -Name 'FormatEquivalent'
                if ($null -ne $equivalent -and $equivalent -isnot [bool]) {
                    throw [System.ArgumentException]::new("$name changed file FormatEquivalent must be true or false.")
                }
                $files.Add([ordered]@{
                        Path             = & $requireText -Value (Get-AvmPropertyValue -InputObject $file -Name 'Path') -Name "$name changed file Path"
                        Status           = $status.ToLowerInvariant()
                        PreviousPath     = & $optionalText -Value (Get-AvmPropertyValue -InputObject $file -Name 'PreviousPath') -Name "$name changed file PreviousPath"
                        FormatEquivalent = $equivalent -eq $true
                    })
            }
            $changedFiles = $files.ToArray()
        }

        $title = & $optionalText -Value (Get-AvmPropertyValue -InputObject $item -Name 'Title') -Name "$name Title"
        if ($null -eq $title) {
            $title = ''
        }
        $pullRequests.Add([ordered]@{
                Number       = $number
                Title        = $title
                Author       = & $requireText -Value (Get-AvmPropertyValue -InputObject $item -Name 'Author') -Name "$name Author"
                MergedAt     = $mergedAt
                MergeCommit  = $mergeCommit
                Body         = & $optionalText -Value (Get-AvmPropertyValue -InputObject $item -Name 'Body') -Name "$name Body"
                Labels       = $labels.ToArray()
                ChangedFiles = $changedFiles
            })
    }

    $labelEvents = [System.Collections.Generic.List[object]]::new()
    $seenLabelEvents = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($item in (& $list -Source $Facts -Name 'LabelEvents')) {
        $id = & $requireNumber -Value (Get-AvmPropertyValue -InputObject $item -Name 'Id') -Name 'LabelEvents.Id'
        if (-not $seenLabelEvents.Add($id)) {
            throw [System.ArgumentException]::new("Label event $id is listed more than once.")
        }
        $at = Format-AvmReleaseTimestamp -Value (Get-AvmPropertyValue -InputObject $item -Name 'At') -Name "Label event $id At"
        if ([string]::CompareOrdinal($at, $now) -gt 0) {
            throw [System.ArgumentException]::new("Label event $id happened after Now.")
        }
        $action = Get-AvmPropertyValue -InputObject $item -Name 'Action'
        if (@('labeled', 'unlabeled') -cnotcontains $action) {
            throw [System.ArgumentException]::new("Label event $id Action must be 'labeled' or 'unlabeled'.")
        }
        $labelName = & $requireText -Value (Get-AvmPropertyValue -InputObject $item -Name 'Label') -Name "Label event $id Label"
        if ($versionLabels -contains $labelName.ToLowerInvariant()) {
            $labelName = $labelName.ToLowerInvariant()
        }
        $labelEvents.Add([ordered]@{
                Id          = $id
                PullRequest = & $requireNumber -Value (Get-AvmPropertyValue -InputObject $item -Name 'PullRequest') -Name "Label event $id PullRequest"
                Label       = $labelName
                Action      = $action
                Actor       = & $requireText -Value (Get-AvmPropertyValue -InputObject $item -Name 'Actor') -Name "Label event $id Actor"
                At          = $at
            })
    }

    $comments = [System.Collections.Generic.List[object]]::new()
    $seenComments = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($item in (& $list -Source $Facts -Name 'Comments')) {
        $id = & $requireNumber -Value (Get-AvmPropertyValue -InputObject $item -Name 'Id') -Name 'Comments.Id'
        if (-not $seenComments.Add($id)) {
            throw [System.ArgumentException]::new("Comment $id is listed more than once.")
        }
        $createdAt = Format-AvmReleaseTimestamp -Value (Get-AvmPropertyValue -InputObject $item -Name 'CreatedAt') -Name "Comment $id CreatedAt"
        if ([string]::CompareOrdinal($createdAt, $now) -gt 0) {
            throw [System.ArgumentException]::new("Comment $id was created after Now.")
        }
        $body = & $optionalText -Value (Get-AvmPropertyValue -InputObject $item -Name 'Body') -Name "Comment $id Body"
        $comments.Add([ordered]@{
                Id        = $id
                CreatedAt = $createdAt
                Author    = & $requireText -Value (Get-AvmPropertyValue -InputObject $item -Name 'Author') -Name "Comment $id Author"
                Body      = $body
            })
    }

    return [ordered]@{
        Repository         = $repository
        Now                = $now
        LatestVersion      = $latestVersion
        MainHead           = $mainHead
        Freeze             = $freeze
        Authorization      = [ordered]@{
            Owners     = $owners
            CoreTeam   = $coreTeam
            ActorTeams = $actorTeams
        }
        MergedPullRequests = $pullRequests.ToArray()
        LabelEvents        = $labelEvents.ToArray()
        Comments           = $comments.ToArray()
    }
}
