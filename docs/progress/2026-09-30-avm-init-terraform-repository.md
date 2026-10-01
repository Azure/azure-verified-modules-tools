# avm init: resumable Terraform repository setup

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-repo-creation-push-failure`

## Outcome

`New-Repository.ps1` failed to publish
`Azure/terraform-azure-avm-res-signalrservice-webpubsub`: GitHub rejected the
initial push to `main` with `GH013` because the organization's
`azure-production-ruleset` requires a pull request. The script's temporary
`rulesets-default-opt-in=false` change could never lift that ruleset.

Read-only checks against live repositories showed:

- `azure-production-ruleset` applies to every sampled repository whose
  enterprise `activeRepoStatus` property is `true`, and to none where it is
  `false`. Earlier creations succeeded because the property had not flipped
  when they pushed.
- `rulesets-prod-opt-in=false` and `rulesets-default-opt-in=false` do not
  exempt a repository (`Azure/avm-terraform-governance`); only
  `global-rulesets-opt-out=true` does (`Azure/iotedge`, `Azure/azure-mcp`).
  `rulesets-default-opt-in` is the opt-in for a separate `default-ruleset`.
- A JIT-elevated repository admin who is not an organization owner reports
  `current_user_can_bypass: never`, but can edit `global-rulesets-opt-out`
  (verified with an approved no-op write).
- Repository sync already sets `global-rulesets-opt-out=true` permanently.
- Listing repository teams needs repository admin (404 otherwise); checking a
  single team's access does not, and reports its permissions.

At the user's request the fix became a replacement: `avm init -Ecosystem
terraform` now creates and sets up the repository, and the
`repository-management/repository-creation` scripts are removed. Every stage
queries existing local and GitHub state first, so a failed or stopped run
resumes:

1. Write `metadata.json` to the local folder (the persisted answers).
1. Create the repository, then wait for portal setup and JIT elevation.
1. Grant the module contributors (push) and readers (triage) teams, checking
   each team directly and never downgrading.
1. Publish the first commit from a temporary clone: the portal seed files,
   `metadata.json`, the packaged minimal scaffold, and `avm pre-commit`
   output. No other local content is published, and `main` must hold only
   seed files. The push runs with `global-rulesets-opt-out` temporarily
   `true`; the original value is recorded in the Avm state folder first and
   restored from that record by a later run if needed.
1. Request the app installations, reusing an existing fork, branch, or pull
   request, then clone the repository into an empty folder.

A second review round tightened recovery and safety:

- The opt-out record lives only on the machine that made the change, so it
  also stores the repository ID. A later run restores it only while the
  property is still `true` and repository sync does not manage the
  repository, and discards a record for a deleted repository of the same name.
  A `true` value with no record and no repository sync stops the run, because
  its original value is unknown. The value is read again just before the push.
- Repository sync's own ruleset requires pull requests on `main` with no
  administrator bypass, so a synced repository without module files is
  refused before any work instead of failing at the push.
- Declining a `-Confirm` prompt stops the run at that stage.
- A published `main` must hold a non-empty `terraform.tf`, `_header.md`, an
  example folder, and `tests/`; otherwise the run names the missing files. The
  check reads the root and `examples` trees, which GitHub does not truncate at
  module sizes.
- The local clone is made beside the folder and moved into place. The folder is
  replaced only when it is missing, empty, or holds just the published
  `metadata.json`. That file is moved aside before it is compared, and put back
  if it differs or the move fails.
- The app installation request creates the fork first. GitHub returns the
  caller's existing fork, even a renamed one, and the fork looked up by name
  is used only if that call fails. This follows the GitHub CLI's behaviour and
  was not tried live, because it writes to production.

App configuration YAML is edited line by line, removing the runtime
`powershell-yaml` install. The token scope preflight catches missing
`read:org` or `workflow` scopes before any change.

## Checklist

- [x] Diagnose the rejected push against live rulesets and custom properties.
- [x] Package the minimal Terraform scaffold and prove it passes a real
  `avm pre-commit`, including replacing the portal README.
- [x] Add GitHub/Git helpers, team access, ruleset opt-out, and app
  installation request with idempotent reuse of forks, branches, and PRs.
- [x] Implement the resumable `avm init` Terraform flow and wire the dispatcher.
- [x] Address review findings: record-based opt-out recovery, clean staging
  checkout, elevation before admin-only calls, fork reuse, published-content
  check, `-Confirm` propagation, per-team access checks.
- [x] Add unit and component coverage, including rejected push, failed
  restore, stale record, and local-content isolation.
- [x] Address the second review: repository-scoped opt-out records, the
  unexplained `true` stop, declined confirmations, the published module-file
  check, the transactional local clone, and create-first fork reuse.
- [x] Address the final review: an unexplained `true` always stops the run,
  synced repositories without module files are refused before publishing,
  the module-file check reads non-truncating trees, and `metadata.json` is
  compared after it is moved aside. Kept create-first fork reuse, which the
  GitHub CLI source documents.
- [x] Remove the old creation scripts and tests; update README, spec, plan,
  repository-management README, and CHANGELOG.
- [x] Run the local gate, commit, push, and open a pull request.
- [x] Test live on `Azure/terraform-azure-avm-res-signalrservice-webpubsub`
  from this branch's source, and fix what the test found: new `metadata.json`
  files now list their properties in schema order, starting with `$schema`.
- [x] Fix the CI failures that the local gate missed:
  - The component suite set `GIT_CONFIG_COUNT` before `GIT_CONFIG_KEY_0`
    existed. Locally the calling environment supplied a `GIT_CONFIG_KEY_0`,
    so git accepted it; on CI every test failed in setup. The suite now
    ignores inherited git configuration and sets all three variables before
    its first git call.
  - CI runs Pester 6, which fails a call when no filtered mock matches,
    instead of running the real command as Pester 5 does. The suite now
    passes unmatched `Get-AvmApplicationPath` and `Invoke-AvmProcess` calls
    to the real commands, and the declined team access test mocks every call.
  - CI's PSScriptAnalyzer flagged parameters that
    `Get-AvmTerraformMissingModuleFile` used only inside a nested
    `Where-Object` block. It now uses them directly.

## Validation

- Real publication smoke test (real git and `avm pre-commit` against a local
  bare remote seeded with the portal README): all six pre-commit steps passed,
  68 files published, README regenerated, staging directory removed.
- Targeted tests for the new code: 163 passed, including the component suite
  against a real local git remote.
- `./build.ps1 pre-commit` after the metadata order fix: layout and lint
  clean; 1,993 unit tests passed (9 skipped); 871 component tests passed.
- After the CI fixes, the same gate run under Pester 6.2.0 with no inherited
  `GIT_CONFIG_*` variables: layout and lint clean; 1,993 unit tests passed
  (9 skipped); 871 component tests passed.
- Live test on the webpubsub repository, which the old script had left with
  only the portal README:
  - Without JIT elevation, the run wrote `metadata.json` locally and stopped at
    the administrator access step with no remote changes.
  - After elevation, the resumed run read the values from `metadata.json`,
    granted both teams, and pushed the first commit with the opt-out
    temporarily set and then restored to `false`. It rendered `_header.md`
    from the display name and description, opened
    microsoft/github-operations#1900 from the existing fork (the create-first
    fork call returned it), and cloned the repository.
  - A further run changed nothing and reused the open app installation pull
    request.

## Blockers or dependencies

Documentation updates for `avm init` should merge once this is released:

- Internal runbook: azure-cloud-native/Azure-Verified-Modules-Docs#53 on
  msft.ghe.com.
- Public repository setup guide: Azure/Azure-Verified-Modules#3025 (draft),
  which also simplifies the JIT step to proposing the shared rule tie
  directly. Azure/Azure-Verified-Modules#2989 describes Terraform `avm init`
  as local-only and needs the same correction once this ships.
