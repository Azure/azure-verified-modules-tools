# Repository state migration inventory correction

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-fix-migration-inventory`

## Outcome

Correct the initial ordinary-state inventory failure in the temporary
migration introduced by [#224](https://github.com/Azure/azure-verified-modules-tools/pull/224).
The failed [user-started run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37310826660/job/111766205950)
reported an unexpected or aliased ordinary key without identifying it.
The exact first rejected key was not logged. A separately approved, names-only
inventory supplied by the parent found four keys rejected by that parser:
`avm-container-images-cicd-agents-and-runners.tfstate`, `avm-gh-app.tfstate`,
`avm-template.tfstate`, and
`avm-res-redhatopenShift-openshiftcluster.tfstate`.

This slice starts from main at
`a951532aa89c87da221183510ff0fd820781cc70`. It preserves full configured-scope
inventory, exact ownership and recovery validation, and all-before-publication
staging. No new activation, layout, or approval setting is permitted.
Migration removal remains separate and requires a successful live migration.

## Checklist

- [x] Read repository guidance and check the main baseline and open reviews.
- [x] Trace key parsing against established ordinary and former state writers.
- [x] Reproduce source-derived valid naming and rejection cases locally.
- [x] Correct the proven historical-family mismatch and add safe actionable diagnostics.
- [x] Prove inventory rejection precedes remote publication.
- [x] Run focused native/component controls and the required local gate.
- [x] Preserve migration, ordinary sync, recovery and operator-control contracts.

This records the source correction and local validation. Publication and
automatic hosted-check evidence belong on its review; they do not establish
that a production migration has succeeded.

## Findings

The ordinary writer has always used the supplied `repoId` plus `.tfstate`;
the migration incorrectly treated the current lowercase module naming contract
as the complete historical container inventory. Source snapshot `9b01b78`
included `template` in discovery; `e6461cf1bca19fd193b10e92e8e44551e4d1e69b`
subsequently excluded it without deleting historical state.

The parent supplied allowlisted ownership metadata for both case-distinct
OpenShift keys. They reference one immutable GitHub repository but own different
objects: the mixed-case snapshot has the old flat root, eight managed objects
and six data instances; the canonical snapshot has 70 GitHub managed objects
and five data instances. No managed type/ID pair overlaps. The original flat
Terraform contract at `558a4ff523afa070ba79ecee68c3adb062d6b3eb`, paths
`tf-repo-mgmt/repository_sync/main.tf`, `github.tf`, and `terraform.tf`,
confirms the identity, federation, subscription role, membership, environment
and secret address family. These states are not redundant snapshots.

The parent's separately approved metadata reads also established that all
three excluded template/non-module keys have the flat repository root, not
`module.github`: each has 52 managed objects and four data instances, including
43 labels and the root `main` ruleset. The correction audits those recorded
repository identities without requiring an excluded repository to still exist
in GitHub. It validates each label/ruleset's repository association and never
migrates those old states.

The correction also audits the exact mixed-case key without normalizing it into
a destination. It requires a consistent recorded non-BAMI tenant, non-BAMI subscriptions,
repository/principal relationships, the canonical repository and node IDs,
distinct lineage, default providers, and the recognized flat address family.
All managed Azure, Graph and GitHub type/ID pairs participate in the full
inventory collision check. Its local file path is distinct on Windows too.
The historical state is neither passed to Terraform nor published.

Key diagnostics quote and escape the key, name the backend account/container
and prefix, redact known credentials, and explain that publication has not
started. Source/recovery keys remain strictly canonical; duplicate keys,
unknown aliases, trailing data and ambiguous ownership fail closed.

All key validation and state auditing occur inside the inventory/staging
action. Remote backup uploads, backend initialization and native state pushes
are reachable only after that entire action returns successfully.

## Validation

- Existing migration component baseline: 82 passed.
- Source-derived template regressions before the correction: both preview
  and apply reproduced the original inventory exception.
- Focused migration components with the three actual flat historical families:
  150 passed.
- Managed-Terraform local migration/transfer integration suite: all 14 cases
  passed. The final full run passed 12; two were blocked by GitHub HTTP 500
  responses while downloading an AzAPI provider signature, and both passed
  their targeted rerun. Its workflow-entry case covers preview, native
  publication, completed rerun, all actual historical families, and unchanged
  exact-key historical state hashes.
- Final `pre-commit`: layout and lint passed; 2,897 unit tests passed, nine
  skipped; 1,442 component tests passed, one skipped. Two earlier transient
  directory-move access-denied errors in unrelated module-catalog component
  tests did not recur.
- Final historical-family lint passed without findings.
- Automatic hosted checks are pending.

## Blockers or dependencies

No live backend, Azure, Graph, Entra, credential, state, or workflow-control
operation is authorized to this session. Only code, synthetic local tests, and GitHub review
and automatic-check inspection are in scope. The user retains merge and
live retry control.

The state families are established by the parent's approved metadata-only
projections. Their initial extraction omitted the nonsecret AzAPI dynamic
`output.value.properties` and `body.value.properties` fields, so those
projections alone do not prove the identity/role relationship checks pass for
the live snapshots. The code requires that proof and fails closed when it is
absent. The legacy root has no root outputs; an empty root-output projection
is expected. The parent controls any separately approved additional evidence
and the subsequent live retry. Do not invent missing identity/principal proof
or claim a live migration succeeded.

Team documentation is coordinated by the parent in
[azure-cloud-native/Azure-Verified-Modules-Docs#52](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/52);
this slice will report findings rather than create a duplicate documentation
review.
