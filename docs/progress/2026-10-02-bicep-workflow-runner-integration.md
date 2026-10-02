# Bicep workflow runner integration

**Status**: complete
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

- [x] Preserve authored parameter and token names, including keys and count.
- [x] Match typed CI parameter precedence, secure values and location inputs.
- [x] Match subscription selection, scope handling and regional validation.
- [x] Record attempted deployment IDs before submission and retry only known
      failed or preflight-rejected submissions.
- [x] Connect assertions, post hooks and native cleanup in their existing order.
- [x] Retain cleanup state independently of temporary templates and parameters.
- [x] Add a deliberate cleanup-resume command with explicit target checks.
- [x] Preserve authentication renewal between hosted workflow phases without
      exporting tokens or introducing automatic login.
- [x] Exercise unmodified registry cases and failure paths without live Azure.
- [x] Update command help, implementation contracts and the migration ledger.
- [x] Run the full development gate, commit and push to the existing draft.

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
was exercised offline against installed Az.Resources 9.0.3. That foundation
was committed and pushed at `a1cef96`.

The ordinary e2e engine is now wired locally to native execution, typed
inputs, subscription selection, retained state, hosted Deploy/Complete
phases, assertions, post hooks and ordinary cleanup. Focused mocked-Azure
controls exercise all four
scopes, hosted sign-in renewal, failed submissions and cleanup recovery.
They exposed and corrected empty-array result unrolling during completion.
The old public-runner fixtures have been replaced with native controls,
including the complete pinned route-table and management-group templates;
the templates' locks and role assignments remain intact.

Offline qualification now compiles unmodified registry sources at
`89b1910d5d11e4f87579ae98e119effe9b7c9578` with Bicep 0.47.16 and
`--no-restore`, using only the existing published-module cache. Six
simulated-Azure scenarios cover route-table subscription-to-group deployment,
management-group role definitions, management-group `init`/`idem` deployment,
tenant service groups, and the PostgreSQL configurations suite with both
passing and deliberately failing responses. The authored PostgreSQL file
runs both its real Pester cases: two passes for correct responses, then one
pass and one failure for the negative control. Cleanup completes in either
case. All 5,611 snapshot source files remain byte-identical.

The registry archive SHA-256 is
`1CDD03E038D09E4BB8A2D07079C9BFA606A121BDFDB9F01FDDFC02289F7AC05D`;
the pinned Windows x64 compiler SHA-256 is
`3F343AB1CE41FEAC156464ADEE3DC499CB6C197366FC731AED276192011D867C`.
The retained session qualification report distinguishes real compilation and
authored assertions from simulated Azure operations. No unmodified
child-local e2e cases exist in this snapshot; child discovery remains covered
by local fixtures, not claimed as registry-source execution.

Qualification exposed two concrete compatibility bugs. Recursive token
replacement now recognizes actual custom objects rather than mistaking
JSON-decorated numbers and booleans for objects. Pester output envelopes now
support SDK-style `Type`/`Value` access while preserving authored nested keys
and arrays; the real PostgreSQL discovery previously failed on `.Value`.
Six focused scalar/container unit controls, two real-Pester component
controls covering both execution modes, and twelve native retry/identity
controls pass. The native response must identify the exact recorded attempt
before success or a confirmed-failure retry is accepted.

The ordinary `.\build.ps1 pre-commit` gate passed: layout, lint with no
findings, 2,750 unit tests with nine skips, and 1,257 component tests with
one skip. Expected negative-fixture warnings remain visible; no analyzer
rule, retry policy or assertion was suppressed. Callback inputs are captured
explicitly for analyzer-visible data flow. Final registry qualification was
repeated against these exact source bytes after the gate. The local-only
qualification wrapper was removed from repository discovery; its driver,
source-file hashes, staged templates and report remain session artifacts.

## Blockers or dependencies

No live Azure deployment, deletion, login, permission change, release or
registry workflow cutover is authorized. Those require a specific request
once source implementation is ready. Full live parity cannot be established
by mocked calls or local module metadata.
