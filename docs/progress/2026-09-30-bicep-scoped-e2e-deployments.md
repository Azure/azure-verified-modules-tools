# Bicep higher-scope end-to-end deployments

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

Add fail-closed subscription-, management-group-, and tenant-scoped Bicep
deployment tests against explicit, externally provisioned test targets.
Keep the resource-group deployment and cleanup path unchanged. This slice
does not switch registry CI, provision test targets, or establish that a
given identity has tenant-root deployment permissions.

## Safety boundary

- Compile and inspect every selected example before cloud operations. Require
  explicit target IDs and verify the selected Azure CLI subscription and
  tenant, and the existing management group for management-group cases.
- Stage case-specific tokens and parameters outside the module. Require
  identity-matched, Create-only JSON what-if results, new resource IDs under
  approved targets, and ownership evidence before creating a deployment.
- Record the target, deployment name, and expected IDs before creation. After
  a successful or failed attempt, inspect scoped deployment operations,
  including inline nested deployments. Reject Update operations even after
  a Create preview. Delete only resources whose exact IDs and run ownership
  can be verified. Fail and report predicted and unexpected pending IDs if
  cleanup cannot be proved, then stop further examples.
- Run case-local Pester assertions after a verified deployment, even if
  cleanup later fails. Never create or delete a test subscription, tenant, or
  preprovisioned management group.
- Reject unknown, linked, scripted, cross-target, and privileged resource
  operations until their effects and inverse actions are reviewed. Do not
  replicate the registry's subscription-alias decommissioning path.

## Supported boundary and remaining parity gaps

The positive list is policy definitions, policy-set definitions and role
definitions at the explicitly selected subscription, management-group or
tenant scope; subscription scope also permits an empty, run-tagged resource
group. Inline nested deployments must remain at the same target and have
fully inspectable Create predictions and matching deployment operations.
The generated ten-character case suffix must appear in every created
resource name; a caller-supplied `namePrefix` is not overwritten. The existing
resource-group-only path still uses its own disposable-group lifecycle.
Authored post-deployment Pester assertions run for both paths; absent
assertions are reported as `not-present`, not as passing assertions.

Assignments, exemptions, subscription aliases, scripts, locks, linked
templates, cross-scope writes, unsupported resource types, incomplete
what-if expansion, and unverified cleanup are refused. Additional module
resource types and cross-scope examples in registry CI therefore remain
unsupported. These test tiers do not establish policy/convention compliance
parity or justify replacing legacy CI. Existing configured test targets must
be supplied explicitly; the module does not discover, provision or lease
test subscriptions, tenants or management groups. A reaper for higher-scope
objects and recovery after process termination are still needed before
unattended execution. Tenant-root permissions are unverified; a separate
approval for a specific nonproduction target and identity is required before
any live deployment or privilege change.

## Checklist

- [x] Implement scope-aware preflight, deployment-operation discovery and
      ownership-checked cleanup helpers.
- [x] Route higher-scope cases through deployment, assertions and cleanup
      without changing resource-group behavior.
- [x] Add mocked success and failure coverage for all enabled scopes and
      rejected/ambiguous operations.
- [x] Update public help and document enabled resource types, unsupported
      cases and remaining CI parity gaps.
- [x] Run the full local gate and publish this slice on the existing review.

## Validation

`./build.ps1 pre-commit`: layout and lint passed, 1,969 unit tests passed
(9 skipped) and 1,011 component tests passed. `./build.ps1 coverage`:
72.12% (5,443/7,547 commands), above the 70% floor. Higher-scope
success, refusal, partial deployment, assertions and cleanup use mocked
Azure CLI/Pester processes. The Azure CLI's local help confirmed which
scopes accept `--mode`; no live Azure deployment, tenant action, access
change or workflow dispatch was run.

## Blockers or dependencies

The test targets and identities are provisioned outside Avm.Authoring.
Tenant-root permissions for one test identity are unverified; actual
tenant-scope use needs separate authorization and explicit approval before
any live run. Types without provable per-case ownership remain unsupported.
