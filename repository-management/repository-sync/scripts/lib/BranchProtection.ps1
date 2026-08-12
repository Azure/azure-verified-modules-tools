# Removes the legacy classic branch-protection rule (the older
# `repos/{owner}/{repo}/branches/{branch}/protection` REST resource) from a
# target repository if one is present.
#
# Background: every AVM repository is supposed to be governed exclusively by
# the rulesets defined in `terraform/modules/github/github.rulesets.tf`.
# A handful of repos still carry an older "Branch protection rule" that
# predates the ruleset migration; those rules silently shadow the rulesets
# (e.g. by enforcing required reviews that the rulesets already enforce, or
# by allowing bypasses the rulesets disallow) and need to be removed.
#
# Plan mode logs the detected rule with `[PLAN]` and never deletes. Apply
# mode logs and then issues a `DELETE` against the same endpoint (204 = ok,
# 404 = already gone in a race).
#
# Returns:
#   @{
#     IssueLog = updated issue log
#     Removed  = $true if a legacy rule was found and deleted, $false otherwise
#   }

function Remove-LegacyBranchProtection {
    param(
        [string]$orgAndRepoName,
        [string]$defaultBranch,
        [bool]$planOnly,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog = $issueLog
        Removed  = $false
    }

    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        Write-Warning "$modeTag No default branch supplied for $orgAndRepoName; skipping legacy branch-protection check."
        return $result
    }

    $endpoint = "repos/$orgAndRepoName/branches/$defaultBranch/protection"

    try {
        $getResult = Invoke-GitHubCliWithRetry `
            -commands @(
                @{
                    Arguments = @("api", $endpoint)
                    OutputLog = "gh-branch-protection-get.output.log"
                }
            ) `
            -errorLog "gh-branch-protection-get.error.log" `
            -maxRetries 5 `
            -retryDelayIncremental 5

        if ($getResult.success) {
            # 200 OK -> a classic branch-protection rule exists.
            Write-Host "$modeTag $orgAndRepoName has a legacy classic branch-protection rule on '$defaultBranch'." -ForegroundColor Yellow

            if ($planOnly) {
                Write-Host "$modeTag Plan mode is enabled; not deleting the legacy rule."
                return $result
            }

            $deleteResult = Invoke-GitHubCliWithRetry `
                -commands @(
                    @{
                        Arguments = @("api", $endpoint, "--method", "DELETE")
                        OutputLog = "gh-branch-protection-delete.output.log"
                    }
                ) `
                -errorLog "gh-branch-protection-delete.error.log" `
                -maxRetries 5 `
                -retryDelayIncremental 5
            if (!$deleteResult.success) {
                if ($deleteResult.error -match "HTTP 404") {
                    Write-Host "  Legacy branch-protection rule already gone on $orgAndRepoName/$defaultBranch (HTTP 404)."
                    return $result
                }
                throw "gh api DELETE $endpoint exited $($deleteResult.exitCode) : $($deleteResult.error)"
            }
            Write-Host "  Deleted legacy branch-protection rule on $orgAndRepoName/$defaultBranch." -ForegroundColor Green
            $result.Removed = $true
        } elseif ($getResult.error -match "HTTP 404" -or $getResult.error -match "Branch not protected") {
            # No classic branch-protection rule present. Expected case.
            Write-Host "$modeTag $orgAndRepoName has no legacy classic branch-protection rule on '$defaultBranch'."
        } else {
            throw "gh api $endpoint exited $($getResult.exitCode) : $($getResult.error)"
        }
    } catch {
        Write-Warning "  Failed to check/remove legacy branch protection for $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "legacy-branch-protection-cleanup-failed" `
            -message "Failed to check or remove legacy classic branch-protection on $orgAndRepoName/$defaultBranch." `
            -data $null `
            -issueLog $result.IssueLog
    }

    return $result
}
