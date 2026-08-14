# Removes any repository-level rulesets from a target repository that were
# not created by our Terraform automation.
#
# Background: `terraform/modules/github/github.rulesets.tf` is the
# single source of truth for repository-level rulesets on every AVM repo.
# Three rulesets are managed there:
#   * "Azure Verified Modules"             (target=branch)
#   * "Only allow v tags"                  (target=tag)
#   * "Must not delete/update version tags" (target=tag)
# Anything else that shows up at the repository scope was created manually
# (or by some other tool) outside our automation, and silently shadows or
# weakens the policies we ship. This module enumerates repository-scoped
# rulesets and deletes anything whose `name` is not in the managed list.
#
# Org-level / enterprise-level rulesets are deliberately NOT touched:
#   * The list endpoint is called with `includes_parents=false` so the
#     response only contains rulesets defined ON this repository.
#   * Each candidate is additionally double-checked against
#     `source_type == "Repository"` before we DELETE it.
# So the org-wide `azure-production-ruleset` (and any future org/enterprise
# rulesets) are out of scope and will never be enumerated, let alone
# deleted, by this function.
#
# Endpoints:
#   GET    /repos/{owner}/{repo}/rulesets?includes_parents=false
#   DELETE /repos/{owner}/{repo}/rulesets/{ruleset_id}
# Both require the "Administration" repo permission, which the AVM bot has
# on every repo it governs.
#
# Plan mode logs each unmanaged ruleset with `[PLAN]` and never deletes.
# Apply mode logs and then issues a `DELETE` against the ruleset (204 = ok,
# 404 = already gone in a race).
#
# Returns:
#   @{
#     IssueLog       = updated issue log
#     RemovedCount   = number of unmanaged rulesets deleted (0 in plan mode)
#     DetectedNames  = string[] of unmanaged ruleset names that were
#                      detected (regardless of plan vs apply)
#   }

function Remove-UnmanagedRulesets {
    param(
        [string]$orgAndRepoName,
        [bool]$planOnly,
        [array]$issueLog,
        [string[]]$managedRulesetNames = @(
            "Azure Verified Modules",
            "Only allow v tags",
            "Must not delete/update version tags"
        )
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog      = $issueLog
        RemovedCount  = 0
        DetectedNames = @()
    }

    # `includes_parents=false` restricts the response to rulesets defined
    # ON the repository itself, so org/enterprise rulesets are never even
    # enumerated here. `per_page=100` is the GitHub maximum and is far
    # more than realistic AVM repos will ever have (they ship with 3),
    # so a single, non-paginated call is sufficient. We deliberately do
    # NOT use `gh api --paginate` because it concatenates per-page JSON
    # arrays back-to-back (e.g. `[..][..]`) which `ConvertFrom-Json`
    # cannot parse, and any client-side merge of that shape is fragile.
    $listEndpoint = "repos/$orgAndRepoName/rulesets?includes_parents=false&per_page=100"

    try {
        $listResult = Invoke-GitHubCliWithRetry `
            -commands @(
                @{
                    Arguments = @("api", $listEndpoint)
                    OutputLog = "gh-rulesets-list.output.log"
                }
            ) `
            -errorLog "gh-rulesets-list.error.log" `
            -maxRetries 5 `
            -retryDelayIncremental 5 `
            -returnOutput

        if (!$listResult.success) {
            throw "gh api $listEndpoint exited $($listResult.exitCode) : $($listResult.error)"
        }

        $rulesets = @()
        if (-not [string]::IsNullOrWhiteSpace($listResult.output)) {
            try {
                # `gh api` (no --paginate) returns a single JSON array.
                # `@(...)` coerces a 1-element result back to an array
                # because `ConvertFrom-Json` unwraps single-element arrays
                # to a scalar PSCustomObject by default.
                $rulesets = @(($listResult.output.Trim()) | ConvertFrom-Json)
            } catch {
                throw "Failed to parse rulesets response for $orgAndRepoName : $_"
            }
        }

        if ($rulesets.Count -eq 0) {
            Write-Host "$modeTag $orgAndRepoName has no repository-level rulesets."
            return $result
        }

        $managedSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$managedRulesetNames,
            [System.StringComparer]::Ordinal
        )

        $unmanaged = @($rulesets | Where-Object {
            # Belt-and-braces: even with `includes_parents=false`, double
            # check the source so we never DELETE something that does not
            # belong to this repo. Skip rulesets with no name (defensive).
            $_.source_type -eq "Repository" `
                -and -not [string]::IsNullOrWhiteSpace($_.name) `
                -and -not $managedSet.Contains([string]$_.name)
        })

        if ($unmanaged.Count -eq 0) {
            Write-Host "$modeTag $orgAndRepoName has $($rulesets.Count) repository-level ruleset(s); all match the managed set."
            return $result
        }

        $result.DetectedNames = @($unmanaged | ForEach-Object { [string]$_.name })

        foreach ($rs in $unmanaged) {
            $rsName = [string]$rs.name
            $rsId   = [int]$rs.id
            Write-Host "$modeTag $orgAndRepoName has an unmanaged repository ruleset '$rsName' (id=$rsId, target=$($rs.target))." -ForegroundColor Yellow

            if ($planOnly) {
                continue
            }

            $deleteEndpoint = "repos/$orgAndRepoName/rulesets/$rsId"
            $deleteResult = Invoke-GitHubCliWithRetry `
                -commands @(
                    @{
                        Arguments = @("api", $deleteEndpoint, "--method", "DELETE")
                        OutputLog = "gh-rulesets-delete.output.log"
                    }
                ) `
                -errorLog "gh-rulesets-delete.error.log" `
                -maxRetries 5 `
                -retryDelayIncremental 5
            if (!$deleteResult.success) {
                # A 404 here just means the ruleset disappeared between our
                # LIST and DELETE. Treat it as a successful no-op.
                if ($deleteResult.error -match "HTTP 404") {
                    Write-Host "  Ruleset '$rsName' (id=$rsId) already gone on $orgAndRepoName (HTTP 404)."
                    continue
                }
                throw "gh api DELETE $deleteEndpoint exited $($deleteResult.exitCode) : $($deleteResult.error)"
            }
            Write-Host "  Deleted unmanaged ruleset '$rsName' (id=$rsId) on $orgAndRepoName." -ForegroundColor Green
            $result.RemovedCount++
        }
    } catch {
        Write-Warning "  Failed to check/remove unmanaged rulesets for $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "unmanaged-rulesets-cleanup-failed" `
            -message "Failed to check or remove unmanaged repository ruleset(s) on $orgAndRepoName." `
            -data "$_" `
            -issueLog $result.IssueLog
    }

    return $result
}
