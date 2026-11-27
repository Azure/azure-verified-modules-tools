function ConvertTo-AvmReleaseFacts {
    <#
    .SYNOPSIS
        Validate and normalise the facts that the release decision engine reads.

    .DESCRIPTION
        The I/O layer gathers facts from GitHub. This function checks the rules the engine relies on and returns a normalised copy. Timestamps become canonical UTC strings, commit SHAs become lower case, and version labels become lower case. It does not check basic types, because the release I/O layer is the only producer.

        Contract violations throw an ArgumentException:

        - A malformed repository, timestamp, or merge commit SHA.
        - A pull request, label event, or comment listed twice.
        - An event later than Now.
        - A label present at merge but added after the merge.
        - A freeze value, label event action, or changed file status outside its allowed values.

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

    $list = {
        param([object] $Source, [string] $Name)
        return , @(Get-AvmPropertyValue -InputObject $Source -Name $Name | Where-Object { $null -ne $_ })
    }

    $repository = ([string](Get-AvmPropertyValue -InputObject $Facts -Name 'Repository')).Trim()
    if ($repository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$') {
        throw [System.ArgumentException]::new("Repository '$repository' must be 'owner/name'.")
    }
    $now = Format-AvmReleaseTimestamp -Value (Get-AvmPropertyValue -InputObject $Facts -Name 'Now') -Name 'Now'

    $latestVersion = Get-AvmPropertyValue -InputObject $Facts -Name 'LatestVersion'
    $mainHead = Get-AvmPropertyValue -InputObject $Facts -Name 'MainHead'
    if ($null -ne $mainHead) {
        $mainHead = ([string]$mainHead).Trim().ToLowerInvariant()
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
            $owners = [string[]]@($ownersValue)
        }
        $coreValue = Get-AvmPropertyValue -InputObject $authorization -Name 'CoreTeam'
        if ($null -ne $coreValue) {
            $coreTeam = [string]$coreValue
        }
        $teamsValue = Get-AvmPropertyValue -InputObject $authorization -Name 'ActorTeams'
        if ($null -ne $teamsValue) {
            foreach ($login in $teamsValue.Keys) {
                $actorTeams[[string]$login] = [string[]]@($teamsValue[$login] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            }
        }
    }

    $versionLabels = @($policy.VersionLabels)
    $pullRequests = [System.Collections.Generic.List[object]]::new()
    $seenPullRequests = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($item in (& $list -Source $Facts -Name 'MergedPullRequests')) {
        $number = [long](Get-AvmPropertyValue -InputObject $item -Name 'Number')
        $name = "Pull request #$number"
        if (-not $seenPullRequests.Add($number)) {
            throw [System.ArgumentException]::new("$name is listed more than once.")
        }
        $mergedAt = Format-AvmReleaseTimestamp -Value (Get-AvmPropertyValue -InputObject $item -Name 'MergedAt') -Name "$name MergedAt"
        if ([string]::CompareOrdinal($mergedAt, $now) -gt 0) {
            throw [System.ArgumentException]::new("$name merged after Now.")
        }
        $mergeCommit = ([string](Get-AvmPropertyValue -InputObject $item -Name 'MergeCommit')).Trim().ToLowerInvariant()
        if ($mergeCommit -cnotmatch '^[0-9a-f]{40}$') {
            throw [System.ArgumentException]::new("$name MergeCommit must be a 40-character commit SHA.")
        }

        $labels = [System.Collections.Generic.List[object]]::new()
        foreach ($label in (& $list -Source $item -Name 'Labels')) {
            $labelName = ([string](Get-AvmPropertyValue -InputObject $label -Name 'Name')).Trim()
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
                    AddedBy   = Get-AvmPropertyValue -InputObject $label -Name 'AddedBy'
                    AddedAt   = $addedAt
                })
        }

        $changedFilesValue = Get-AvmPropertyValue -InputObject $item -Name 'ChangedFiles' -NoEnumerate
        $changedFiles = $null
        if ($null -ne $changedFilesValue) {
            $files = [System.Collections.Generic.List[object]]::new()
            foreach ($file in (& $list -Source $item -Name 'ChangedFiles')) {
                $status = [string](Get-AvmPropertyValue -InputObject $file -Name 'Status')
                if (@('added', 'modified', 'changed', 'removed', 'renamed', 'copied') -notcontains $status) {
                    throw [System.ArgumentException]::new("$name changed file Status '$status' is not a GitHub file status.")
                }
                $files.Add([ordered]@{
                        Path             = [string](Get-AvmPropertyValue -InputObject $file -Name 'Path')
                        Status           = $status.ToLowerInvariant()
                        PreviousPath     = Get-AvmPropertyValue -InputObject $file -Name 'PreviousPath'
                        FormatEquivalent = (Get-AvmPropertyValue -InputObject $file -Name 'FormatEquivalent') -eq $true
                    })
            }
            $changedFiles = $files.ToArray()
        }

        $pullRequests.Add([ordered]@{
                Number       = $number
                Title        = [string](Get-AvmPropertyValue -InputObject $item -Name 'Title')
                Author       = [string](Get-AvmPropertyValue -InputObject $item -Name 'Author')
                MergedAt     = $mergedAt
                MergeCommit  = $mergeCommit
                Body         = Get-AvmPropertyValue -InputObject $item -Name 'Body'
                Labels       = $labels.ToArray()
                ChangedFiles = $changedFiles
            })
    }

    $labelEvents = [System.Collections.Generic.List[object]]::new()
    $seenLabelEvents = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($item in (& $list -Source $Facts -Name 'LabelEvents')) {
        $id = [long](Get-AvmPropertyValue -InputObject $item -Name 'Id')
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
        $labelName = ([string](Get-AvmPropertyValue -InputObject $item -Name 'Label')).Trim()
        if ($versionLabels -contains $labelName.ToLowerInvariant()) {
            $labelName = $labelName.ToLowerInvariant()
        }
        $labelEvents.Add([ordered]@{
                Id          = $id
                PullRequest = [long](Get-AvmPropertyValue -InputObject $item -Name 'PullRequest')
                Label       = $labelName
                Action      = $action
                Actor       = [string](Get-AvmPropertyValue -InputObject $item -Name 'Actor')
                At          = $at
            })
    }

    $comments = [System.Collections.Generic.List[object]]::new()
    $seenComments = [System.Collections.Generic.HashSet[long]]::new()
    foreach ($item in (& $list -Source $Facts -Name 'Comments')) {
        $id = [long](Get-AvmPropertyValue -InputObject $item -Name 'Id')
        if (-not $seenComments.Add($id)) {
            throw [System.ArgumentException]::new("Comment $id is listed more than once.")
        }
        $createdAt = Format-AvmReleaseTimestamp -Value (Get-AvmPropertyValue -InputObject $item -Name 'CreatedAt') -Name "Comment $id CreatedAt"
        if ([string]::CompareOrdinal($createdAt, $now) -gt 0) {
            throw [System.ArgumentException]::new("Comment $id was created after Now.")
        }
        $comments.Add([ordered]@{
                Id        = $id
                CreatedAt = $createdAt
                Author    = [string](Get-AvmPropertyValue -InputObject $item -Name 'Author')
                Body      = Get-AvmPropertyValue -InputObject $item -Name 'Body'
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
