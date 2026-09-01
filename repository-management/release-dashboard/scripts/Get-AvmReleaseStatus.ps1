<#
.SYNOPSIS
    Collects release and managed-file version status for every AVM Terraform module repository.

.DESCRIPTION
    Writes a single JSON document describing, per repository:
      - the managed-files version it is pinned to
      - its newest published release
      - how many commits sit on the default branch beyond that release
      - how many of those are human-authored rather than automation
      - how old the oldest unreleased human commit is

    Every field comes from the GitHub API. Nothing is inferred.
#>
[CmdletBinding()]
param(
    [string]$Owner = 'Azure',
    [string]$RepoPattern = 'terraform-azurerm-avm-',
    [string]$OutputPath = "$PSScriptRoot/../site/data/release-status.json",
    [int]$MaxRepos = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GhJson {
    param([string]$Path, [string]$Jq, [string]$Method, [hashtable]$Fields)
    $arguments = @('api')
    if ($Method) { $arguments += @('-X', $Method) }
    $arguments += $Path
    # Query strings long enough to need encoding go through -f rather than the path,
    # which is what the search endpoints require.
    if ($Fields) { foreach ($key in $Fields.Keys) { $arguments += @('-f', "$key=$($Fields[$key])") } }
    if ($Jq) { $arguments += @('--jq', $Jq) }
    $raw = & gh @arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw -join "`n") | ConvertFrom-Json } catch { return $null }
}

function Get-AvmRepoName {
    param([string]$Owner, [string]$Pattern)
    $found = & gh search repos --owner $Owner $Pattern --limit 300 --json 'name,isArchived' 2>$null | ConvertFrom-Json
    return @($found |
        Where-Object { -not $_.isArchived -and $_.name -like "$Pattern*" } |
        Select-Object -ExpandProperty name |
        Sort-Object -Unique)
}

function Get-PinnedVersion {
    param([string]$Repo)
    # The contents API returns base64, not JSON, so this bypasses Invoke-GhJson.
    $encoded = & gh api "repos/$Repo/contents/.avm/managed-files-version.json" --jq '.content' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $encoded) { return $null }
    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($encoded -join '') -replace '\s', '')))
        return ($decoded | ConvertFrom-Json).version
    } catch { return $null }
}

function Get-NewestVersion {
    <#
        The Terraform registry publishes from git tags, not GitHub releases, so the
        tag list is the authority on what a consumer can actually install. Three AVM
        repositories carry a version tag with no matching release: aks-economy,
        aks-enterprise and certificateregistration-certificateorder. Reading releases
        alone reports those as never published, while the registry serves them.

        Releases are still read, because they carry a publication date that a tag
        does not. When the newest tag has no release, the date comes from the commit
        the tag points at.
    #>
    param([string]$Repo)

    $tags = Invoke-GhJson -Path "repos/$Repo/tags?per_page=100"
    if ($null -eq $tags) { return $null }

    $versions = foreach ($tag in @($tags)) {
        $text = ($tag.name -replace '^v', '')
        # Ignore pre-release and non-semver tags; the registry does not serve them.
        if ($text -notmatch '^\d+\.\d+\.\d+$') { continue }
        [pscustomobject]@{ Name = $tag.name; Version = [version]$text; Sha = $tag.commit.sha }
    }
    $versions = @($versions)
    if ($versions.Count -eq 0) { return $null }

    $newest = $versions | Sort-Object Version | Select-Object -Last 1

    $published = $null
    $releases = Invoke-GhJson -Path "repos/$Repo/releases?per_page=100"
    if ($null -ne $releases) {
        $match = @($releases | Where-Object { $_.tag_name -eq $newest.Name -and -not $_.draft }) | Select-Object -First 1
        if ($match) { $published = $match.published_at }
    }
    if (-not $published) {
        # gh --jq emits a bare string here, not JSON, so this bypasses Invoke-GhJson
        # for the same reason Get-PinnedVersion does.
        $commitDate = & gh api "repos/$Repo/commits/$($newest.Sha)" --jq '.commit.committer.date' 2>$null
        if ($LASTEXITCODE -eq 0 -and $commitDate) { $published = ($commitDate -join '').Trim() }
    }

    return [pscustomobject]@{ Tag = $newest.Name; Published = $published }
}

