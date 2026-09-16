# Provider alias preservation

**Status**: complete
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
- [x] Pin a compatible MAPOTF release with verified release archive hashes.
- [x] Validate MAPOTF 0.2.1 through normal pinned-tool selection and existing-module regressions.

## Validation

### Published MAPOTF 0.2.1 acceptance

- All six official MAPOTF 0.2.1 release archives were downloaded and hashed
  against `checksums.txt` and GitHub asset digests. Both Windows executables
  have valid Microsoft Authenticode signatures. Only MAPOTF's version and six
  hashes changed through `scripts/Update-AvmPins.ps1 -Mapotf 0.2.1`.
- Normal `Install-AvmTool` / `Resolve-AvmTool` selected `mapotf/0.2.1` from an
  isolated `AVM_HOME`, with `AVM_MAPOTF_TEST_BINARY` unset. The executable reports
  release commit `bc1fc9f9d293e853078cae1f5e1aae78e0101ed1`, built
  `2026-09-16T13:44:05Z`, and has a valid Microsoft signature. Its SHA-256
  matches the independently extracted official amd64 executable:
  `ac3aac82dd7eb5841ac7d98a33b36673f695de7f187f89271ec6a05a0b94af40`.
- `.\build.ps1 pre-commit`: 1,425 unit tests passed, eight skipped; all 117
  component tests passed. Existing analyzer retries recovered; 187 warnings,
  no errors.

The safe local integration selection ran through `.\build.ps1 integration`:

| Suite | Passed | Failed | Skipped | Excluded |
| --- | ---: | ---: | ---: | ---: |
| Provider requirements, including representative Fabric/AzAPI | 31 | 0 | 0 | 0 |
| Git module sources and subdirectory resolution | 3 | 0 | 0 | 0 |
| Deprecated interfaces | 7 | 0 | 0 | 0 |
| Existing AzAPI/AzureRM module chains | 7 | 0 | 5 | 4 |
| Total | 48 | 0 | 5 | 4 |

Both existing fixtures remain unchanged after pre-commit. Legacy-header cleanup,
provider ordering, full-profile drift, and native unit tests with mocked
providers also pass. The initial run had 47 passes and one GitHub HTTP 500 while
fetching AzAPI authentication checksums. A requested targeted retry repeated the
full safe selection and passed all 48 cases; both runs' logs and results are
retained separately. No source or retry policy was changed to hide that failure.

The five existing fixture-specific skips were:

| Fixture | Test | Reason |
| --- | --- | --- |
| AzAPI | unit tier installs modules referenced by run blocks from a cold working directory | Only AzureRM carries the run-block helper. |
| AzureRM | validates examples that consume deprecated module interfaces without failing | Only AzAPI carries deprecated interfaces. |
| AzureRM | removes legacy AVM headers and their telemetry helper locals | Legacy AzAPI headers are exercised on the AzAPI fixture. |
| AzureRM | sorts required provider entries with released MAPOTF nested-block ordering | Ordering is exercised on the AzAPI fixture. |
| AzureRM | unit tier preserves deprecated aliases and safe defaults through a child-module wrapper | Only AzAPI carries these deprecated interfaces. |

Two tests were explicitly excluded for each fixture, four cases total, because
they run real Azure-contacting policy plans: `pr-check runs every step, evaluates
plan policies, and resolves tools from the AVM cache` and `keeps a real policy
exception scoped to its own example`. The harness's Defender preference calls
were prevented by a process-local throwing guard; no host protection settings
changed. No live Terraform apply or cloud operation ran.

### Earlier release and development baselines

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
- Earlier `.\build.ps1 pre-commit`: passed; 1,425 unit tests passed, 8 skipped;
  all 117 component tests passed. The existing analyzer retry handled transient
  failures; that gate completed with 230 warnings and no errors.

The final targeted acceptance uses the repository build entry point without a
binary override:

```powershell
Remove-Item Env:\AVM_MAPOTF_TEST_BINARY -ErrorAction SilentlyContinue
$env:AVM_HOME = '<isolated validation directory>'
$PesterPreference = @{ Run = @{ TestExtension = 'MapotfProviderRequirements.Integration.Tests.ps1' } }
.\build.ps1 integration
```

Only earlier development/0.2.0 comparisons used the test-binary override.

## Dependencies

- MAPOTF 0.2.1 is stable and contains
  [Azure/mapotf#129](https://github.com/Azure/mapotf/pull/129), including the
  opt-in object merge. It is now pinned with all six verified archive hashes;
  the release-adoption blocker is resolved.
- Keep [the tools change](https://github.com/Azure/azure-verified-modules-tools/pull/124)
  draft for the coordinator's new-head hosted-CI review and readiness decision.
  Local fixture coverage is not a guarantee for every existing module.
- Following the user's updated instruction, cover the public pattern in
  [Azure/Azure-Verified-Modules#2932](https://github.com/Azure/Azure-Verified-Modules/issues/2932)
  with representative fixtures. The private implementation was not inspected
  or tested. Capacity is looked up, not provisioned; no cloud activity runs.
- The separate MAPOTF optional-provider-field panic fix is included in 0.2.1
  but was not duplicated in this tools slice.
