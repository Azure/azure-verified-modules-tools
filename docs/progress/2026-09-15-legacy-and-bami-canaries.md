# Legacy and BAMI canaries

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-legacy-and-bami-canaries`

## Outcome

Select exactly `legacy` or `bami` from central repository and Bicep module
groups. Keep legacy test settings, identities, and Terraform state intact.
Consume one complete staged BAMI bundle and make Terraform activation an
explicit, disabled-by-default operator action. Bicep variable publication
continues in [its own slice](2026-09-15-bicep-test-tenant-propagation.md).

## Checklist

- [x] Read repository rules and active work; inspect current sync and state.
- [x] Send the parent session the eight-variable and consumer action contract,
  plus the separate candidate identity root/state approach.
- [x] Add central configuration, shared ordered resolution, and strict inputs.
- [x] Add the Bicep consumer action without changing consumer repository files.
- [x] Isolate per-repository BAMI identities from legacy identity state.
- [x] Preserve Terraform's existing effective repository-secret contract.
- [x] Cover selection, candidate failures, state safety, and legacy regressions.
- [x] Complete the local gate for the core selection and identity changes.
- [x] Keep Bicep propagation as a separate, explicitly tracked slice so the
  verified resolver can be published for its consumer.

## Validation

Current targeted checks:

- `.\build.ps1 test-repository-management`: 258 passed.
- `.\build.ps1 component`: 102 passed, including action output and candidate
  orchestration with mocked calls.
- `.\build.ps1 test-tenant-terraform`: both roots pass format and validation;
  seven mocked-provider tests pass. The guard also consumes the
  mock-provider-generated candidate plan and correctly blocks its missing
  Owner delegation restriction.
- `.\build.ps1 pre-commit`: green; 1,304 unit tests passed (8 skipped), 102
  component tests passed. Layout passed; lint recovered from its known
  analyzer-engine exception and completed with warnings.
- The first full run found the repository-required `terraform init -upgrade`
  flag missing on the candidate path. Added it without weakening the guard.

All API tests are mocked. No live sync, deployment, variable publication,
identity changes, or state changes are authorized by this slice.

## Dependencies and operator gates

- The BAMI publisher stages the eight `TEST_BAMI_*` variables in the Tools
  `avm` environment without replacing legacy `ARM_*` values.
- Candidate Terraform identities use an Azure-only root and a separate
  `bami-identities/<tenantGuid>/<repoId>.tfstate` key in the existing TME backend.
- Candidate apply requires the independently reviewed Owner, User Access
  Administrator, and RBAC Administrator delegation deny rules in both
  role-assignment write and delete conditions. The current shared Azure module
  is missing Owner; the real candidate plan is checked before any apply.
- The parent owns the separate Bicep consumer change and internal team docs.
- Bicep federation must separately target
  `repository_owner_id:6844498:repository_id:447791597:environment:avm-validation`.
  The execution identity currently has no proved GitHub federation/login.
- The protected Entra readers group already exists in BAMI. Controller
  Graph lookup and membership access are still unproved; do not add another
  group or grant permissions as part of this slice.
- Operators must approve and configure propagation and candidate identity
  provisioning after reviewing the code and plans. These remain off by default.
