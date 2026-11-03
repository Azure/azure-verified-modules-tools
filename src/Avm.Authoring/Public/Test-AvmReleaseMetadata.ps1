function Test-AvmReleaseMetadata {
    <#
    .SYNOPSIS
        Check one Terraform module pull request's version label and breaking-change details.

    .DESCRIPTION
        Applies the release-metadata rules to facts about one pull request. It never calls GitHub or reads files, so the same facts always give the same result. Invoke-AvmReleaseMetadataCheck gathers the facts from GitHub and calls this function.

        - Human-authored pull request: needs exactly one version label: patch, minor, or major. It must keep the breaking-changes checkbox from the pull request template. When the box is ticked, the "What changes" and "Required upgrade" sections must hold text other than the template placeholders.
        - Routine bot pull request, such as Dependabot: needs no version label unless it changes module code beyond formatting. Module code is the root *.tf and *.tf.json files and anything under modules/.
        - Bot pull request with a version label that a person added: an opt-in. It follows the human rules, except that a missing checkbox means no breaking change.
        - Repo-sync pull request (author azure-verified-modules[bot], title starting with 'chore: run avm pre-commit'): needs no version label and never triggers a release, unless a person opts it in.

        On a bot pull request, a version label added by a bot or by an unknown actor is ignored. The release engine accepts an opt-in only from a module owner or the core AVM team. This function doesn't check that, because the workflow token can't read team membership.

        Before 1.0.0, a major label fails. The check validates structure only. It never judges whether the text is accurate, and it never adds labels.

    .PARAMETER Author
        The GitHub login of the pull request author.

    .PARAMETER Title
        The pull request title.

    .PARAMETER Body
        The pull request description.

    .PARAMETER Labels
        The pull request labels. Each entry is a label name, or an object with Name and AddedBy. AddedBy is the login of whoever added the label most recently. Labels other than patch, minor, and major are ignored. Names match case-insensitively.

    .PARAMETER ChangedFiles
        The changed files. Each entry has Path, Status (added, modified, changed, removed, renamed, or copied), optional PreviousPath, and FormatEquivalent. FormatEquivalent is $true when the file content is identical after terraform fmt on both sides. Null or omitted means the list is unknown, so the pull request counts as changing module code.

    .PARAMETER CurrentVersion
        The latest published module version, such as '0.4.1' or 'v1.2.0'. Null or empty means no version is published, which skips the major-before-1.0.0 rule.

    .PARAMETER SkipModuleVersionCheck
        Skip the standard installed-module version check.

    .EXAMPLE
        Test-AvmReleaseMetadata -Author 'alice' -Title 'feat: add zones' -Body "- [ ] Breaking changes." -Labels @('minor') -ChangedFiles @(@{ Path = 'main.tf'; Status = 'modified'; FormatEquivalent = $false }) -CurrentVersion '0.4.1'

        Returns Status 'pass', Kind 'Human', TriggersRelease $true, and VersionLabel 'minor'.

    .EXAMPLE
        Test-AvmReleaseMetadata -Author 'dependabot[bot]' -Title 'chore(deps): bump azurerm' -ChangedFiles @(@{ Path = 'terraform.tf'; Status = 'modified'; FormatEquivalent = $false })

        Returns Status 'fail' with a missing-label issue, because the bot pull request changes module code beyond formatting.

    .OUTPUTS
        A result with Tool, Status ('pass' or 'fail'), Kind, TriggersRelease, VersionLabel, VersionLabels, BreakingChange, ModuleCodeChanged, FormattingOnly, ModuleCodeFiles, Issues, Warnings, Notes, and IgnoredLabels. Each issue has Code, Message, and Remedy. Each ignored label has Name, AddedBy, Reason, and Message.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Release metadata names the pull request check.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Author,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Title,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Body,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Labels = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $ChangedFiles,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $CurrentVersion,

        [switch] $SkipModuleVersionCheck
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    Test-AvmModuleVersion -SkipModuleVersionCheck:$SkipModuleVersionCheck

    $policy = Get-AvmReleasePolicy
    $class = Get-AvmReleasePullRequestClass -Author $Author -Title $Title -ChangedFiles $ChangedFiles
    $bodyResult = Test-AvmReleasePullRequestBody -Body $Body
    $isHuman = $class.Kind -eq 'Human'

    $issues = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $ignored = [System.Collections.Generic.List[object]]::new()
    $counted = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($Labels | Where-Object { $null -ne $_ })) {
        $name = $null
        $addedBy = $null
        if ($entry -is [string]) {
            $name = $entry
        }
        else {
            $name = [string](Get-AvmPropertyValue -InputObject $entry -Name 'Name')
            $addedBy = [string](Get-AvmPropertyValue -InputObject $entry -Name 'AddedBy')
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $labelName = $name.Trim().ToLowerInvariant()
        if ($policy.VersionLabels -notcontains $labelName) {
            continue
        }
        if (-not $isHuman) {
            $actor = Test-AvmReleaseActorAuthorized -Actor $addedBy -Owners @() -CoreTeam $policy.CoreTeam
            if ($actor.Reason -in @('bot', 'missing-actor')) {
                $message = 'The check could not tell who added this label, so it is not an opt-in.'
                if ($actor.Reason -eq 'bot') {
                    $message = 'A version label added by automation is not an opt-in.'
                }
                $ignored.Add([pscustomobject][ordered]@{
                        Name    = $labelName
                        AddedBy = if ([string]::IsNullOrWhiteSpace($addedBy)) { $null } else { $addedBy }
                        Reason  = $actor.Reason
                        Message = $message
                    })
                $warnings.Add("Ignored the '$labelName' label. $message")
                continue
            }
        }
        if (-not $counted.Contains($labelName)) {
            $counted.Add($labelName)
        }
    }
    $versionLabels = @($policy.VersionLabels | Where-Object { $counted.Contains($_) })

    $plan = Get-AvmReleaseVersionPlan -CurrentVersion $CurrentVersion -PullRequests @(@{ Number = 0; Labels = $versionLabels })
    if (@($plan.Issues | Where-Object { $_.Code -eq 'invalid-base-version' }).Count -gt 0) {
        throw [System.ArgumentException]::new("CurrentVersion '$CurrentVersion' is not a MAJOR.MINOR.PATCH version.")
    }

    $optIn = -not $isHuman -and $versionLabels.Count -gt 0
    $triggersRelease = $isHuman -or $optIn -or $class.RequiresVersionLabel
    $labelList = "'" + ($policy.VersionLabels -join "', '") + "'"
    $what = $policy.WhatChangesHeading
    $upgrade = $policy.RequiredUpgradeHeading
    $remedies = @{
        'breaking-checkbox-ambiguous'  = "Keep exactly one '- [ ] $($policy.BreakingCheckbox).' line. Tick it only when consumers must change their code or configuration."
        'what-changes-missing'         = "Add a '### $what' heading, followed by text that says what breaks for consumers."
        'what-changes-placeholder'     = "Under '### $what', write what breaks for consumers."
        'what-changes-duplicate'       = "Keep one '### $what' heading and delete the others."
        'required-upgrade-missing'     = "Add a '### $upgrade' heading, followed by text that says what consumers must change."
        'required-upgrade-placeholder' = "Under '### $upgrade', write what consumers must change."
        'required-upgrade-duplicate'   = "Keep one '### $upgrade' heading and delete the others."
    }

    if ($triggersRelease) {
        foreach ($planIssue in $plan.Issues) {
            switch ($planIssue.Code) {
                'missing-label' {
                    if ($isHuman) {
                        $issues.Add([pscustomobject][ordered]@{
                                Code    = 'missing-label'
                                Message = 'This pull request has no version label. Every human-authored pull request needs exactly one.'
                                Remedy  = "Add one of $labelList. Use patch for a fix, minor for a new feature, and major for a breaking change. Before 1.0.0, use minor for a breaking change."
                            })
                    }
                    else {
                        $files = @($class.ModuleCodeFiles)
                        $detail = 'The check could not list the changed files, so it treats this pull request as changing module code.'
                        if ($files.Count -gt 0) {
                            $shown = (@($files | Select-Object -First 5 | ForEach-Object { "'$_'" })) -join ', '
                            if ($files.Count -gt 5) {
                                $shown += ", and $($files.Count - 5) more"
                            }
                            $detail = "It changes module code beyond formatting: $shown."
                        }
                        $issues.Add([pscustomobject][ordered]@{
                                Code    = 'missing-label'
                                Message = "This bot pull request needs a version label. $detail"
                                Remedy  = "A module owner or a member of the core AVM team must add one of $labelList by hand. Automation must never add it."
                            })
                    }
                }
                'conflicting-labels' {
                    $issues.Add([pscustomobject][ordered]@{
                            Code    = 'conflicting-labels'
                            Message = "This pull request has more than one version label: $($versionLabels -join ', ')."
                            Remedy  = "Remove labels until exactly one of $labelList remains."
                        })
                }
                'major-before-1.0' {
                    $issues.Add([pscustomobject][ordered]@{
                            Code    = 'major-before-1.0'
                            Message = "The latest published version is $($plan.PreviousVersion). Major labels aren't allowed before 1.0.0."
                            Remedy  = "Replace the 'major' label with 'minor'. Before 1.0.0, breaking changes use minor."
                        })
                }
            }
        }

        if ($isHuman -and $policy.RequireBreakingCheckbox -and -not $bodyResult.CheckboxFound) {
            $issues.Add([pscustomobject][ordered]@{
                    Code    = 'breaking-checkbox-missing'
                    Message = 'The description has no breaking-changes checkbox.'
                    Remedy  = "Restore the '- [ ] $($policy.BreakingCheckbox).' line from the pull request template. Tick it when consumers must change their code or configuration, then fill in '### $what' and '### $upgrade'."
                })
        }
        foreach ($bodyIssue in $bodyResult.Issues) {
            $code = [string]$bodyIssue.Code
            $remedy = 'Fix the pull request description.'
            if ($remedies.ContainsKey($code)) {
                $remedy = $remedies[$code]
            }
            $issues.Add([pscustomobject][ordered]@{
                    Code    = $code
                    Message = [string]$bodyIssue.Message
                    Remedy  = $remedy
                })
        }

        $notes.Add('When it merges, this pull request starts a pending release, or joins the existing one.')
        if ($optIn) {
            $notes.Add('A version label on a bot pull request is an opt-in. The release engine accepts it only from a module owner or a member of the core AVM team. This check does not verify who that is.')
        }
    }
    elseif ($class.Kind -eq 'Automation') {
        $notes.Add('This is a repo-sync pull request. It needs no version label and never triggers a release. Its changes ship with the next release.')
        if ($class.NeedsAttention) {
            $notes.Add('It changes module code beyond formatting, so the release issue will flag it for review.')
        }
    }
    else {
        $notes.Add('This routine bot pull request needs no version label and does not trigger a release. Its changes ship with the next release.')
        if ($class.FormattingOnly) {
            $notes.Add('Its module code changes are formatting only.')
        }
    }
    if ($null -eq $ChangedFiles -and -not $isHuman) {
        $notes.Add('The changed files are unknown, so the check treats this pull request as changing module code.')
    }

    $versionLabel = $null
    if ($versionLabels.Count -eq 1) {
        $versionLabel = $versionLabels[0]
    }

    return [pscustomobject][ordered]@{
        Tool              = 'release-metadata/1'
        Status            = if ($issues.Count -gt 0) { 'fail' } else { 'pass' }
        Kind              = $class.Kind
        TriggersRelease   = [bool]$triggersRelease
        VersionLabel      = $versionLabel
        VersionLabels     = $versionLabels
        BreakingChange    = [bool]$bodyResult.BreakingChange
        ModuleCodeChanged = [bool]$class.ModuleCodeChanged
        FormattingOnly    = [bool]$class.FormattingOnly
        ModuleCodeFiles   = @($class.ModuleCodeFiles)
        Issues            = $issues.ToArray()
        Warnings          = $warnings.ToArray()
        Notes             = $notes.ToArray()
        IgnoredLabels     = $ignored.ToArray()
    }
}
