# AVM Authoring Quality Specification

This document defines the durable quality standards for the AVM authoring
tooling. It is a standard, not an implementation manual: source code, tests,
build configuration, workflows, and contributor documentation define the
current technical details. Historical decisions belong in issues and pull
requests.

## Quality priorities

Changes should be correct, safe, reliable, maintainable, and efficient. Keep
the solution as small as possible without weakening a required behavior or
boundary.

## Design and maintainability

- Prefer existing, well-understood tools and shared code over duplicate
  implementations.
- Share logic when behavior and safety requirements are the same. Keep distinct
  trust, platform, or user-facing boundaries explicit.
- Add abstractions, dependencies, configuration, and public options only when a
  demonstrated need justifies their ongoing cost.
- Keep classification and tuning values, including error codes, statuses,
  message patterns, retry limits, timings, and region lists, in versioned
  resource configuration with a schema rather than inline literals. Tests may
  use literals.
- Keep each function focused on one responsibility. Extract a helper to clarify
  or reuse behavior, not merely to shorten a function.
- Preserve compatibility for existing users. Make intentional public behavior
  changes explicit and version them according to the project's release policy.

## Correctness and reliability

- Validate inputs at trust boundaries before making changes or contacting
  external services.
- Report failures clearly and preserve useful error context. Do not hide
  failures, silently ignore invalid input, or return success-shaped fallbacks.
- Make repeated operations safe where practical. Do not retry a write unless
  its effects are known to be safe to repeat.
- Protect user data: stage and verify changes before replacing existing data,
  and preserve the original data when an operation fails.
- Keep check and preview modes free of persistent changes.
- Keep outputs and side effects deterministic when inputs are the same.

## Security

- Treat repository content, command arguments, configuration, network data, and
  generated files as untrusted until validated.
- Use least privilege. Ask for confirmation before consequential actions when
  the command's contract requires it.
- Never expose credentials or sensitive data in logs, errors, tests, fixtures,
  or telemetry.
- Do not turn user-controlled data into executable commands or code.
- Use the repository's shared process and networking mechanisms. Preserve
  argument boundaries, certificate validation, integrity checks, offline
  controls, and source restrictions.
- Changes that weaken a security control require security review and the
  approvals required by repository policy.

## Portability and filesystem safety

- Support the platforms and runtime versions declared by the module and its CI.
- Use platform-aware APIs for paths, temporary files, permissions, and process
  behavior. Do not assume path separators, filesystem casing, line endings, or
  shell conventions.
- Keep generated files in the correct encoding and line-ending format.
- Do not modify user files or shared process state unexpectedly. Scope temporary
  data to the operation and clean it up without masking the original failure.
- Test behavior on the supported operating systems when a change can depend on
  platform behavior.

## PowerShell and public interfaces

- Follow PowerShell conventions and the repository's analyzer configuration.
- Use approved verbs and the `Avm` noun prefix for exported functions. Give
  every public function complete, accurate comment-based help.
- Use clear parameter and output types. State-changing commands must support
  the repository's confirmation and preview conventions.
- Keep error behavior explicit and consistent. Handle only errors that can be
  recovered from safely; otherwise preserve and report them.
- Do not expose internal implementation details as public options or output
  unless users need and can rely on them.

## Performance and concurrency

- Measure a real bottleneck before optimizing. Prefer removing repeated work
  over adding complexity.
- Keep common commands and tests responsive. Avoid repeating expensive setup
  when a safe shared fixture or cached result serves the same purpose.
- Make ownership of mutable state explicit. Protect state shared across
  processes, and avoid hidden global state that makes concurrent operations
  interfere.
- Preserve cancellation and timeout behavior for long-running work.

## Testing and validation

- Tests should protect distinct user-visible behavior, important boundaries,
  or failure cases. Remove tests that duplicate stronger coverage without
  adding a separate guarantee.
- Test behavior at the lowest layer that proves the contract. Use unit tests for
  isolated logic, component tests for real local filesystem and process
  behavior, and gated integration or qualification tests for external or native
  behavior.
- Mock external systems in local test tiers. Never allow a test to make an
  unintended production change.
- Include meaningful boundary and failure cases. Prefer a small set of
  representative cases over repeated full setups that assert the same rule.
- Keep tests isolated, deterministic, and non-writing outside their temporary
  fixtures. A skipped required check is not a pass.
- Measure slow tests. Improve test value and remove redundant work before
  splitting suites solely to distribute runtime.
- Run the repository's required validation before proposing a change. Report
  checks that were not run or were skipped.

## CI, releases, and documentation

- CI should validate the relevant code, tests, generated files, and supported
  platforms. Workflow permissions and credentials must be limited to the work
  each job needs.
- Build and publish reproducible artifacts from reviewed source. Verify
  dependencies and release artifacts using the repository's supply-chain
  controls.
- Document public behavior and meaningful compatibility changes. Keep
  generated documentation synchronized with its source.
- Keep this document focused on standards. Put operational instructions in
  contributor documentation and enforceable technical contracts in code,
  tests, or configuration.
