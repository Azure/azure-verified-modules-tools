# Credential-free Terraform policy plans

**Status**: complete
**Started**: 2026-09-03
**Updated**: 2026-09-03
**Branch**: `jaredfholgate-mock-azure-credentials`

## Outcome

Run the Terraform policy stage without Azure credentials while keeping the
plan JSON the same document a credentialled run produces.

The policy stage still performs the real `terraform init` -> `plan -out` ->
`show -json` sequence with the genuine `azurerm`/`azapi` providers. The only
change is where the providers get their access token: a synthetic, unsigned
token served over loopback in the managed-identity response shape.

## Design

`Start-AvmFakeAzureCredential` opens a loopback `TcpListener`, serves a
managed-identity token response, and returns the environment overrides that
point the providers at it. `Invoke-AvmTerraformCheckPolicy` applies those
overrides only when `Test-AvmAzureCredentialAvailable` finds no real
credential, and stops the endpoint in `finally`.

A real credential always wins. That keeps trusted runs on exactly today's
behaviour and coverage, including the examples whose data sources read
existing Azure resources. The synthetic credential is a fallback that gives
forks and credential-free contributors policy coverage they have no way to
get today, not a replacement for the credentialled path.

Three provider behaviours would otherwise still reach Azure, so the overrides
disable them: every non-MSI credential source, `ARM_PROVIDER_ENHANCED_VALIDATION`
(lists locations and resource providers from ARM), and
`ARM_RESOURCE_PROVIDER_REGISTRATIONS` (writes to the subscription).

## Why not `mock_provider`

The first implementation generated a `terraform test` file with
`mock_provider` blocks and synthesised the `configuration` section from
Conftest's HCL parse. A review with empirical verification found that
approach flips pinned rule outcomes in both directions:

- `mock_provider` bypasses the provider's `PlanResourceChange`, so
  provider-applied defaults such as `min_tls_version` and
  `shared_access_key_enabled` are emitted as `null` instead of their real
  values. This produced false positives (`AVM_SEC_137`, `AVM_SEC_138`) and
  false negatives (`AVM_SEC_STORAGE_PE_PUBLIC_ACCESS`,
  `AVM_SEC_AZPOLICY_BUILTIN_1`). It is not fixable inside `mock_provider`.
- The `test_plan` event carries no `configuration` section, so it had to be
  re-derived. The re-derivation diverged from Terraform's `jsonconfig` on
  nested-block arity, reference sets, and `data.` address prefixes.

Planning with a synthetic token avoids the entire class of problem: the plan
JSON is produced by Terraform, so there is nothing to re-derive and nothing to
keep in sync with `jsonconfig`. It also removed roughly 600 lines of HCL
parsing and plan synthesis, along with the dependencies on the undocumented
`terraform test -json -verbose` event schema and on Conftest's HCL JSON shape.

## Checklist

- [x] Serve a synthetic Azure token from a loopback endpoint.
- [x] Prefer a real credential whenever one is configured.
- [x] Disable every other credential source, enhanced validation, and
  resource-provider registration on the fallback path.
- [x] Detect data sources that need a real credential and fail the example
  with an actionable message instead of a provider authentication error.
- [x] Keep the real `init` -> `plan` -> `show -json` sequence unchanged.
- [x] Prepare the reusable PR check change for a separate post-release pull
  request.
- [x] Keep credentialled integration and end-to-end jobs trusted-only.
- [x] Run `./build.ps1 pre-commit`.

## Validation

- `./build.ps1 pre-commit` - green.
- `./build.ps1 integration` with `terraform-azurerm-avm-res-mock` and **no**
  Azure credentials in the environment: 17 passed, 3 skipped. This includes
  the `pr-check` chain, whose `check policy` step previously required OIDC.
- Both real fixtures with no credentials: the AzureRM fixture passed 130
  evaluations with no findings; the adversarial AzAPI fixture failed with
  exactly the three expected APRL/AVMSEC findings.
- Repeated with `HTTPS_PROXY`/`HTTP_PROXY` pointed at a closed port and
  `NO_PROXY` limited to loopback and the provider-distribution hosts, so every
  Azure endpoint was unreachable. Results were identical, proving the plan
  makes no Azure API call.
- Plan JSON shape confirmed canonical against a real credentialled plan:
  `format_version` 1.2, `planned_values`/`configuration`/`prior_state`
  present, nested blocks as arrays, `data.` address prefixes, full reference
  sets, and provider defaults applied (`min_tls_version = TLS1_2`).

## Known limitations

A create-only plan against empty state makes no Azure API call, so resources
plan correctly. Data sources are the exception: Terraform reads them during
plan whenever their configuration is known, and `-refresh=false` does not
suppress that, so a data source backed by a live API cannot resolve against
the synthetic credential. Seeding a state file does not help either, which was
verified: Terraform still logs `Reading...` and calls the API.

On the fallback path the engine therefore detects those declarations up front
(`Get-AvmTerraformCredentialledDataSource`) and reports the example as
`avm.tf.policy-needs-credential` instead of letting `terraform plan` surface a
provider authentication error. That is a **failure**, not a silent skip, so a
module owner can see the example is unverified and run the credentialled
pipeline from a branch in the module repository.

Detection is by provider prefix (`azurerm_`, `azapi_`, `azuread_`,
`azuredevops_`, `azurestack_`) with an allow-list for types that resolve
locally: `azurerm_client_config`, `azapi_client_config` (token claims) and
`azapi_resource_id` (a local ID parser). Unknown types fail closed, because
the alternative is a confusing provider error deep inside the plan.

`ARM_PROVIDER_ENHANCED_VALIDATION` is also off on the fallback path, so
provider-side location and resource-provider-name validation does not run.
TFLint and `terraform validate` still cover the configuration.

A fleet survey of 55 AVM Terraform repositories covering 344 example
directories found roughly 28% of examples declare at least one data source
needing a live API read, concentrated in six repositories and five data
source types (`azapi_resource_action`, `azurerm_subscription`,
`azurerm_role_definition`, `azapi_resource`, `azurerm_resource_group`).
Roughly 19% specifically need Azure ARM or Microsoft Graph; the remainder are
`http`, `azuredevops_*` and `github_*`. Module roots can also declare such
data sources, though many are `count`-gated.

Note that `terraform init` already needs registry and GitHub egress for
essentially every example, because `Azure/naming/azurerm` and the regions
utility module are fetched from the public registry.

## Rejected alternatives

- **Pre-seeded state plus `-refresh=false`.** Verified not to work: Terraform
  re-reads data sources during plan regardless of the state entry.
- **`override_data` with the real provider.** This does resolve data sources
  and, unlike `mock_provider`, preserves provider defaults. It was rejected
  for now only because the `test_plan` event still carries no `configuration`
  section, which five pinned AVMSEC rules read, so it would reintroduce the
  same false-negative class. Worth revisiting if Terraform adds
  `configuration` to that event.
- **A local ARM emulator.** The provider forces HTTPS on the metadata host, so
  it needs a trusted certificate, and Go uses the Windows system store rather
  than `SSL_CERT_FILE` on a Tier 1 platform. It would also require emulating
  per-resource-type ARM responses.

## Blockers or dependencies

The reusable `terraform-module.yml` change is deliberately split into a
separate pull request. It must merge only after this module implementation is
released to PSGallery, otherwise consumers would invoke credential-free
behavior before their installed module supports it.
