# Shared Bicep workflows

Tools owns reusable orchestration and shared actions. The registry owns module
callers, source, authored tests and configuration. Shared validation and Azure
execution belong to the published `Avm.Authoring` package.

**Not a cutover instruction:** a source-qualified tools commit is not a
qualified package release. The complete package and an approved registry
rollout window are still required.

## Workflows and references

All paths below are under `.github/workflows/`. Existing caller inputs and
defaults remain unchanged except for the two required release pins.

| Previous registry template | Tools workflow | Responsibility |
| --- | --- | --- |
| `avm.template.module.yml` | `bicep-module.yml` | Static, required/advisory policy, e2e and ordinary release tags |
| `avm.template.module.deployment.yml` | `bicep-module-deployment.yml` | One selected target's complete deployment and cleanup lifetime |
| `avm.template.module.preview.yml` | `bicep-module-preview.yml` | Generic validation and read-only release preview |
| `avm.template.module.publish.yml` | `bicep-module-publish.yml` | Generic validation followed by explicitly requested release tags |
| `avm.template.module.publish-only.yml` | `bicep-module-publish-only.yml` | Explicit tag-only path and optional approval, without Azure access |
| `avm.template.module.static.yml` | `bicep-module-static.yml` | Secret-free native static validation for fork callers |

Each remote workflow reference uses a full immutable tools commit SHA. Supply
that same SHA as `tools-ref`; supply the exact qualified package version as
`avm-authoring-version`, normally from `vars.AVM_AUTHORING_VERSION`. There is no
latest-version, development-version or missing-release fallback.

Upgrades are coordinated manually: update the registry's coupled remote
`uses` references and `tools-ref` values together, and qualify the selected
package version against that tools revision. Registry Dependabot ignores only
those two tools-reference dependency entries; updates for other actions stay
enabled. No new updater automation is part of this migration.
Later coupled pin upgrades also edit module caller workflows and require the
same rollout window described below.

The full module workflow retains `workflowInput`, `moduleTestFilePaths`,
`psRuleModuleTestFilePaths` and `modulePath`. Its nested deployment workflow
retains `workflowInput`, `modulePath`, `testCase` and optional `tokenNamePrefix`.
Deployment also accepts optional `targetCommit`, defaulting to `github.sha`;
preview and publishing forward their explicit target to every validation tier.

Default checkout means the **caller**, not tools. Executable jobs separately
check out `.github/actions` and `scripts/bicep-workflows` from the specified
tools SHA into `.avm-tools`, with persisted Git credentials disabled. They do
not check out tools module source or test fixtures beneath the registry.
Nested reusable calls are relative, keeping them on the outer workflow's
revision. Shared implementation never resolves through registry utilities or
caller-local template actions.

Caller checkouts are complete, retaining registry-owned `.avm` configuration.
The qualified package requires `.avm/child-module-publish-allowed-list.json`
with the existing allowed-child-modules contract. The registry keeps an
identical copy of the legacy approvals and retains the legacy utilities file
while current releases need it. This adds no approvals or workflow inputs.
Only the separate tools-support checkout is sparse.

Three initializer actions are callable remotely at that same tools SHA:

| Action under `.github/actions/` | Inputs | Outputs |
| --- | --- | --- |
| `bicep-workflow-input` | `workflowPath` | `workflowInput` |
| `bicep-module-test-files` | `modulePath`; optional `psRuleFilterRegex`, default `(defaults\|waf-aligned)` | `moduleTestFilePaths`, `psRuleModuleTestFilePaths` |
| `bicep-workflow-matrix` | Exact package version, event/base/target and existing generic validation/publication selections | `baseCommit`, `targetCommit`, `hasModules`, `includeAllVersionedModules`, `moduleMatrix`, `workflowInput` |

Initializer scripts resolve from `github.action_path`, not from the caller.
The generic initializer requires checkout HEAD to equal `targetCommit`.
Pull requests retain the synthetic merge SHA through `github.sha`.
Discovery returns real arrays for zero or one tests, preserves adjacent
`.e2eignore` markers, and limits a module matrix to 256 entries. A missing pull
request base fails; a missing push base visibly selects current modules for
static validation and preview only, never deployment or publication.

## Package contract

Static calls only `Invoke-AvmTestUnit -Ecosystem bicep -Recurse
-IncludeCompliance`. Before that route can run, the exact imported package
must declare integer `PrivateData.AvmCapabilities.BicepPackagedCompliance = 1`
in its module manifest. The native-validation owner sets that marker only
after acceptance proves native conventions, compiled checks, README drift,
metadata/source validation and authored unit Pester tests without registry
compliance. A compiled-test asset by itself is not readiness. Missing or
unsupported markers fail before static execution.

