# Metadata integration contract

**Status**: complete
**Started**: 2026-09-15
**Updated**: 2026-09-15
**Branch**: `jaredfholgate-module-metadata-implementation`

## Outcome

Update the real-binary integration expectations for the metadata step added to
both authoring chains. Hosted build jobs passed, but all integration jobs still
expected the old step sequences. No production behavior changes are required.

## Checklist

- [x] Confirm both provider fixtures fail only the two outdated chain assertions.
- [x] Include metadata in both expected sequences and assert warning-only behavior.
- [x] Run the local gate, commit, and push the correction.

## Validation

Failed hosted run: 34956830026, head
`9a75d48a9002865de27673004c7f688f523ea0ac`. All three build jobs passed.
Linux logs for both fixtures show the actual chains include the intended
metadata step and its status passes. The subsequent exact-sequence assertions
fail because they omit that step.

The corrected tests also require built-in metadata validation, a warning for
the missing root metadata file, no error-severity issues, and no metadata file
creation. No outdated chain-sequence expectations remain in the test tree.

Local `.\build.ps1 pre-commit` passed: 1,301 unit tests, 8 existing skips, and
345 component tests, with zero errors. Hosted real-binary execution remains
the required final verification on the new commit.

## Dependencies

Real-binary policy integration uses the existing CI test environment. No
production workflow or repository synchronization is run by this change.
