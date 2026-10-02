# Telemetry migration for explicit unit-test targets

**Status**: in-progress
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Preserve existing unit-test targets and assertions during central telemetry
migration. Establish which local delegated runs can be migrated safely
without weakening the safeguards for unknown dependencies or real providers.

## Checklist

- [x] Identify an active, published repository with existing delegated tests.
- [x] Reproduce the unsupported scope locally without Azure access.
- [x] Identify affected provider mocks and the generated location contract.
- [ ] Add native Terraform-test support to MaPoTF before extending Tools rules.
- [ ] Implement and test only source-proven migration cases.
- [ ] Run the full gate, commit and push, then repeat the narrow preview.

## Evidence

`Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet`
is active and published. Its main at
`670c45d48b0c7c6a244cddac8715269b0fc06185` includes three genuine unit-test
files. Firewall public-IP tags and BGP-propagation tests use
`module { source = "./modules/hub-virtual-network-mesh" }`; primary-region
selection tests target the root. All retain authored telemetry opt-outs.
The current mock migrator explicitly rejects delegated run modules, so a
remote dispatch would not yet provide useful additional evidence.

Locations are supplied inside hub objects. Check the migrated root and child
input contracts before deciding whether tests need another location value;
do not alter the authored per-hub locations or invent production defaults.

A controlled real-MaPoTF regression reproduced the delegated-run rejection
with one root run and one local-child run, provider mocks, authored telemetry
opt-outs and different hub regions. It failed at the current explicit scope
guard before any Terraform test execution or Azure call. The regression is
preserved as the session artifact `telemetry-unit-scope-regression.patch`,
outside committed test discovery until its native prerequisite exists.

Both real root and child metadata declare telemetry prefixes. Neither
inspected `variables.tf` declares a standalone location input. The generated
telemetry contract requires one, so migration must handle test inputs as well
as provider mocks without overwriting the authored hub regions.

The requester selected native Terraform-test support in MaPoTF rather than
a larger HCL text-rewriting layer in Tools. Released MaPoTF 0.2.2 indexes
standard Terraform root block kinds, not test runs, global test variables
or mock-provider blocks. Source work is isolated in the MaPoTF project,
starting from main `aa6f5045d34bccc772f115a3198b2aa98e87bf32`.
The Tools production pin remains unchanged.

The agreed native interface is opt-in single-file selection:
`transform --tf-dir <owner> --test-file <relative.tftest.hcl>`.
Only the selected file may change; normal Terraform discovery stays unchanged.
`data "test_file"` exposes file identity, runs, mock providers and explicit
root/local/remote run targets. The existing `module_source` data source can
inspect known local target declarations without provider initialization.
The planned `debug --eval <expression>` option returns one JSON value without
applying transforms. Tools will use a before-migration declaration snapshot,
so an authored location or unrelated pre-existing missing input is not
silently replaced. These are proposed upstream capabilities, not released
functionality or a completed Tools integration.

## Blockers or dependencies

Investigation is local and source-only. Archived repositories remain excluded.
No deployment, module publication, protected approval, or source-module repair
is authorized by this slice.
Tools integration and its real regression depend on a reviewed, approved
MaPoTF release with verified assets. No merge or release publication has been
authorized. Existing direct-unit migration remains qualified by the preceding
local gate, all-platform CI and active-pattern preview.