function Get-AvmHclBalance {
    # Net bracket depth contributed by one line, ignoring quoted strings and comments.
    param([string]$Line)
    $scan = $Line -replace '"(\\.|[^"\\])*"', '' -replace '#.*$', ''
    return ([regex]::Matches($scan, '[\{\[\(]')).Count - ([regex]::Matches($scan, '[\}\]\)]')).Count
}

function Get-AvmHclField {
    <#
        Splits the interior of a variable or output block into named fields.

        Comparing whole blocks says only that something moved. Comparing fields says
        which one, and for `nullable`, `default` and `validation` that is enough to
        state whether existing callers break rather than merely that they might.
    #>
    param([string[]]$Lines)

    $fields = @{}
    $validations = [System.Collections.Generic.List[string]]::new()
    $index = 0

    while ($index -lt $Lines.Count) {
        $line = $Lines[$index]

        if ($line -match '^\s*validation\s*\{') {
            $buffer = [System.Collections.Generic.List[string]]::new()
            $buffer.Add($line)
            $balance = Get-AvmHclBalance -Line $line
            while ($balance -gt 0 -and ($index + 1) -lt $Lines.Count) {
                $index++
                $buffer.Add($Lines[$index])
                $balance += Get-AvmHclBalance -Line $Lines[$index]
            }
            # error_message is prose. Only the condition decides whether the rule
            # accepts more or less than it used to.
            $text = ($buffer -join ' ') -replace 'error_message\s*=\s*"(\\.|[^"\\])*"', ''
            $validations.Add((($text -replace '\s+', ' ').Trim()))
        }
        elseif ($line -match '^\s*(type|default|nullable|sensitive|value|ephemeral)\s*=(.*)$') {
            $name = $Matches[1]
            $buffer = [System.Collections.Generic.List[string]]::new()
            $buffer.Add($Matches[2])
            $balance = Get-AvmHclBalance -Line $Matches[2]
            while ($balance -gt 0 -and ($index + 1) -lt $Lines.Count) {
                $index++
                $buffer.Add($Lines[$index])
                $balance += Get-AvmHclBalance -Line $Lines[$index]
            }
            $fields[$name] = ((($buffer -join ' ') -replace '\s+', ' ').Trim())
        }
        $index++
    }

    $fields['validation'] = ($validations -join ' ;; ')
    $fields['validationCount'] = $validations.Count
    return $fields
}

