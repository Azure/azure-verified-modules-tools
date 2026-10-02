# Windows CI time budget

**Status**: in-progress
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Let the growing Windows coverage and component test gate finish within a
bounded job timeout, without disabling tests or extending other jobs.

## Checklist

- [x] Confirm the cancellation reason rather than treating it as a test failure.
- [x] Allow 30 minutes for Windows only; retain 15 minutes for Linux and macOS.
- [x] Run workflow tests and the local gate, commit, and push.
- [ ] Observe a completed Windows CI gate.

## Validation

[Windows CI on the central mock fix](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36983042110/job/110761705567)
reported `The job has exceeded the maximum execution time of 15m0s`.
Its coverage phase passed 2,539 tests with zero failures, then the job was
cancelled while the separately buffered component phase was running.
The matching local gate passed all unit and component tests.
The 60 existing workflow tests and the two new platform-budget assertions
passed. The installed actionlint reports the pre-existing `code-quality`
permission on both HEAD and the working copy; excluding only that known
schema mismatch produces no additional findings. The full gate passed
layout, lint, 2,634 unit tests (9 existing skips), and 1,287 component tests
(1 existing skip). Hosted confirmation of the updated limit remains pending.

## Blockers or dependencies

The timeout change does not establish that hosted Windows tests pass.
That remains subject to the next automatic CI result.
