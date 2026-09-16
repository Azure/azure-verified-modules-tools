# Provider alias preservation

**Status**: blocked
**Started**: 2026-09-16
**Updated**: 2026-09-16
**Branch**: `jaredfholgate-provider-alias-preservation`

## Outcome

Preserve `configuration_aliases` as HCL traversals when the packaged MAPOTF
rules upgrade AzAPI or Random requirements. Keep provider detection, version
gates, target constraints, and unrelated provider entries unchanged.

## Checklist

- [x] Read repository contracts and check existing branches and pull requests.
- [x] Investigate MAPOTF update methods and report the missing object-merge API.
- [x] Prepare both provider rules and directly related documentation.
- [x] Cover compliant aliases, separate and combined upgrades, multiple aliases,
      unrelated providers, inline/multiline syntax, comments, and idempotence.
- [x] Run the local pre-commit gate.
- [ ] Pass targeted integration tests with a compatible real MAPOTF binary.
- [ ] Run local transformation and drift checks on an isolated copy of
      Sebastian's actual Terraform module.
- [ ] Pin a compatible MAPOTF release with verified release archive hashes.

## Validation

The targeted `.\build.ps1 integration` suite on the existing 0.1.12 pin passes
all 17 existing cases. The 12 new alias cases reproduce its reader error.
`AVM_MAPOTF_TEST_BINARY` explicitly selects a local development executable for
this suite without changing the managed-tool cache or release pins.

- Repeated with a real development binary built from
  `Azure/mapotf@63f95f9b00d8f4cfdfbb7e27731be80559e369c0`, containing the alias
  reader and optional-provider-field fixes: all 17 existing cases and the three
  compliant-alias cases pass. The nine upgrade cases still fail because the
  existing transform replaces provider objects and drops their aliases.
- The tests compare Terraform-formatted copies for expected metadata and
  untouched content, and compare original files byte-for-byte between MAPOTF
  passes for idempotence. `terraform providers` checks the real alias syntax.
- `.\build.ps1 pre-commit`: passed; 1,425 unit tests passed, 8 skipped;
  all 117 component tests passed. After an analyzer retry exhaustion, a fresh
  PowerShell process passed the complete gate with 217 warnings and no errors.

## Dependencies

- Awaiting a compatible MAPOTF release and verified archive checksums from the
  coordinating session. The existing 0.1.12 pin and hashes remain unchanged.
- MAPOTF 0.2.0 cannot safely merge raw provider objects with its existing DSL.
  Both rules prepare the proposed opt-in `merge_object_attributes` API, reported
  to the coordinator before editing. A compatible MAPOTF implementation and
  release are required before this change can be accepted.
- The coordinator is awaiting the user's identification of Sebastian's module
  and exact revision. No real-module acceptance claim has been made.
- The separate MAPOTF optional-provider-field panic fix is outside this slice.
