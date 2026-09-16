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
- [x] Enable object-attribute merging in both provider rules and update documentation.
- [x] Cover compliant aliases, separate and combined upgrades, multiple aliases,
      unrelated providers, inline/multiline syntax, comments, and idempotence.
- [x] Run the local pre-commit gate.
- [x] Pass targeted integration tests with a compatible real MAPOTF binary.
- [x] Cover the public Fabric workspace proposal with representative Fabric
      and AzAPI aliases, resource/data references, upgrades, and idempotence.
- [x] Verify official MAPOTF 0.2.0 archive/signature provenance and run all 31 cases.
- [ ] Pin a compatible MAPOTF release with verified release archive hashes.

## Validation

- The official [MAPOTF 0.2.0 release](https://github.com/Azure/mapotf/releases/tag/v0.2.0)
  is now published. Its Windows amd64 executable passes 21 of the same 31
  integration cases, with ten failures and no skips. All original cases and
  compliant aliases pass; the nine matrix upgrades and the Fabric/AzAPI upgrade
  still drop aliases. It reports commit `4a12a4858c9674bcb3a8470cafe9a4a02c118746`,
  built `2026-09-16T08:03:50Z`, and does not contain the object-merge capability.
- Before executing that release, the downloaded Windows archive SHA-256 matched
  both official `checksums.txt` and GitHub's asset digest:
  `27a68df04493d723f3e53e9a4c995e8898861945cdc3201e18847b753c00547a`.
  Windows Authenticode reported `Valid`, signed and timestamped by Microsoft.
  The executable SHA-256 is
  `60df09f4e98b9f6cd1d640cbc1bcd3ae2638037afae5a6f21a4b3b27e6013213`.
  The release ran from isolated session storage, not the managed cache; the
  existing managed MAPOTF files and pins were unchanged after testing.
- All 31 integration cases pass, with no failures or skips, against the real
  development executable from
  [Azure/mapotf@b40b96c](https://github.com/Azure/mapotf/commit/b40b96c59cc36b78248808f944a3dc12479a81d3).
  Its reported version is `dev-object-merge-b40b96c`, and its full commit and
  SHA-256 were independently verified:
  `9a607177363bde00f3fe780a20fe0445a19a6c4d645da4e0e3574cae12ce400d`.
- Before the object-merge implementation, the same 31-case suite against
  reader-fixed commit `63f95f9b00d8f4cfdfbb7e27731be80559e369c0` had 21 passes
  and ten alias-loss failures. All ten upgrades now pass.
- The original 29-case baseline on pinned MAPOTF 0.1.12 passed the 17 existing
  cases; its 12 matrix alias cases reproduced the reader error.
- The representative Fabric case checks the complete Fabric requirement,
  workspace/resource and existing-capacity/data provider references, and AzAPI
  networking/resource and client-config/data references. Both compliant and
  upgraded constraints pass on the object-merge development build without
  reading private source; the official 0.2.0 upgrade remains failing.
- The tests compare Terraform-formatted copies for expected metadata and
  untouched content, and compare original files byte-for-byte between MAPOTF
  passes for idempotence. `terraform providers` checks the real alias syntax.
- `.\build.ps1 pre-commit`: passed; 1,425 unit tests passed, 8 skipped;
  all 117 component tests passed. The existing analyzer retry handled transient
  failures; the latest gate completed with 230 warnings and no errors.

The targeted run uses the repository build entry point:

```powershell
$env:AVM_MAPOTF_TEST_BINARY = '<absolute path to the verified executable>'
$PesterPreference = @{ Run = @{ TestExtension = 'MapotfProviderRequirements.Integration.Tests.ps1' } }
.\build.ps1 integration
```

The binary override only replaces tool selection in this integration suite;
execution is real, and no managed cache entry or release pin is fabricated.

## Dependencies

- Release adoption remains blocked: a published MAPOTF release must contain
  [Azure/mapotf#129](https://github.com/Azure/mapotf/pull/129), including the
  opt-in `merge_object_attributes` implementation, and provide all six verified
  archive hashes. Official MAPOTF 0.2.0 is published and verified but fails all
  ten alias-upgrade regressions; it is not a compatible release. The existing
  0.1.12 pin and hashes remain unchanged.
- Keep [the tools change](https://github.com/Azure/azure-verified-modules-tools/pull/124)
  draft until that release is pinned and the native suite passes against it.
- Following the user's updated instruction, cover the public pattern in
  [Azure/Azure-Verified-Modules#2932](https://github.com/Azure/Azure-Verified-Modules/issues/2932)
  with representative fixtures. The private implementation was not inspected
  or tested. Capacity is looked up, not provisioned; no cloud activity runs.
- The separate MAPOTF optional-provider-field panic fix is included in the
  development binary but was not duplicated in this tools slice.
