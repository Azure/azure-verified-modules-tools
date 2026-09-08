# Mapotf provider requirements

**Status**: complete
**Started**: 2026-09-08
**Updated**: 2026-09-08
**Branch**: `jaredfholgate-mapotf-provider-entry-bug`

## Outcome

Fix [issue #104](https://github.com/Azure/azure-verified-modules-tools/issues/104):
leave provider-free helpers without an AzAPI requirement and enforce the current
AzAPI version floor where the module requires it, without weakening unused-provider
linting.

The module profile now considers direct AzAPI resource/data blocks and existing
declarations before enforcing `~> 2.12`. The root profile runs first, so its
generated telemetry still gets the requirement. The schema request and canonical
root fixtures use the same floor.

## Checklist

- [x] Reproduce the provider insertion and establish direct-use detection.
- [x] Update the provider rule and add regression coverage.
- [x] Run the relevant real-binary tests and the pre-commit gate.
- [x] Commit and push the slice.

## Validation

- Reproduced the original unwanted `~> 2.4` insertion in a provider-free helper
  with the pinned MAPOTF binary.
- `.\build.ps1 integration`, with Pester `Run.ExcludePath` excluding the other
  integration files: 17 passed, none skipped. Covers absent/empty requirements,
  built-in and other providers, child-only AzAPI use, direct resources/data,
  existing function-only declarations, version bounds, unused-provider lint,
  root telemetry, idempotence, and the full root/submodule transform-drift chain.
- `.\build.ps1 pre-commit`: passed; 1,044 unit cases (8 skipped), 29 component
  cases, and the layout/lint gates. PSScriptAnalyzer reported 151 non-blocking
  warnings.
- `git diff --check`: clean.

## Blockers or dependencies

None.