Policy calls `Invoke-AvmCheckPolicy` with one exact module-relative `-Example`
and one `-Baseline`. The CLI accepts the same selectors through
`avm check policy -Example ... -Baseline ...`. Omitting selectors retains all
discovered defaults/WAF-aligned tests and all supported baselines. Explicit
examples also accept other `tests/e2e` cases selected by the caller's existing
`psRuleFilterRegex`. Invalid,
unmatched or incorrectly cased selectors fail; repeated selectors do not
repeat evaluation. Terraform rejects these Bicep-only selectors.

Required baselines are `Azure.Pillar.Reliability` and `CB.AVM.WAF.Security`.
`Azure.Default` and `Azure.Pillar.Security` remain advisory. Advisory findings
are warnings, but missing dependencies or uninspectable evaluations are
failures, not blanket `continue-on-error`.

E2e calls native `Invoke-AvmTestE2e` Deploy and Complete phases with persisted
cleanup state. Deploy receives the exact example and explicit CI-input
opt-in; Complete takes selection from state, not another test discovery.
The qualified package must include native root feature-map handling and
tenant-aware registration. There is no duplicate registration action or
registry script fallback.

## Authentication and lifecycle

Subscription pool precedence remains variables `VALIDATE_SUBSCRIPTION_IDS`,
then `TEST_SUBSCRIPTION_IDS`, then the corresponding canonical and legacy
secrets. Singleton subscription/client/tenant prefer `VALIDATE_*` variables
over secrets. Management group prefers variables `VALIDATE_MANAGEMENT_GROUP_ID`,
then `ARM_MGMTGROUP_ID`, then those secrets. Malformed preferred values fail;
they do not select another identity.

Selection and deployment retain environment `avm-validation`; publishing
approval retains `publish-approval`. Selection exposes the original pool
index and a subscription digest, never secret-backed identifiers. Execution
revalidates both before sign-in. Only exact entries and descendants in the
registry's `.oidc-exceptions.json` use `secrets.AZURE_CREDENTIALS`; ordinary
modules never fall back to that secret. Both logins and native execution use
the same selected subscription and resolved tenant.

Per-module/subscription locks cover deployment, assertions and cleanup.
Tenant, management-group and linked-template scopes also use a separate
shared-scope outer lock. Ordinary and ignored cases do not contend on that
outer lock. Publication variants share `avm-publish-<modulePath>`.
Locks queue rather than cancel in-flight work.

Full GitHub variables/secrets are passed only to native Deploy's CI-input
adapter. The package owns typed parameter/token precedence and any retained
legacy vault behavior. Generic policy/deployment keep the `gci` prefix.
Custom resource location remains separate from fixed deployment metadata
location `WestEurope`.

After sign-in renewal, Complete runs assertions and requested cleanup.
Failure recovery uses persisted state only, without replaying authored hooks.
`removeDeployment=false` retains resources while still allowing assertions.
Cancellation prevents starting renewal or recovery; the runner attempts to
retain state/results but a hard termination cannot guarantee an upload.
Artifacts contain allow-listed diagnostics and credential-free native state,
not raw responses, templates or credential payloads. Invalid, empty, skipped
or filtered executions cannot produce a passing result artifact.

Release jobs create only module Git tags for the existing ADO publication
path. They do not publish to MCR. Ordinary release selection compares the
target to its parent; generic variants use their explicit base. Metadata-only
edits do not qualify. Versioned children precede parents; same-target tags
are reusable, conflicting tags fail, and uncertain pushes are reconciled
without replaying the mutation. Preview cannot create or push tags.

## Rollout and federation

Merge tools orchestration and the separate native-validation implementation,
then qualify and publish a package containing both the complete native
boundary and the policy selectors. Record that exact release. Update registry
references to an available, reviewed tools commit and set the package version
only through the authorized rollout. Do not substitute a branch name or a
placeholder release.

The registry root `bicepconfig.json` already sets
`documentation.template.file` to `docs/templates/avm-readme-v1.scriban` and
`documentation.template.includeRoot` to `docs/templates`. That existing
override prevents selection of the planned package default; it is not a new
caller-template requirement or workflow input. Defer removal of only the
`documentation.template` object until a compatible package release and the
remaining legacy-template consumers are qualified, then coordinate it with
the authorized registry cutover. Keep `documentation.examples` and compiler
settings unchanged. Retain legacy Scriban files while existing consumers need them.
This tools migration does not change registry configuration or template bytes.

**Bulk-merge warning:** all 213 ordinary module callers include their own
workflow file in main-only push paths. Merging their migration can start
deployment-capable validation for every affected module. Feature-branch
pushes and unlabelled workflow-only drafts are a separate source-only case.
The registry merge requires a user-approved rollout window. No merge, fleet
execution, trigger/default weakening or hidden skip flag is authorized by
preparing these files.

