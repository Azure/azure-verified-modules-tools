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
- [x] Cover the public Fabric workspace proposal with representative Fabric
      and AzAPI aliases, resource/data references, upgrades, and idempotence.
- [ ] Pin a compatible MAPOTF release with verified release archive hashes.

## Validation

The original 29-case `.\build.ps1 integration` baseline on the existing 0.1.12
pin passes all 17 existing cases. Its 12 alias cases reproduce the reader error.
`AVM_MAPOTF_TEST_BINARY` explicitly selects a local development executable for
this suite without changing the managed-tool cache or release pins.

- The expanded 31-case suite uses a real development binary built from
  `Azure/mapotf@63f95f9b00d8f4cfdfbb7e27731be80559e369c0`, containing the alias
  reader and optional-provider-field fixes: 21 pass, including all 17 existing
  cases, three compliant-alias layouts, and the compliant Fabric/AzAPI case.
  Ten upgrade cases still fail because provider objects lose their aliases.
- The representative Fabric case checks the complete Fabric requirement,
  workspace/resource and existing-capacity/data provider references, and AzAPI
  networking/resource and client-config/data references. The upgraded case
  demonstrates the remaining alias-loss defect without reading private source.
- The tests compare Terraform-formatted copies for expected metadata and
  untouched content, and compare original files byte-for-byte between MAPOTF
  passes for idempotence. `terraform providers` checks the real alias syntax.
- `.\build.ps1 pre-commit`: passed; 1,425 unit tests passed, 8 skipped;
  all 117 component tests passed. The existing analyzer retry handled transient
  failures; the latest gate completed with 230 warnings and no errors.

## Dependencies

- Awaiting a compatible MAPOTF release and verified archive checksums from the
  coordinating session. The existing 0.1.12 pin and hashes remain unchanged.
- MAPOTF 0.2.0 cannot safely merge raw provider objects with its existing DSL.
  Both rules prepare the proposed opt-in `merge_object_attributes` API, reported
  to the coordinator before editing. A compatible MAPOTF implementation and
  release are required before this change can be accepted.
- Following the user's updated instruction, cover the public pattern in
  [Azure/Azure-Verified-Modules#2932](https://github.com/Azure/Azure-Verified-Modules/issues/2932)
  with representative fixtures. The private implementation was not inspected
  or tested. Capacity is looked up, not provisioned; no cloud activity runs.
- The separate MAPOTF optional-provider-field panic fix is outside this slice.