function Get-AvmHclBlock {
    <#
        Parses top-level HCL blocks of one kind into a map of name to field set.

        Brace depth is counted rather than the file being split on a regex, because
        AVM descriptions embed worked Terraform examples: a naive split treats
        `variable "foo"` inside a heredoc as a real declaration.

        Descriptions are dropped on purpose. They are long, carry examples, and
        change on their own schedule, so including them reports a documentation
        edit as an interface change.
    #>
    param([string]$Text, [string]$Kind)

    $result = @{}
    $lines = $Text -split "`r?`n"
    $current = $null
    $buffer = $null
    $depth = 0
    $heredoc = $null

    foreach ($line in $lines) {
        if ($heredoc) {
            if ($line.Trim() -eq $heredoc) { $heredoc = $null }
            continue
        }

        if ($null -eq $current) {
            if ($line -match "^\s*$Kind\s+`"([^`"]+)`"\s*\{") {
                $current = $Matches[1]
                $buffer = [System.Collections.Generic.List[string]]::new()
                $depth = 1
            }
            continue
        }

        $isDescription = $line -match '^\s*description\s*='

        if ($line -match '<<-?\s*([A-Za-z_][A-Za-z0-9_]*)\s*$') {
            $heredoc = $Matches[1]
            if (-not $isDescription) { [void]$buffer.Add($line) }
            continue
        }

        $depth += Get-AvmHclBalance -Line $line
        if ($depth -le 0) {
            $result[$current] = Get-AvmHclField -Lines @($buffer)
            $current = $null
            $buffer = $null
            continue
        }

        if (-not $isDescription) { [void]$buffer.Add($line) }
    }
    return $result
}

function Compare-AvmHclField {
    <#
        Names what moved inside one declaration and which way.

        Four verdicts are possible. `breaking` means an input that used to be
        accepted now is not. `behaviour` means deployed infrastructure can change
        without anyone editing a configuration. `relaxed` means strictly more is
        accepted than before. `unclear` means the field moved in a way set
        comparison cannot rank, which is the honest limit of this approach.
    #>
    param([hashtable]$Before, [hashtable]$After, [string]$Name)

    $changes = [System.Collections.Generic.List[object]]::new()
    $get = { param($map, $key) if ($map.ContainsKey($key)) { [string]$map[$key] } else { $null } }

    $beforeType = & $get $Before 'type'
    $afterType = & $get $After 'type'
    $typeChanged = $beforeType -ne $afterType
    $typeIsShort = ($null -ne $beforeType -and $null -ne $afterType -and $beforeType.Length -le 40 -and $afterType.Length -le 40)

    $beforeCount = [int](& $get $Before 'validationCount')
    $afterCount = [int](& $get $After 'validationCount')
    $validationAdded = $afterCount -gt $beforeCount

    $beforeNullable = & $get $Before 'nullable'
    $afterNullable = & $get $After 'nullable'
    if ($beforeNullable -ne $afterNullable) {
        # Terraform defaults `nullable` to true, so absent and "true" mean the same.
        $wasNullable = ($null -eq $beforeNullable) -or ($beforeNullable -eq 'true')
        $isNullable = ($null -eq $afterNullable) -or ($afterNullable -eq 'true')
        if ($wasNullable -and -not $isNullable) {
            $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'breaking'; detail = 'null is no longer accepted' })
        } elseif (-not $wasNullable -and $isNullable) {
            $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'relaxed'; detail = 'null is now accepted' })
        }
    }

    if ($typeChanged -and $validationAdded) {
        # A rule added beside a loosened type usually restores what the type stopped
        # enforcing, so the pair cannot be ranked from counts alone. AVM's storage
        # account did exactly this: `subresource_name` moved from `string` to
        # `optional(string, null)` and a rule now requires it to be non-null, which
        # accepts precisely the same input as before and only changes the error text.
        # Judging the rule on its own reported that as breaking, which it is not.
        $n = $afterCount - $beforeCount
        $changes.Add([pscustomobject]@{
                declaration = $Name
                verdict     = 'unclear'
                detail      = "the type changed and $n validation rule$(if ($n -ne 1) { 's were' } else { ' was' }) added, which often compensate for each other, so the pair needs reading together"
            })
    }
    elseif ($validationAdded) {
        $n = $afterCount - $beforeCount
        $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'breaking'; detail = "$n validation rule$(if ($n -ne 1) { 's' }) added with no type change, so input that used to pass may now fail" })
    }
    elseif ($afterCount -lt $beforeCount) {
        $n = $beforeCount - $afterCount
        $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'relaxed'; detail = "$n validation rule$(if ($n -ne 1) { 's' }) removed" })
    }
    elseif ((& $get $Before 'validation') -ne (& $get $After 'validation')) {
        $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'unclear'; detail = 'a validation rule was rewritten, so whether it accepts more or less needs reading' })
    }

    $beforeDefault = & $get $Before 'default'
    $afterDefault = & $get $After 'default'
    if ($beforeDefault -ne $afterDefault) {
        if ($null -eq $beforeDefault) {
            $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'relaxed'; detail = 'gained a default, so it is no longer required' })
        } elseif ($null -eq $afterDefault) {
            $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'breaking'; detail = 'lost its default, so it is now required' })
        } else {
            $short = ($beforeDefault.Length -le 30 -and $afterDefault.Length -le 30)
            $detail = if ($short) { "default changed from $beforeDefault to $afterDefault" } else { 'default changed' }
            $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'behaviour'; detail = "$detail, which can alter deployed infrastructure with no configuration edit" })
        }
    }

    # Reported only when no validation rule was added, because the combined case
    # above already names the type change and saying it twice adds noise.
    if ($typeChanged -and -not $validationAdded) {
        if ($typeIsShort) {
            $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'breaking'; detail = "type changed from $beforeType to $afterType" })
        } else {
            # Object types run to thousands of characters. Adding an optional
            # attribute and removing a required one look identical at this level.
            $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'unclear'; detail = 'the object type changed, so which attributes moved needs reading' })
        }
    }

    $beforeSensitive = & $get $Before 'sensitive'
    $afterSensitive = & $get $After 'sensitive'
    if ($beforeSensitive -ne $afterSensitive) {
        $verdict = if ($afterSensitive -eq 'true') { 'behaviour' } else { 'breaking' }
        $detail = if ($afterSensitive -eq 'true') { 'is now sensitive, so it is redacted in output' } else { 'is no longer sensitive, so a previously redacted value is now shown' }
        $changes.Add([pscustomobject]@{ declaration = $Name; verdict = $verdict; detail = $detail })
    }

    $beforeValue = & $get $Before 'value'
    $afterValue = & $get $After 'value'
    if ($beforeValue -ne $afterValue) {
        $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'behaviour'; detail = 'the value expression changed, so consumers may read something different' })
    }

    if ($changes.Count -eq 0) {
        $changes.Add([pscustomobject]@{ declaration = $Name; verdict = 'unclear'; detail = 'the declaration changed in a way this comparison does not name' })
    }
    return @($changes)
}

