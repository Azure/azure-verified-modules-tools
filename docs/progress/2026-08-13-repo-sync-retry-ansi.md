# Repo sync: retry transient Terraform provider install failures

- **Status:** complete
- **Started:** 2026-08-13
- **Completed:** 2026-08-13
- **Branch:** `jaredfholgate-managed-files-versioning`

## Outcome

The scheduled repository sync failed hard on a transient `502 Bad Gateway` from
the Terraform registry even though `Invoke-TerraformWithRetry` already listed
`Error: Failed to install provider` in its `retryOn` set. Root cause: Terraform
colourises its diagnostics even when stdout and stderr are redirected to files,
and it hard-wraps the detail behind a `│` gutter. Both defeat the naive
per-line `-like` match.

Observed failure:
<https://github.com/Azure/azure-verified-modules-tools/actions/runs/31702052540/job/94453457058#step:9:204>

The raw stderr line was:

```text
ESC[31m│ESC[0m ESC[0mESC[1mESC[31mError: ESC[0mESC[0mESC[1mFailed to install providerESC[0m
```

so `*Error: Failed to install provider*` could never match — the escape codes
sit between `Error: ` and the summary. The same applied to
`Error: Failed to query available provider packages`. Both patterns were dead.

## Checklist

- [x] Strip ANSI escape sequences from captured stderr before pattern matching
      (`Remove-AnsiEscapeCode`), applied once so both `retryOn` and
      `recoveryActions` benefit, including the array passed to a recovery action
- [x] Flatten the boxed, wrapped diagnostic into a single normalised string
      (`ConvertTo-FlatErrorText`) so patterns spanning a wrap still match
- [x] Share one matcher (`Get-ErrorOutputMatch`) between the retry loop and the
      recovery-action loop; prefer the offending line for the log message
- [x] Extend the Terraform `retryOn` defaults with `500`, `502`, `503`, `504`
      and `failed to retrieve cryptographic signature for provider`
- [x] Keep the `Get-Content … | Write-Host` display paths uncleaned so colour
      still renders in the Actions log
- [x] Add `tests/Pester/Unit/RepositoryManagement/RetryHelpers.Tests.ps1`

## Validation

- `Invoke-Pester tests/Pester/Unit/RepositoryManagement/` — 24 passed, 0 failed,
  including the pre-existing `MigrationLayout` structural guard.
- `./build.ps1 pre-commit` — green.

Regression coverage asserts both directions: a colourised provider-install
failure retries and then succeeds, while a genuine `Unsupported argument`
configuration error still fails on the first attempt without retrying.

## Notes

`Error acquiring the state lock` survived the bug only by luck — it is the
diagnostic summary, so it sits contiguously inside a single escape-code run and
never spans the `Error: ` boundary.

Stripping ANSI in the retry engine was preferred over adding `-no-color` to the
Terraform argv: it fixes every pattern in one place, does not change Terraform's
behaviour, and keeps colour in the Actions log.
