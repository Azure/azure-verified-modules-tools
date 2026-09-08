# Retire the legacy Copilot Actions environment

**Status**: complete
**Started**: 2026-09-08
**Updated**: 2026-09-08
**Branch**: `jaredfholgate-override-variable-setup`

## Outcome

Remove repository-sync provisioning of the legacy `copilot` GitHub Actions
environment and its `ARM_CLIENT_ID`, `ARM_TENANT_ID`, and
`ARM_SUBSCRIPTION_ID` environment secrets. Dedicated Agents secrets are already
configured and remain outside this change. Preserve the Copilot firewall
configuration, repository-level CI secrets, and the CI environments.

GitHub documents the migration from the `copilot` environment to Agents secrets
in [Configure secrets and variables for Copilot cloud agent](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/configure-secrets-and-variables).

## Checklist

- [x] Confirm the legacy environment and secrets are explicitly managed by sync.
- [x] Confirm Agents secrets are already configured with the requester.
- [x] Remove the legacy resources and their root/module input wiring.
- [x] Add regression coverage for retirement and retained firewall configuration.
- [x] Run the local pre-commit gate.
- [x] Keep this cleanup separate from the custom-subscription documentation change.

## Validation

`.\build.ps1 pre-commit` passed: layout, lint, 1,036 unit tests (8 skipped),
and 29 component tests. Both new repository-management assertions passed.
The gate reported analyzer warnings and recovered a transient analyzer
NullReferenceException through its existing retry mechanism.

`git diff --check` passed. No Terraform plan or apply was run.

## Blockers and dependencies

No implementation blockers. No live environment or secret changes are made in
this session. After merge, a subsequent applying repository sync will destroy
the four retired Terraform resources for repositories where they are managed
in state. Deleting the environment also removes any other configuration still
stored in that environment. Agents secrets are separate and are not managed
by those resources.