function Get-AvmModuleInterface {
    <#
        Returns the public interface of a module at one ref: every root variable and
        output, keyed `variable.<name>` or `output.<name>`.
    #>
    param([string]$Repo, [string]$Ref)

    $interface = @{}
    foreach ($pair in @(@('variables.tf', 'variable'), @('outputs.tf', 'output'))) {
        $raw = & gh api "repos/$Repo/contents/$($pair[0])?ref=$Ref" -H 'Accept: application/vnd.github.raw' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { continue }
        $blocks = Get-AvmHclBlock -Text (($raw -join "`n")) -Kind $pair[1]
        foreach ($entry in $blocks.GetEnumerator()) {
            $interface["$($pair[1]).$($entry.Key)"] = $entry.Value
        }
    }
    return $interface
}

function Get-AvmNextVersion {
    <#
        Applies SNFR17 to a tag.

        Before 1.0.0 the major version never moves: a breaking change and a feature
        both bump the minor, and only a backward-compatible fix bumps the patch.
        That rule stops at 1.0.0, after which ordinary semantic versioning applies
        and a breaking change bumps the major. Not every AVM module is pre-1.0 —
        `avm-res-web-hostingenvironment` is already at 2.0.1 — so the version itself
        selects which rule to use.
    #>
    param([string]$Tag, [switch]$Changed, [switch]$Breaking)

    $prefix = if ($Tag.StartsWith('v')) { 'v' } else { '' }
    $parts = ($Tag -replace '^v', '') -split '\.'
    if ($parts.Count -ne 3) { return $null }

    $major = [int]$parts[0]; $minor = [int]$parts[1]; $patch = [int]$parts[2]

    $bump = if (-not $Changed) { 'patch' }
    elseif ($Breaking -and $major -ge 1) { 'major' }
    else { 'minor' }

    switch ($bump) {
        'major' { $major++; $minor = 0; $patch = 0 }
        'minor' { $minor++; $patch = 0 }
        default { $patch++ }
    }

    return [pscustomobject]@{
        Bump    = $bump
        Version = "$prefix$major.$minor.$patch"
    }
}