Moving the reusable workflow changes `job_workflow_ref`. Inspected GitHub
subject customization includes `repository_owner_id`, `repository_id` and
`context`, not `job_workflow_ref`. The caller repository and environment names
are unchanged, so the design preserves that configured subject. This is
configuration evidence, not a live Entra authentication test. Federated
credentials, identities, role assignments and subject templates are unchanged.
Terraform repository-sync credentials separately bind `job_workflow_ref`;
their policy is not copied into this Bicep migration. Reassess any future
registry trust policy that explicitly binds that claim.

Existing tools review-triggered CI includes Azure sign-in and Windows Defender
exclusions. A tools review, including a draft, remains held until those hosted
actions are authorized or an already-supported safe path is confirmed. Do not
bypass that hold by altering CI or using a fork.

Coordinate an ownership, exact-pinning, unchanged-federation and rollout-window
update in [Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs).
Reuse an appropriate existing review; do not silently open a third one.

## Coverage and retirement boundaries

Run `.\build.ps1 test-workflows` and `.\build.ps1 pre-commit`. The migration's
new runtime cases use local fixtures and mocked package/cloud/Git mutation
boundaries; they do not dispatch workflows.

| Former registry coverage | Tools evidence |
| --- | --- |
| `ModuleWorkflow`: ignored selection (two cases), skipped reporting and complete lock lifetime | `BicepModuleWorkflow.Tests.ps1`: ignored-step selection and environment/lifetime contracts; `BicepSharedWorkflow.Component.Tests.ps1`: ignored cases require no pool/compiler and keep distinct locks |
| `ModuleWorkflow`: shared-scope serialization, publication lock and direct deployment pinning | `BicepModuleWorkflow.Tests.ps1`: outer/inner locks, all release variants, relative callee/SHA forwarding and exact target checkout |
| `ModuleWorkflow`: four generic matrix cases | `BicepSharedWorkflow.Component.Tests.ps1`: metadata retained for pull requests with either deployment toggle, excluded for pushes, and missing pull request base rejected; also empty results, recovered bases and HEAD mismatch |
| Mixed caller/callee assertions: fork-static internals, approval environment, `gci` and absence of broad outer locks | `BicepModuleWorkflow.Tests.ps1`: secret-free static, permission boundaries, approval, prefix and per-case outer groups; caller triggers/opt-in remain registry tests |
| `TestSubscriptionWorkflow`: migrated module selection/authentication cases | `BicepSharedWorkflow.Component.Tests.ps1` plus workflow precedence/renewal contracts; `BicepPolicy.Component.Tests.ps1` and native input tests cover downstream typed parameters |
| `CIParameterWorkflow` | `BicepNativeWorkflowInputs.Component.Tests.ps1`, `BicepWorkflowInput.Component.Tests.ps1`, `BicepWorkflowInput.Tests.ps1`, `BicepWorkflowEnvironment.Tests.ps1`; new workflow tests restrict CI payloads to Deploy |
| `DeploymentCleanupWorkflow` | `BicepNativeDeployment.Tests.ps1`, `BicepWorkflowCleanup.Tests.ps1`, `BicepCleanupState.Component.Tests.ps1`, `BicepNativeWorkflowRecovery.Component.Tests.ps1`; new phase-forwarding tests cover renewal/recovery conditions and failure artifacts |
| `RegionalValidationWorkflow` | `BicepNativeExecution.Component.Tests.ps1`, `BicepNativeWorkflowInputs.Component.Tests.ps1` and `BicepWorkflowInput.Tests.ps1`; workflow forwards custom location without adding retries |
| `RequiredSubscriptionFeaturesWorkflow` | Native e2e/root-map acceptance is owned by the separate refactor and remains a release prerequisite; this branch proves no extra registration stage and explicit selected identity forwarding |
| Release and setup safeguards | `BicepWorkflowRelease.Component.Tests.ps1` and `BicepWorkflowInstallation.Tests.ps1`: exact versions/capability, bounded reads, state reconciliation, version/tag conflicts and preview isolation |
| Child-publication approvals | Registry-owned `.avm/child-module-publish-allowed-list.json` preserves the existing contract and approvals; workflow contracts retain complete caller checkouts, and the qualified native package owns validation |
| Existing README template override | Registry root `bicepconfig.json` selects its legacy Scriban template; removing only `documentation.template` to select the package default depends on compatible-release and remaining-consumer qualification, not these workflow tests. Examples and compiler settings remain unchanged |

Do not remove the last two `TestSubscriptionWorkflow.Tests.ps1` cases:
they cover registry `platform.deployment.history.cleanup.yml`, not migrated
module orchestration. Keep their supporting local code. Retirement of the
other legacy engine assertions remains contingent on the qualified native
release and its acceptance evidence; this table does not claim an unfinished
package is ready.
