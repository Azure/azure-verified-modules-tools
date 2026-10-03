# Native Azure dependency import scope

**Status**: in-progress
**Started**: 2026-10-03
**Updated**: 2026-10-03
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Make the selected Az.Accounts version visible to the native Azure modules'
global dependency imports. Preserve version floors, command provenance,
existing sign-in requirements and the refusal to replace an older loaded
version. This follows a real local prerequisite failure before authentication
or deployment, not a failure of an Azure resource operation.

## Checklist

- [x] Install only the approved missing Az.Subscription 0.12.0 module after
      all local and hosted checks passed.
- [x] Reproduce the import conflict in a fresh process and identify the
      nested Az.Resources global import.
- [x] Cover private-to-global dependency resolution with isolated fixture
      modules, including an already loaded eligible Accounts version.
- [x] Publish only the selected Accounts dependency globally before importing
      the remaining native modules.
- [x] Recheck the real installed prerequisites without signing in.
- [x] Requalify the unsigned package with the dependency regressions.
- [x] Pass the ordinary full development gate.
- [ ] Confirm hosted checks before using the approved live test.

## Validation

All 17 hosted checks for `9234c88` passed, including the complete Windows
component tier. The approved Az.Subscription 0.12.0 package is installed in
CurrentUser scope; its existing Az.Accounts dependency satisfies the package's
minimum and was not replaced.

The real dependency check then failed in a fresh process:
Az.Accounts 5.3.4 was imported privately inside Avm.Authoring, but the nested
Az.Resources 9.0.3 client could not see it. Its global import with a lower
minimum selected the user's older 3.0.4 installation and failed with an
assembly-version conflict. Preloading the eligible Accounts version in the
caller scope made the same real dependency check pass. Correct the shared
preflight rather than relying on that setup workaround.

Before the correction, the isolated fresh-process fixture reproduced the
nested client's legacy Accounts autoload; its caller-preloaded control
passed. After the correction, both cases pass. Standard lint, six focused
dependency unit tests and three component controls passed. The unit controls
retain loaded-old refusal, newest eligible explicit-path selection, command
provenance, complete dependency inventory and non-Accounts local imports.
Both dependency selectors and the new component selector are included in
extracted-package qualification.

The complete real installed dependency check also passes in a fresh process
without preloading Accounts externally. The selected global Accounts version
is 5.3.4. This check imports modules and examines command metadata only.

The refreshed unsigned 0.0.0 archive has SHA-256
`1DD4562705310CF5A2191638C917EE4B9FCE079053D6D1FD7AC7B90B185FF716`.
Its boundary is `9234c88bb7c021ad17ac0976fa32f1bbda439eb6` plus only the
dependency-import correction. That source file has SHA-256
`7164139C19C2AAFB6E28A11A40DCA0F4CA939DC4905166EDDD8333AC999F0718`.
All 348 payload files were byte-verified, 56 command definitions resolved
inside the extracted package, and packaged controls passed 174 unit and
145 component cases. Five actual pinned-compiler scaffold controls and
six real-compiler registry scenarios with simulated Azure passed.
All 5,611 frozen registry files remained unchanged.

The ordinary full development gate passed layout, lint, 2,814 unit tests
and 1,259 component tests, with nine unit skips and one component skip.
The complete local gate took 12 minutes 53 seconds. Hosted checks for the
correction commit remain separate and pending.

No sign-in, deployment, resource deletion or permission change has occurred.
The prepared live driver has not run and its single-case approval is unused.

## Blockers or dependencies

The one approved route-table smoke still requires a user-completed
process-only sign-in. New runtime bytes must pass local/package/hosted
qualification before that test; no other live case, release or registry
cutover is authorized.