function Compare-AvmModuleInterface {
    <#
        Compares the interface at the newest tag against the default branch and
        recommends a bump. Under SNFR17 any interface change is a minor bump before
        1.0.0, whether it breaks callers or merely adds to them, so the two are
        reported separately for the day a module reaches 1.0.0 and they diverge.
    #>
    param([string]$Repo, [string]$Tag, [string]$Branch)

    $before = Get-AvmModuleInterface -Repo $Repo -Ref $Tag
    $after = Get-AvmModuleInterface -Repo $Repo -Ref $Branch
    if ($before.Count -eq 0 -and $after.Count -eq 0) { return $null }

    $shortName = { param($key) ($key -split '\.', 2)[1] }
    $signature = { param($fields) (($fields.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '|') }

    $removed = @($before.Keys | Where-Object { $_ -notin $after.Keys } | Sort-Object)
    $added = @($after.Keys | Where-Object { $_ -notin $before.Keys } | Sort-Object)
    $altered = @($before.Keys | Where-Object {
            $_ -in $after.Keys -and (& $signature $before[$_]) -ne (& $signature $after[$_])
        } | Sort-Object)

    # A variable with no `default` is required, so adding one breaks every existing
    # caller rather than merely extending the interface.
    $requiredAdded = @($added | Where-Object {
            $_ -like 'variable.*' -and -not $after[$_].ContainsKey('default')
        })

    # Naming the direction of each altered declaration is what separates "something
    # moved" from "callers break". Whatever this cannot rank stays `unclear`, which
    # is the measured size of the gap rather than a hidden guess.
    $fieldChanges = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $altered) {
        foreach ($change in (Compare-AvmHclField -Before $before[$key] -After $after[$key] -Name (& $shortName $key))) {
            $fieldChanges.Add($change)
        }
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    foreach ($group in @(
            @{ items = @($removed | Where-Object { $_ -like 'variable.*' }); verb = 'removed'; noun = 'variable' },
            @{ items = @($removed | Where-Object { $_ -like 'output.*' }); verb = 'removed'; noun = 'output' },
            @{ items = @($added | Where-Object { $_ -like 'variable.*' }); verb = 'added'; noun = 'variable' },
            @{ items = @($added | Where-Object { $_ -like 'output.*' }); verb = 'added'; noun = 'output' }
        )) {
        $count = $group.items.Count
        if ($count -eq 0) { continue }
        $plural = if ($count -eq 1) { $group.noun } else { "$($group.noun)s" }
        $names = @($group.items | Select-Object -First 3 | ForEach-Object { & $shortName $_ })
        $tail = if ($count -gt 3) { ", and $($count - 3) more" } else { '' }
        $reasons.Add("$count $plural $($group.verb): $($names -join ', ')$tail")
    }

    $changed = ($removed.Count + $added.Count + $altered.Count) -gt 0
    $breakingFields = @($fieldChanges | Where-Object { $_.verdict -eq 'breaking' })
    $unclearFields = @($fieldChanges | Where-Object { $_.verdict -eq 'unclear' })
    $breaking = ($removed.Count + $requiredAdded.Count + $breakingFields.Count) -gt 0
    $next = Get-AvmNextVersion -Tag $Tag -Changed:$changed -Breaking:$breaking

    return [pscustomobject]@{
        comparedAgainst     = $Tag
        variablesAdded      = @($added | Where-Object { $_ -like 'variable.*' } | ForEach-Object { & $shortName $_ })
        variablesRemoved    = @($removed | Where-Object { $_ -like 'variable.*' } | ForEach-Object { & $shortName $_ })
        outputsAdded        = @($added | Where-Object { $_ -like 'output.*' } | ForEach-Object { & $shortName $_ })
        outputsRemoved      = @($removed | Where-Object { $_ -like 'output.*' } | ForEach-Object { & $shortName $_ })
        declarationsAltered = @($altered | ForEach-Object { & $shortName $_ })
        fieldChanges        = @($fieldChanges)
        unclearCount        = $unclearFields.Count
        requiredAdded       = @($requiredAdded | ForEach-Object { & $shortName $_ })
        breaking            = $breaking
        suggestedBump       = if ($next) { $next.Bump } else { $null }
        suggestedVersion    = if ($next) { $next.Version } else { $null }
        reasons             = @($reasons)
    }
}

function Get-AwaitingReleaseIssue {
    <#
        AVM defines "Status: Awaiting Release To Be Cut :scissors:" to mean a fix has
        merged but no release carries it yet. That is the same condition this script
        computes from tags, so the issues belong beside the commit counts.

        One org-wide search returns every match with its repository, which costs a
        single call rather than one per repository.
    #>
    param([string]$Owner)

    $query = "org:$Owner is:issue is:open label:`"Status: Awaiting Release To Be Cut :scissors:`""
    $found = Invoke-GhJson -Path 'search/issues' -Method 'GET' -Fields @{ q = $query; per_page = '100' }

    $byRepo = @{}
    if ($null -eq $found -or -not ($found.PSObject.Properties.Name -contains 'items')) { return $byRepo }

    foreach ($item in @($found.items)) {
        $repoName = ($item.repository_url -split '/')[-1]
        if (-not $byRepo.ContainsKey($repoName)) { $byRepo[$repoName] = [System.Collections.Generic.List[object]]::new() }
        $byRepo[$repoName].Add([pscustomobject]@{
                number = $item.number
                title  = $item.title
                url    = $item.html_url
            })
    }
    return $byRepo
}

$repoNames = @(Get-AvmRepoName -Owner $Owner -Pattern $RepoPattern)
if ($MaxRepos -gt 0) { $repoNames = @($repoNames | Select-Object -First $MaxRepos) }
Write-Host "Found $($repoNames.Count) repositories"

$awaitingByRepo = Get-AwaitingReleaseIssue -Owner $Owner
Write-Host "Found awaiting-release issues in $($awaitingByRepo.Keys.Count) repositories"

$records = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($name in $repoNames) {
    $index++
    $repo = "$Owner/$name"
    Write-Host "[$index/$($repoNames.Count)] $name"

    $meta = Invoke-GhJson -Path "repos/$repo" -Jq '{default_branch, html_url}'
    $defaultBranch = if ($meta) { $meta.default_branch } else { 'main' }

    $record = [ordered]@{
        module                 = $name -replace '^terraform-azurerm-', ''
        repo                   = $name
        url                    = if ($meta) { $meta.html_url } else { "https://github.com/$repo" }
        pinnedVersion          = Get-PinnedVersion -Repo $repo
        latestTag              = $null
        latestPublished        = $null
        aheadBy                = 0
        automationAhead        = 0
        humanAhead             = 0
        oldestHumanDays        = $null
        unreleasedPrs          = @()
        awaitingReleaseIssues  = @(if ($awaitingByRepo.ContainsKey($name)) { $awaitingByRepo[$name] } else { })
        interfaceDelta         = $null
        state                  = 'unknown'
    }

    $release = Get-NewestVersion -Repo $repo
    if ($null -eq $release) {
        $record.state = 'never-released'
        $records.Add([pscustomobject]$record)
        continue
    }

    $record.latestTag = $release.Tag
    $record.latestPublished = $release.Published

    $comparison = Invoke-GhJson -Path "repos/$repo/compare/$($release.Tag)...$defaultBranch"
    if ($null -eq $comparison -or -not ($comparison.PSObject.Properties.Name -contains 'commits')) {
        $record.state = 'compare-failed'
        $records.Add([pscustomobject]$record)
        continue
    }

    $record.aheadBy = [int]$comparison.ahead_by
    $commits = @($comparison.commits)

    # Author separates real work from automation far better than commit subject does.
    # "fix: grept apply" appears as both a bot commit and a human one, so no subject
    # pattern splits them; the account that pushed it always does.
    #
    # The test is a regex rather than -like, because -like reads "[bot]" as a
    # character class. '*[bot]' therefore matches any login ending in b, o or t,
    # and never matches the literal suffix, which silently counts every bot as human.
    $humanCommits = @($commits | Where-Object {
            $login = if ($_.author) { $_.author.login } else { $null }
            $login -and $login -notmatch '\[bot\]$'
        })
    $record.humanAhead = $humanCommits.Count
    $record.automationAhead = $commits.Count - $humanCommits.Count

    if ($humanCommits.Count -gt 0) {
        $oldest = ($humanCommits | ForEach-Object { [datetime]$_.commit.committer.date } | Sort-Object | Select-Object -First 1)
        $record.oldestHumanDays = [int][math]::Round(((Get-Date).ToUniversalTime() - $oldest).TotalDays, 0)

        # Squash merges rewrite commit SHAs, so a merge_commit_sha recorded on the pull
        # request often is not the commit that reached the default branch. The trailing
        # "(#123)" that squashing writes into the subject survives, so the subject is the
        # reliable link back to the pull request.
        $seen = [System.Collections.Generic.HashSet[int]]::new()
        $pullRequests = [System.Collections.Generic.List[object]]::new()
        foreach ($commit in $humanCommits) {
            $subject = ($commit.commit.message -split "`n")[0]
            if ($subject -notmatch '\(#(\d+)\)\s*$') { continue }
            $number = [int]$Matches[1]
            if (-not $seen.Add($number)) { continue }
            $pullRequests.Add([pscustomobject]@{
                    number = $number
                    title  = ($subject -replace '\s*\(#\d+\)\s*$', '')
                    author = $commit.author.login
                    url    = "https://github.com/$repo/pull/$number"
                    date   = $commit.commit.committer.date
                })
        }
        $record.unreleasedPrs = @($pullRequests | Sort-Object number)
    }

    $record.state = if ($record.humanAhead -gt 0) { 'unreleased-work' }
    elseif ($record.aheadBy -gt 0) { 'automation-only' }
    else { 'current' }

    # Four extra API calls per repository, so this runs only where a release is
    # actually pending. Nothing is waiting on the other 150.
    if ($record.state -eq 'unreleased-work') {
        $record.interfaceDelta = Compare-AvmModuleInterface -Repo $repo -Tag $release.Tag -Branch $defaultBranch
    }

    $records.Add([pscustomobject]$record)
}

$document = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    repoCount   = $records.Count
    modules     = $records
}

$directory = Split-Path -Parent $OutputPath
if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
[IO.File]::WriteAllText($OutputPath, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host "Wrote $OutputPath"
