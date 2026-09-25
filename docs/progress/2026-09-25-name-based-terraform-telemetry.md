# Name-based Terraform telemetry

**Status**: in-progress
**Started**: 2026-09-25
**Updated**: 2026-09-25
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Align Terraform deployment telemetry with Bicep's name-based reporting.
Keep the empty subscription-scoped AzAPI deployment and non-destructive
`modtm` migration, but remove its reporting tags. The deployment name carries
the metadata prefix, installed full version with dots replaced by hyphens
(`0-0-0` when unavailable), a one-character distribution source token
(`t` Terraform Registry, `o` OpenTofu Registry, `g` Git, `x` other), and the
stable four-character instance suffix. A changing empty-template output
forces one in-place write on each normal apply without changing that name.

All 396 cataloged Terraform prefixes match
`46d3xtrf.<kind>.<seven lowercase hex characters>` (20 characters). The
metadata schema should require that fixed form, and generated names must
reject a version that would exceed Azure's 64-character limit rather than
truncating data.

## Checklist

- [x] Update metadata schema, validators, and fixtures for seven-character
      Terraform identity segments.
- [x] Replace telemetry tags with the versioned name, source token, and
      changing empty-template output in the packaged mapotf rule.
- [x] Keep the TFLint exemption narrow for the tagless deployment.
- [x] Update tests and generated fixture documentation for the name contract.
- [x] Align tooling documentation and the existing published-spec review.
- [x] Run focused local integration and metadata coverage.
- [x] Run `./build.ps1 pre-commit`.
- [x] Correct the native Terraform metadata integration fixture to use
      seven-hex identifiers for both root and child modules.
- [ ] Commit and push the change to the existing feature branches; verify CI.

## Validation

Focused real-mapotf integration passed for name encoding, all four source
tokens, unversioned fallback, a 36-character version at the exact 64-character
name limit, rejection at 37 characters, child/helper behavior, and legacy
state. A mocked two-run Terraform test confirmed that a second normal plan
updates the existing telemetry deployment in place while keeping its name
stable. The AVM TFLint attestation kept ordinary resource-tag enforcement
and exempted only the generated tagless deployment. Example and provider
requirements integration passed (74 cases), as did targeted metadata and
repository-creation component coverage. Both fixture READMEs remained
canonical under the documentation generator. No live Azure resources were
changed.
`./build.ps1 pre-commit` passed with 1,829 unit tests (9 platform skips),
803 component tests, and no errors. The first gate run exposed a catalog
fixture that still authored descriptive Terraform prefixes; updating that
one shared fixture made the complete component tier pass.
The first pushed CI run exposed another descriptive Terraform prefix in
the native metadata-reader integration fixture. All six fixture integration
jobs failed at that same test. Updating its root and child seeds and keeping
the unsupported source-update assertion on a valid changed prefix restored
both native integration tests locally with
`./build.ps1 integration -TestName 'Integration: module metadata*'`.
The post-fix `./build.ps1 pre-commit` gate also passed with no errors.

## Blockers or dependencies

No production or canary deployment is authorized by this slice. Grafana
name parsing, OpenTofu compatibility, sovereign-cloud location overrides,
and subscription-scope permissions remain release gates.
