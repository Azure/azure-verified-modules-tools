# Repository management

This area owns the managed files and scheduled repository synchronization used
by AVM Terraform repositories, plus the shared Bicep/Terraform module catalog.

[Module catalog sync](module-catalog/README.md) owns the generated CSV/JSON
indexes and source CSV row-removal protection.

New Terraform repositories are created with `avm init` from
[Avm.Authoring](../src/Avm.Authoring/README.md#initialize-a-terraform-module-repository),
which publishes the module's own metadata in its first commit. Repository sync
takes over once the AVM GitHub App is installed. No separate tooling inventory
registration is required. Agents can follow the
[`avm-tf-module-repository-creation`](../.github/skills/avm-tf-module-repository-creation/SKILL.md)
skill, which covers the inputs to ask for and the Open Source Portal steps.

[State infrastructure and TME cutover](repository-sync/README.md) documents
the independent state identity, deployment, migration, and rollback.

The current snapshot came from the legacy Terraform governance repository at commit
`59078e1bde61af0a5881331d2d26a41f791f5624`. This is an interim home until
these capabilities move to Proxima.

## Standard GitHub labels

[`labels/avm-standard-github-labels.json`](labels/avm-standard-github-labels.json)
is the source for AVM standard label names, descriptions, and colors. Terraform
repository sync reads it locally; the `Repos: Label Sync` workflow reconciles
the AVM and Bicep repositories daily and when the catalog changes. The workflow
only creates or updates standard labels, retaining repository-specific labels.
Manual runs default to a write-free plan.

The same workflow proposes a generated CSV update in the AVM repository. Keep
its existing CSV URL for the public specification's table and download, but
edit the JSON here instead. The one `githubDescription` override preserves the
longer specification text while keeping the GitHub label description within
GitHub's 100-character limit.

## Pull request reviewer routing

`Repos: PR Routing` handles Bicep and active Terraform module repositories in
the AVM App installation. Terraform discovery shares repository sync's provider
and module-name rules; archived repositories and tooling/template repositories
are excluded before the reviewer token is scoped.

Owners come from the published module catalog, with the request head's
`metadata.json` taking precedence when root metadata changes or a module is
not yet indexed. Terraform resolves all files, examples, and child modules to
the repository root's owners; child metadata cannot declare owners. Bicep
module-path and core-team rules are unchanged. Both ecosystems skip drafts,
the author, existing review requests, and people who already reviewed, and
only add missing reviewers and labels.

The fifteen-minute runs search batches of twenty Terraform repositories for
ready requests updated in the last hour. GitHub cannot match a repository-name
wildcard in an issue search, so each batch supplies exact `repo:` qualifiers.
Incomplete results, pagination changes, search failures, or the 1,000-result
search cap trigger complete per-repository listing instead. The daily sweep
and manual runs with a zero-minute lookback always list every repository
directly, avoiding dependence on search indexing. The catalog is read once
per run; individual request or repository failures do not stop the remainder.

Manual runs default to `what_if: true`. Leave the URL empty for a fleet sweep,
use a full GitHub URL for a Terraform request, or use a bare number for Bicep.
The workflow accepts only active installed targets, keeps schedule/manual-only
triggers and the `avm` environment, and grants its writer token only content
read, pull-request write, and member read on the selected repositories.
Merging a workflow change extends scheduled routing; live dry runs or writes
still require operator approval.

## Terraform repository metadata

Repository discovery reads and validates each selected repository's root
`metadata.json` on its default branch. The display name and full `owners` array
replace the retired tools-local CSV inventory. GitHub's archived flag is
authoritative; archived repositories are skipped without reading metadata.
The generated public module indexes remain separate catalog outputs.

During rollout, a missing file produces a warning and leaves the repository
eligible for sync, but direct collaborator cleanup is skipped until ownership
is available. Sync does not create metadata files. Invalid metadata or API
failures exclude the affected repository and produce an error.

Direct administrators listed as owners, including members of qualified owning
teams, retain the existing just-in-time access exemption. Unresolvable teams
stop collaborator cleanup with an error; an explicitly empty owner array is
not treated as unavailable metadata. Other direct access remains subject to
the existing cleanup policy.

## Test tenant selection

`testTenant` accepts only `legacy` or `bami`. The
[Terraform configuration](repository-config/config.json) defaults to `bami`
for all repositories discovered by the existing Terraform sync, including new
and otherwise unlisted repositories. Configuration is the source of truth;
tenant selection is independent of managed-file promotion. Higher `order`
wins; later declaration wins a tie, so explicit legacy exceptions remain
supported. If no matching group declares `testTenant`, the resolver still
falls back to `legacy`.

Tools publishes BAMI execution settings for `Azure/bicep-registry-modules`
using generic `VALIDATE_*` Variables, without per-module canary selectors.
Consumer bindings use generic Variables first, then Secrets, without a
repository or provider mode check. External contributors retain configurable
credentials, subscription pools, and Key Vault paths, including the existing
Key Vault capability and deprecation warning. The legacy consumer aliases
`TEST_SUBSCRIPTION_IDS`, `VALIDATE_SUBSCRIPTION_ID`, and `ARM_MGMTGROUP_ID`
remain supported. The independent `CI_` configuration still resolves Secrets
before Variables before Key Vault. Manual test-scope inputs remain independent
of tenant selection. Consumer changes are maintained separately.

The BAMI publisher stages this complete nonsecret bundle in the Tools `avm`
environment. There is one current BAMI tenant, not a profile catalog.

| Variable | Purpose |
| --- | --- |
| `TEST_BAMI_TENANT_ID` | Candidate tenant |
| `TEST_BAMI_CONTROLLER_CLIENT_ID` | Repository-identity provisioning only |
| `TEST_BAMI_ADMIN_SUBSCRIPTION_ID` | Subscription holding repository identities |
| `TEST_BAMI_SUBSCRIPTION_IDS` | Exactly 28 unique `{name,id}` objects, encoded as JSON |
| `TEST_BAMI_MANAGEMENT_GROUP_ID` | Test management-group name |
| `TEST_BAMI_IDENTITY_RESOURCE_GROUP_NAME` | Existing repository-identity resource group |
| `TEST_BAMI_BICEP_CLIENT_ID` | Separate Bicep execution identity |
| `TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID` | Bicep persistent-resource subscription |

Admin and Persistent must be different subscriptions, and neither may appear
in the disposable test pool. The shared Bicep-only guard also rejects
Persistent overlap without copying Admin into the Bicep projection.

Terraform sync uses dedicated per-repository identities, never the controller
or Bicep client as a test identity. It replaces the existing repository
**secrets** `ARM_TENANT_ID`, `ARM_CLIENT_ID`, and `TEST_SUBSCRIPTION_IDS`; writing
same-named variables would not override the current consumers' secrets.
Explicit legacy selections retain the legacy consumer settings. See the
[candidate state and execution prerequisites](repository-sync/README.md#bami-candidate-identities).

Bicep variable sync maps only the five validated execution fields to generic
target Variables; the eight-field source bundle above is unchanged.

| BAMI source field | Consumer target Variable |
| --- | --- |
| `TEST_BAMI_TENANT_ID` | `VALIDATE_TENANT_ID` |
| `TEST_BAMI_BICEP_CLIENT_ID` | `VALIDATE_CLIENT_ID` |
| `TEST_BAMI_SUBSCRIPTION_IDS` | `VALIDATE_SUBSCRIPTION_IDS` |
| `TEST_BAMI_MANAGEMENT_GROUP_ID` | `VALIDATE_MANAGEMENT_GROUP_ID` |
| `TEST_BAMI_PERSISTENT_SUBSCRIPTION_ID` | `VALIDATE_PERSISTENT_SUBSCRIPTION_ID` |

Only these five generic Variables are managed. Old `TEST_BAMI_*` aliases,
the retired `TEST_BAMI_MODULE_PATHS` selector, and legacy customer keys are
outside the managed snapshot and write allowlist. The publisher neither
writes nor deletes them and never reads or writes Secrets. The five execution
values remain strings, including the compact subscription-pool JSON.

Tools rejects incomplete or malformed source bundles before publication.
Reserved-subscription and identity separation checks are unchanged.
These checks do not prove that separately
published source values came from the same publication; a complete but mixed
bundle may still pass structural validation.
Successful variable readback is not proof of Azure authentication or permissions.
Bicep activation also requires its own execution-identity federated credential
for the intended subject
`repository_owner_id:6844498:repository_id:447791597:environment:avm-validation`.
Source validation does not verify that credential or runtime login; never reuse
the Tools-controller credential as the Bicep execution identity.

### Bicep variable publication

The separate `sync-test-tenant-variables` job in Bicep Sync requires trusted
Tools `main`. Scheduled runs use `33 2-23/4 * * *` (02:33, 06:33, 10:33,
14:33, 18:33 and 22:33 UTC); manual dispatch has no inputs. Both call the
entry point with `-Apply` and reconcile the five generic execution Variables.
There is no workflow enable flag, preview flag or global activation variable.
The App must separately be approved for Actions Variables (`actions_variables: write`) on
`Azure/bicep-registry-modules`. Its variable token has no content, secret,
workflow, or pull-request write permission.
The pinned action's [generic permission-input parser](https://github.com/actions/create-github-app-token/blob/bcd2ba49218906704ab6c1aa796996da409d3eb1/lib/get-permissions-from-inputs.js)
maps `permission-actions-variables: write` to `actions_variables: write`.
Its manifest omits this input, so an undeclared-input warning can occur; the
runner still passes it to the action. Do not use `permission-variables` or omit
the explicit scope.

The retired Bicep CODEOWNERS job and its merge behavior are not part of this
workflow. BAMI-selected Terraform repositories also attempt preparation during
normal sync, including scheduled applies, subject to their existing prerequisites.

[Invoke-BicepTestTenantSync.ps1](bicep-test-tenant-sync/scripts/Invoke-BicepTestTenantSync.ps1)
defaults to a read-only plan. Standalone publication requires an explicit,
operator-approved `-Apply`; `-PlanOnly:$false` is rejected, and `-Apply -WhatIf`
is write-free. The script uses eight named environment variables, plus
`GH_TOKEN`; it accepts no target or configuration override.

All eight source values are required even for plans. The publisher treats
upstream BAMI execution as always active: any present generic target value that
differs from the validated projection stops publication, including plans,
before any write. Missing variables may be
initialized only when every present value matches. Retargeting requires
coordinated maintenance outside this routine publisher; there is no selector
deactivation route. Each write has a snapshot preflight and readback, followed
by complete execution-value verification and a final snapshot check.

Migration is held for coordinated review and live authorization: merge and
publish the generic-variable publisher first to stage and verify the complete
five-variable bundle, then switch consumers, then drain old code before
separately authorized cleanup of obsolete names. Old aliases and maintenance
inputs remain untouched while staging. If a generic target already contains a
different value, publication fails closed; there is no migration flag or
retarget bypass.

Do not run other variable writers alongside the serialized workflow. GitHub
variables cannot be updated conditionally as one transaction: snapshot checks
detect observed edits but cannot eliminate races between reads and writes.
Failures never trigger write retries or rollback. Even a matching readback
after a lost response is reported as an error, so a failed run may already have
written some execution values. Inspect the consumer before retrying. `Published`
means verified variable contents, not working Azure authentication.

After an acknowledged write, an unchanged pre-write snapshot permits at most
three additional GETs after 5, 10 and 15 seconds. Other observed changes,
unexpected values or timestamps, failed reads and unacknowledged writes still
stop immediately. Every read retains the same strict comparison; this bounded
wait does not retry writes or bypass complete and final verification.

## Terraform CODEOWNERS

Repository sync renders [CODEOWNERS.template](repository-sync/CODEOWNERS.template)
from [repository configuration](repository-config/config.json). Matching groups,
including the wildcard `default` group, contribute `codeOwnersTeams` for the
default `*` rule and `codeOwnersFileProtectionTeams` for the subsequent
`.github/CODEOWNERS` rule. Teams are deduplicated and qualified with the target
organization; a group targeting one repository can supply its specific owners.
An empty team list omits that configured rule.

The final rule is always
`metadata.json @Azure/azure-verified-modules-engineering-owners @Azure/azure-verified-modules-module-owners`, including when
configured team lists are empty. The unrooted basename covers root and child
metadata files; other files retain their configured owners. The teams are
alternatives: approval from either team satisfies code-owner review, not both.

Review enforcement also requires the existing active ruleset's
`require_code_owner_review = true` and visible teams with repository write
access. Default Terraform configuration grants both teams `push` without
adding environment approvals; the existing CODEOWNERS-file rule remains
engineering-only. Neither the template nor its generation grants or broadens
the existing AVM App bypass; authorized operators must verify these
prerequisites before rollout.

Repository groups may set `pullRequestBypassTeams` to a list of configured team
slugs. Terraform resolves their team IDs and grants a pull-request-only bypass
of the main branch ruleset alongside the existing AVM App. Only
`canary-ring-0` sets this list, to
`azure-verified-modules-engineering-owners`, so only
`avm-ptn-example-repo` gets the team bypass. It covers all pull-request rules,
not just approvals; it does not allow direct pushes or bypass tag rulesets.

The generated file replaces stale content or creates a missing file after
`avm pre-commit` succeeds, in the same temporary checkout and publication flow.
Plan-only runs show local drift without publishing. Edit the configuration or
template here, not the generated files in individual module repositories.

## Staged managed-file rollout rings

Managed files live in [`Azure/azure-verified-modules-managed-files`](https://github.com/Azure/azure-verified-modules-managed-files)
under `terraform`, one folder per file group. A repository receives `root` plus
every overlay declared by the repository groups it belongs to, applied in
`order`; higher `order` wins. The narrowest ring therefore carries the highest
`order`.

| Ring | Directory | Repositories | `order` |
| ---- | --------- | ------------ | ------- |
| 0 | `terraform/canary-ring-0` | `avm-ptn-example-repo` only | 20 |
| 1 | `terraform/canary-ring-1` | the ten canary repositories | 10 |
| – | `terraform/root` | every managed repository | base |

Author a risky change in `canary-ring-0`, then promote it a ring at a time:

```pwsh
git mv terraform/canary-ring-0/<path> terraform/canary-ring-1/<path>
git mv terraform/canary-ring-1/<path> terraform/root/<path>
```

A file's directory is the only thing that selects its audience, so promotion
never edits the repository group config and never changes cohort membership.

**Promote by moving, never by copying.** Overlays beat `root`, so a copy left
behind in a higher ring keeps overriding `root` for that ring's repositories. The
symptom is that every repository picks up the change except the one used to test
it.

Each group folder also carries a reserved `_config.json` that is never synced
into a target repository. It declares the group's `description`, its
`deletedFiles`, and its `managedLines`. To stop shipping a file everywhere, add
it to the `deletedFiles` array in the relevant group's `_config.json`. That both
suppresses the file and removes any copy already present in the target
repository.
