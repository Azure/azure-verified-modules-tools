# Terraform TFLint module-class scoping

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Adopt the released AVM TFLint ruleset's module-class option so only resource
module roots require `resource_id`, without allowing a pattern or utility
declaration to exempt a real resource module.

## Checklist

- [x] Pin the released ruleset version consistently in all packaged profiles.
- [x] Derive non-resource root classes from a verified repository identity
      and validate their metadata; keep unknown roots on the resource default.
- [x] Apply the class setting only to the root TFLint configuration and keep
      authored override warnings intact.
- [x] Cover resource, pattern, utility, conflicting identity, and child-module
      behavior with focused unit and real-ruleset tests.
- [x] Run the pre-commit gate, commit, and push the existing branch without
      force.

## Validation

The local plugin pin and root-class configuration are prepared but not
committed. `./build.ps1 layout` passed, as did 12 focused class/configuration
unit tests. The initial real TFLint integration test could not initialize v1.2.0:
`tflint --init` reports that its release has no `checksums.txt`. No local
test result at that point established that the proposed pin was installable.

## Blockers or dependencies

The initial v1.2.0 prerelease had no assets. Its protected release pipeline
had built and signed the binaries but was waiting for human approval to
publish and promote them. Earlier ruleset versions cannot parse
`module_class`, so the draft was held rather than shipping an unusable pin.
No Azure deployment, protected-job approval, or plugin publication is part
of this slice.

On October 2, normal publication completed: v1.2.0 is no longer a
prerelease and has all 12 platform archives plus `checksums.txt`.
[Checksum attestation](https://github.com/Azure/tflint-ruleset-avm/actions/runs/36982976021)
passed on the v1.2.0 tag at `c511cf0`. Only the ten deferred TFLint paths
were restored from the saved draft; the central mock fixes were retained.
Real pinned installation and execution then passed all seven integration
cases with zero skips: the existing attestation/interface/tag checks and
six resource-ID scenarios spanning resource roots with and without the
output, named patterns, extracted pattern candidates, utility Git origins,
and unknown identities. Each class case also checks child and example
profiles. The focused unit run passed 28 tests, including two CI-budget
assertions. Layout and lint passed; the full gate is pending.

Real-plugin checks caught a missing `enabled` field when creating a new
root rule block. The generator now supplies that default only for an absent
rule, preserving existing authored disables. The tag negative fixture now
removes the required top-level tags attribute, matching the released rule's
presence check rather than treating an empty map as invalid.
No release action was performed by this session.

The first full gate exposed 22 outdated unit-test assumptions: the old
plugin version and fictional `/cfg` paths that could not satisfy the new
configuration check. Engine tests now copy the packaged configurations into
their own test directory rather than bypassing that check. Unit and
component pin assertions now expect v1.2.0. All 53 focused engine, class,
and pin tests and all nine Terraform-chain component cases passed. The full
gate then passed layout, lint, 2,634 unit tests (9 existing skips), and
1,287 component tests (1 existing skip).
