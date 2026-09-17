# Avm.Authoring installation retries

**Status**: complete
**Started**: 2026-09-17
**Updated**: 2026-09-17
**Branch**: `jaredfholgate-avm-authoring-installation-retry`

## Outcome

Retry failed `Avm.Authoring` installations in repository sync and every job in
the reusable Terraform workflow. Use three attempts with 5- and 10-second
delays, log retry warnings, and rethrow the final failure. Preserve optional
version selection and post-install compatibility checks.

The five reusable workflow jobs share one inline installer through a YAML
anchor, including the module-version log. Installation failures are retried
regardless of error wording; imports and compatibility checks after a successful
installation remain outside the retry loop.

The reported [repository-sync failure](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35201342585/job/105136705390#step:12:53)
was a PowerShell Gallery HTTP 504 while looking up `Avm.Authoring`.

## Checklist

- [x] Inspect the reported failure and locate all workflow/template installs.
- [x] Add bounded retries, including prerequisite installation where needed.
- [x] Cover first-attempt success, recovery, exhaustion, and version selection.
- [x] Run the repository gate and review the complete diff.

## Validation

- `./build.ps1 test -TestName 'Avm.Authoring installation in *', 'terraform-module reusable workflow*'`
  passed all 33 selected tests. Install commands, sleeps, and module execution
  are mocked; no Gallery installs or repository-sync jobs run.
- `./build.ps1 pre-commit` passed: 1,541 unit tests and 589 component tests,
  with zero errors and 30 warnings from existing test scenarios.
- Parsed both workflows with `powershell-yaml`: all six installation steps are
  present, and the five Terraform jobs expand to one identical installer.
- `git diff --check` passed.

## Blockers or dependencies

None. The reusable workflow checks out the consuming module repository, so its
installer must work without scripts from this repository being present.
