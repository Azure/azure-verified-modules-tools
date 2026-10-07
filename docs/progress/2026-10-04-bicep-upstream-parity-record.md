# Bicep registry upstream parity record

- Status: complete
- Started: 2026-10-04
- Branch: jaredfholgate-avm-authoring-refactor

## Outcome

Records how the native Bicep tooling compares with the registry after
[#219](https://github.com/Azure/azure-verified-modules-tools/pull/219). The baseline is registry `main` at `7c31eb8` plus pending
[Azure/bicep-registry-modules#7374](https://github.com/Azure/bicep-registry-modules/pull/7374) at `5287b1a`. Each implementation gap landed as its own behaviour-change commit, separate from the refactor commits. This record does not authorize a release, a live run or a registry cutover.

## Implementation gaps closed on this branch

| Upstream change | Commit | Progress |
|---|---|---|
| Submission-timeout observation (Azure/bicep-registry-modules#7455) | `0fa5b75` | `2026-10-04-bicep-deployment-timeout-watch.md` |
| Regional relocation, strict cleanup before relocation, structured operation errors (Azure/bicep-registry-modules#7455, Azure/bicep-registry-modules#7457) | `281188f` | `2026-10-04-bicep-regional-relocation.md` |
| Repository-root required-feature map (Azure/bicep-registry-modules#7456) | `6b27902`, tests repaired in `1e9218c` | `2026-10-04-bicep-required-features.md` |
| PSRule subscription token from the test pool (Azure/bicep-registry-modules#7438) | `6963c76` | `2026-10-04-bicep-psrule-subscription-pool.md` |
| Safe nested Azure error codes | `f7545e0` | `2026-10-04-bicep-safe-error-codes.md` |

## Covered without code changes

- Existing-only Microsoft Graph and Key Vault references compile without an object-ID parameter, and README generation does not list them as deployed resources. This is now an integration case in `BicepDocsScoped.Integration.Tests.ps1`.
- README inline comments and expressions, object metadata examples and keys, and cross-reference kind collisions were already covered.
- Canonical resource headers keep an intentional formatting difference. Legacy parallel README generation is replaced by a different implementation with the same outcome.

## Intentional differences

- Subscription ordering for e2e keeps the tools' seeded order contract.
- Changed, renamed and deprecated module selection uses the tools' own supported command surface.
- Gallery registration fallback is a registry bootstrap concern and is not ported.
- Registry-owned module and test asset updates, and child publish-path renames, are repository data, not tool behaviour.

## Requirements for any future authorized cutover

These belong to the registry's calling workflows. They are not implemented here and must be preserved before the registry switches to these tools:

- Two-label e2e gating, generic-workflow retry exclusion, and skipping ignored jobs before checkout, setup or login.
- Sanitized matrix data based on pool position and digest, and verifying the selected subscription before login.
- Stable module and subscription locks, plus shared deployment-phase locks for management-group, tenant, linked and expression-valued nested templates.

## Validation

- `./build.ps1 integration -TestName 'Integration: Bicep docs scoped examples*'`: 5 passed in 52s.
- Each implementation commit above passed `./build.ps1 pre-commit`.