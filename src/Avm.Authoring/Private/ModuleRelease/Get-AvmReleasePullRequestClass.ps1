function Get-AvmReleasePullRequestClass {
    <#
    .SYNOPSIS
        Classify a merged pull request for the release engine.

    .DESCRIPTION
        Decides the pull request kind from its GitHub author and title only.

        - Automation: a repo-sync pull request. The author is azure-verified-modules[bot] and the title starts with 'chore: run avm pre-commit'. Repo-sync pull requests never trigger a release. When they change module code beyond formatting, the release issue flags them.
        - RoutineBot: any other pull request from a known routine bot, such as Dependabot.
        - Human: every other author, including unknown bots. Unknown identities get the stricter human rules.

        Module code is the root *.tf and *.tf.json files and anything under modules/. A change is formatting-only when every changed module-code file was modified in place, and its content is identical after terraform fmt on both sides. The caller supplies that comparison as FormatEquivalent on each file. Added, removed, and renamed module-code files are never formatting-only. When the changed files are unknown, the pull request counts as changing module code.

    .PARAMETER Author
        The GitHub login of the pull request author.

    .PARAMETER Title
        The pull request title.

    .PARAMETER ChangedFiles
        The changed files. Each entry has Path, Status (added, modified, changed, removed, renamed, or copied), optional PreviousPath, and FormatEquivalent. Null means the file list is unknown.

    .EXAMPLE
        Get-AvmReleasePullRequestClass -Author 'dependabot[bot]' -Title 'chore: bump azurerm' -ChangedFiles @(@{ Path = 'examples/default/main.tf'; Status = 'modified'; FormatEquivalent = $false })

        Returns Kind 'RoutineBot' and RequiresVersionLabel $false.

    .OUTPUTS
        Ordered dictionary with Kind, ModuleCodeChanged, FormattingOnly, ModuleCodeFiles, RequiresVersionLabel, and NeedsAttention.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Author,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Title,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $ChangedFiles
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $policy = Get-AvmReleasePolicy
    $kind = 'Human'
    $titleText = ''
    if ($null -ne $Title) {
        $titleText = $Title.Trim()
    }
    if ($Author -eq $policy.AutomationAuthor -and $titleText.StartsWith($policy.AutomationTitlePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $kind = 'Automation'
    }
    elseif (@($policy.RoutineBots | Where-Object { $_ -eq $Author }).Count -gt 0) {
        $kind = 'RoutineBot'
    }

    $isModuleCode = {
        param([string] $Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return $false
        }
        $normalized = ($Path -replace '\\', '/').TrimStart('/')
        if ($normalized -match '^(?i)modules/') {
            return $true
        }
        return ($normalized -notmatch '/') -and ($normalized -match '(?i)\.tf(\.json)?$')
    }

    $moduleFiles = [System.Collections.Generic.List[string]]::new()
    $moduleCode = $false
    $formattingOnly = $false
    if ($null -eq $ChangedFiles) {
        $moduleCode = $true
    }
    else {
        $formattingOnly = $true
        foreach ($file in $ChangedFiles) {
            $path = [string](Get-AvmPropertyValue -InputObject $file -Name 'Path')
            $previousPath = [string](Get-AvmPropertyValue -InputObject $file -Name 'PreviousPath')
            $status = ([string](Get-AvmPropertyValue -InputObject $file -Name 'Status')).ToLowerInvariant()
            if (-not ((& $isModuleCode -Path $path) -or (& $isModuleCode -Path $previousPath))) {
                continue
            }
            $moduleCode = $true
            $moduleFiles.Add(($path -replace '\\', '/'))
            $equivalent = (Get-AvmPropertyValue -InputObject $file -Name 'FormatEquivalent') -eq $true
            if (@('modified', 'changed') -notcontains $status -or -not $equivalent) {
                $formattingOnly = $false
            }
        }
        if (-not $moduleCode) {
            $formattingOnly = $false
        }
    }

    $beyondFormatting = $moduleCode -and -not $formattingOnly
    $requiresLabel = switch ($kind) {
        'Human' {
            $true
        }
        'RoutineBot' {
            $beyondFormatting
        }
        default {
            $false
        }
    }

    return [ordered]@{
        Kind                 = $kind
        ModuleCodeChanged    = $moduleCode
        FormattingOnly       = $formattingOnly
        ModuleCodeFiles      = $moduleFiles.ToArray()
        RequiresVersionLabel = $requiresLabel
        NeedsAttention       = $kind -eq 'Automation' -and $beyondFormatting
    }
}
