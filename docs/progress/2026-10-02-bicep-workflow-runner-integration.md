# Bicep workflow runner integration

**Status**: in-progress
**Started**: 2026-10-02
**Updated**: 2026-10-02
**Branch**: `jaredfholgate-didactic-memory`

## Outcome

Connect the native deployment and cleanup lifecycle to the ordinary Bicep
commands, preserving existing registry scenarios rather than shipping the
restricted earlier runner. Continue through implementation and qualification
without stopping at intermediate slice boundaries. Ask for specific approval
before live Azure qualification, release or registry cutover.

Recovery means resuming cleanup from the saved local JSON file through a
normal CLI command. It does not mean publishing the file or creating a new
internet-facing service.

## Checklist

- [ ] Preserve authored parameter and token names, including keys and count.
- [ ] Match typed CI parameter precedence, secure values and location inputs.
- [ ] Match subscription selection, scope handling and regional validation.
- [ ] Record attempted deployment IDs before submission and retry only known
      failed or preflight-rejected submissions.
- [ ] Connect assertions, post hooks and native cleanup in their existing order.
- [ ] Retain cleanup state independently of temporary templates and parameters.
- [x] Add a deliberate cleanup-resume command with explicit target checks.
- [ ] Preserve authentication renewal between hosted workflow phases without
      exporting tokens or introducing automatic login.
- [ ] Exercise unmodified registry cases and failure paths without live Azure.
- [ ] Update command help, implementation contracts and the migration ledger.
- [ ] Run the full development gate, commit and push to the existing draft.

## Validation

The focused input controls pass: 42 unit and three component controls cover
typed CI values and precedence, dictionary-member collisions, generic
subscription pools, allowed-region selection and conservative error
classification. Base is the completed state/context slice `aaf1d15`.
All Azure operations in development controls are mocked.

The user explicitly selected same-process execution for post-deployment
Pester and post.ps1, matching the registry workflow. This retains
process-only Azure sign-ins without transferring credentials. Caller or
workflow cancellation replaces the earlier CLI's separate-process time
limits for that path; unit Pester execution remains isolated.

The [native execution input slice](2026-10-02-bicep-native-execution-inputs.md)
contains the helper and recovery-command implementation. Real same-process
Pester and script-restoration controls pass; native SDK parameter conversion
was exercised offline against installed Az.Resources 9.0.3. The ordinary
e2e engine is still unchanged until the lifecycle is wired end to end.

## Blockers or dependencies

No live Azure deployment, deletion, login, permission change, release or
registry workflow cutover is authorized. Those require a specific request
once source implementation is ready. Full live parity cannot be established
by mocked calls or local module metadata.
