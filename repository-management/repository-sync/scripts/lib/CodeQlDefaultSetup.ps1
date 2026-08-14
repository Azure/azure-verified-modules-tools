# Disables GitHub's CodeQL "default setup" on a target repository if it is
# currently configured.
#
# Background: every AVM repository is governed by an explicit advanced-setup
# CodeQL workflow shipped via the managed files repository at
# `terraform/root/.github/workflows/codeql.yml`
# (language matrix is pinned to `actions`, action versions are SHA-pinned).
# When GitHub's org/enterprise-level default-setup toggle is also on, GitHub
# additionally spawns its own dynamic `dynamic/github-code-scanning/codeql`
# workflow. The two run against the same `/language:actions` SARIF category
# and the default-setup run cannot satisfy our customized OIDC subject
# template (its dynamic jobs cannot attach to a deployment environment), so
# every push generates a spurious failed run and a duplicate SARIF upload.
#
# This module idempotently flips default setup to `not-configured` on every
# sync. The advanced-setup workflow shipped via managed files then owns
# CodeQL for the repo. The PATCH is a no-op if default setup is already off.
#
# Endpoints:
#   GET   /repos/{owner}/{repo}/code-scanning/default-setup
#   PATCH /repos/{owner}/{repo}/code-scanning/default-setup  {"state":"not-configured"}
# Both require the "Administration" repo permission, which the AVM bot has
# on every repo it governs.
#
# Plan mode logs the detected state with `[PLAN]` and never patches. Apply
# mode logs and then patches.
#
# Returns:
#   @{
#     IssueLog = updated issue log
#     Disabled = $true if default setup was found configured and patched off,
#                $false otherwise (already off, 404, GHAS not available, etc.)
#   }

function Disable-CodeQlDefaultSetup {
    param(
        [string]$orgAndRepoName,
        [bool]$planOnly,
        [array]$issueLog
    )

    $modeTag = if ($planOnly) { "[PLAN]" } else { "[APPLY]" }
    $result = @{
        IssueLog = $issueLog
        Disabled = $false
    }

    $endpoint = "repos/$orgAndRepoName/code-scanning/default-setup"

    try {
        $getResult = Invoke-GitHubCliWithRetry `
            -commands @(
                @{
                    Arguments = @("api", $endpoint)
                    OutputLog = "gh-codeql-default-setup-get.output.log"
                }
            ) `
            -errorLog "gh-codeql-default-setup-get.error.log" `
            -maxRetries 5 `
            -retryDelayIncremental 5 `
            -returnOutput

        if ($getResult.success) {
            $state = $null
            try {
                $parsed = $getResult.output | ConvertFrom-Json
                $state = $parsed.state
            } catch {
                Write-Warning "$modeTag Could not parse code-scanning default-setup response for $orgAndRepoName : $_"
                return $result
            }

            if ($state -eq "not-configured") {
                Write-Host "$modeTag $orgAndRepoName has CodeQL default setup already disabled."
                return $result
            }

            Write-Host "$modeTag $orgAndRepoName has CodeQL default setup enabled (state='$state'); the managed advanced-setup workflow (.github/workflows/codeql.yml) is the source of truth." -ForegroundColor Yellow

            if ($planOnly) {
                Write-Host "$modeTag Plan mode is enabled; not disabling default setup."
                return $result
            }

            # `-f` (raw field) passes a literal string body parameter,
            # avoiding the need to wrangle a JSON payload through stdin.
            $patchResult = Invoke-GitHubCliWithRetry `
                -commands @(
                    @{
                        Arguments = @("api", $endpoint, "--method", "PATCH", "-f", "state=not-configured")
                        OutputLog = "gh-codeql-default-setup-patch.output.log"
                    }
                ) `
                -errorLog "gh-codeql-default-setup-patch.error.log" `
                -maxRetries 5 `
                -retryDelayIncremental 5
            if (!$patchResult.success) {
                throw "gh api PATCH $endpoint exited $($patchResult.exitCode) : $($patchResult.error)"
            }
            Write-Host "  Disabled CodeQL default setup on $orgAndRepoName." -ForegroundColor Green
            $result.Disabled = $true
        } elseif ($getResult.error -match "HTTP 404") {
            # Endpoint not present (very old repos / not-yet-onboarded).
            # Nothing to disable.
            Write-Host "$modeTag $orgAndRepoName has no CodeQL default-setup configuration (HTTP 404)."
        } elseif ($getResult.error -match "HTTP 403") {
            # GitHub Advanced Security is not enabled on this repo - so
            # default setup cannot be configured either. No-op.
            Write-Host "$modeTag $orgAndRepoName : code-scanning default-setup endpoint returned 403 (GHAS not enabled); nothing to disable."
        } else {
            throw "gh api $endpoint exited $($getResult.exitCode) : $($getResult.error)"
        }
    } catch {
        Write-Warning "  Failed to check/disable CodeQL default setup for $orgAndRepoName : $_"
        $result.IssueLog = Add-IssueToLog `
            -orgAndRepoName $orgAndRepoName `
            -type "codeql-default-setup-disable-failed" `
            -message "Failed to check or disable CodeQL default setup on $orgAndRepoName." `
            -data $null `
            -issueLog $result.IssueLog
    }

    return $result
}
