# Tools-owned Bicep workflow templates

**Status**: blocked
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-bicep-workflow-templates`

## Outcome

Move the six reusable Bicep workflow responsibilities and their shared
Actions support into tools ownership. Registry callers retain module paths,
authored tests, triggers and configuration. Validation and deployment engines
remain in the packaged `Avm.Authoring` implementation, not copied registry
utilities or inline replacements.

Tools baseline: `f76e852c8f11d6fa0634457c725073704c8f0c31`.
Registry inventory: `ca00e89a931f637f628503a3a625e7d487157496`.
The isolated checkout started at live tools main; no app background-fetch
operation handle was supplied. This branch does not modify or cherry-pick the
[authoring refactor](https://github.com/Azure/azure-verified-modules-tools/pull/221).

## Checklist

- [x] Account for all six source templates, shared actions, helpers and callers.
- [x] Agree exact paths, inputs, outputs, stable checks and immutable references.
- [x] Implement tools-owned orchestration using public package APIs.
- [x] Preserve input precedence, authentication boundaries, cleanup and tag guards.
- [x] Add focused workflow/action contracts and offline orchestration tests.
- [x] Pass supported focused checks and the ordinary full development gate.
- [x] Document release, federation and registry-cutover dependencies.
- [x] Preserve the source-qualified work in a local feature-branch commit.
- [ ] Push the feature branch after explicit publication authorization.
- [ ] Create the separate tools review after hosted CI authorization.

## Validation

No workflow was dispatched and no cloud, identity, permission, credential,
deployment, cleanup, registration, tag or publication operation was run.
Source/mock validation so far:

- `.\build.ps1 test-workflows`: 93 passed, zero skipped or not run. This
  includes real deployment-action parameter evaluation with both omitted and
  explicit custom location, all six workflow contracts and exact-version
  installation/capability/retry cases.
- Focused public/CLI policy: 7 passed; policy components: 30 passed, including
  caller custom-filter output flowing into explicit native policy selection.
- The final unfiltered `.\build.ps1 pre-commit` passed layout, lint,
  2,938 unit tests (9 skipped) and 1,548 component tests (1 skipped), with
  zero failures.
- Two earlier full runs failed at the unchanged catalog staging-directory
  move in different cases. The exact-match source prerequisite below
  corrected that failure without OS changes or test exclusions; its three
  controlled-lock regressions and the complete gate pass.
- The existing analyzer retry handled transient `NullReferenceException`
  failures. No analyzer implementation was changed.

No broad integration command was run. Release operations and Azure entry
points in workflow support tests are mocked.

## Implementation

The six tools workflows use `.github/workflows/bicep-module*.yml`. Seven
tools-owned actions share `scripts/bicep-workflows/`; no shared step resolves
through caller-local template actions or a registry utilities checkout.
Initializer actions resolve scripts from their own immutable action checkout.
Executable reusable jobs separately check out tools support at `tools-ref`,
excluding tools source/tests from registry discovery. Nested reusable calls
remain relative to the outer tools workflow revision.

Every caller supplies the same immutable full SHA in its remote reference and
`tools-ref`, plus an exact qualified `avm-authoring-version`. Generic discovery
requires its checkout to match `targetCommit`; preview and publishing forward
that target through native deployment as well as static validation.
The user selected coordinated manual upgrades of the coupled remote
references, `tools-ref` and qualified package version. Registry ownership
includes only the two narrow tools-reference Dependabot ignores; other action
updates remain enabled. No updater automation or variable change is included.
Caller checkouts remain complete, including `.avm`. The registry owner adds
`.avm/child-module-publish-allowed-list.json` with identical existing approvals
for the qualified package and keeps the legacy file for current releases;
no approvals or workflow inputs change.

The coordinator assigned additive public/CLI policy `Example` and `Baseline`
selectors to this slice. The existing engine preserves absent-selector
behavior and required/advisory classification, and rejects invalid selections.
Explicit examples also accept custom-filtered e2e tests; the existing discovery
helper expands its candidates only for explicit selection, preserving the
default defaults/WAF-aligned selection.
No new feature-registration stage or public feature API was added: the
refactor's native e2e adapter owns registry-root feature maps and selected
tenant/subscription forwarding.

Standard release selection remains the original upstream-main previous-commit
diff, not publication-history selection. Generic variants retain explicit
base/target selection and preview-only missing-base behavior. Only module Git
tags are created by the eventual workflow, for the existing ADO publication
path; no MCR publication implementation was added.

## Blockers or dependencies

The [workflow contract and coverage map](../bicep-workflow-templates.md)
records initializer inputs/outputs, all six transferred responsibilities,
old-suite retirement boundaries and the rollout sequence.

The resolved local-gate prerequisite concerns `Write-AvmCatalogBundle`'s
`[IO.Directory]::Move` in `repository-management/module-catalog/scripts/ModuleCatalog.ps1`.
Two full runs hit `IOException`/`MethodInvocationException` access-denied on
different unique `.catalog-<GUID>` staging directories, from component cases
at lines 1546 and 1238. The coordinator's prior-art commit
`4c087e2238599ac2de6edd51f309b82e9eb68063` contains a matching bounded
staging-directory move helper and three regression cases in the two catalog
files. After the user directed autonomous continuation, only those exact
catalog files were manually brought across and their Git blob hashes verified.
The prerequisite has its own
[progress record](2026-10-05-catalog-staging-move-retry.md) and separate
local commit `6a6f2787169c656a520d0ed957fe61b9c23e53c1`. No mixed commit
or other refactor code was copied.
The locking process is not identified; no OS/security changes or test
exclusions are permitted. The corrected full gate passed.

The coordinator also reported that the connected OAuth App rejected a
workflow-file push for missing `workflow` scope. The authorization response
granted nothing: keep all qualified commits local, including the separate
catalog prerequisite. This branch has not attempted publication. Resume only
after explicit authorization, without alternate credentials/API routes,
partial pushes, history rearrangement or repeated authorization failures.

The native-validation owner confirms that no released `Avm.Authoring`
version contains the complete registry-independent validation boundary.
The refactor manifest's `0.0.0` is not a release floor. Registry cutover
requires a qualified release of that finished implementation and resolved
immutable tools references; this slice must not invent a version or provide
a registry-utilities fallback. The agreed manifest marker is integer
`PrivateData.AvmCapabilities.BicepPackagedCompliance = 1`. Static setup already
rejects missing/unsupported values. The native owner will add the marker only
with its complete default route and acceptance cases. This branch does not
set the marker; a compiled-check asset alone is not sufficient.

The separate tools review is held by the coordinator: existing review-triggered
CI includes protected-environment Azure sign-in and Windows Defender exclusion
commands. Creating a draft does not avoid those triggers. There is no approval
to run those operations, weaken CI, or use a fork as a bypass. Main-only push
CI does not block a source-qualified feature-branch push.

**Registry rollout warning:** all 213 ordinary module callers include their own
workflow file in main-only push filters. Merging the eventual bulk caller edit
can therefore start deployment-capable validation for every affected module.
Feature-branch pushes and unlabelled workflow-only drafts are a distinct,
source-only case. Cutover requires a user-approved rollout window; no merge or
fleet execution is authorized. Do not silently change triggers, validation
defaults or skip flags to suppress this consequence.

Federated credentials and subject configuration are unchanged. The migration
changes `job_workflow_ref`. Both inspected GitHub OIDC subject configurations
use `repository_owner_id`, `repository_id` and `context`, not
`job_workflow_ref`; caller repository and existing environment names stay
unchanged. Reconfirmed through the GitHub customization API before
publication. Terraform repository-sync's distinct subject policy does include
`job_workflow_ref` and was not reused. This is configuration evidence, not a
live Entra authentication test. No token or Entra query is authorized. Internal operator documentation in
[Azure-Verified-Modules-Docs](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs)
needs a coordinated ownership/rollout update, not an unrelated third review.
