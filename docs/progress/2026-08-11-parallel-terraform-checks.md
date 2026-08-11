# Parallel Terraform checks

Status: complete
Started: 2026-08-11
Completed: 2026-08-11
Branch: jaredfholgate-fix-check-failure-output

## Outcome

`avm lint` now initializes and checks independent Terraform scopes concurrently, while `avm check policy` runs each complete example lifecycle concurrently. Public commands expose a bounded `ThrottleLimit` with a default of four workers, results retain deterministic input order, and each distinct TFLint configuration is initialized once.

## Checklist

- [x] Add an ordered runspace-pool coordinator with error and stream propagation.
- [x] Parallelize Terraform initialization and lint execution by scope.
- [x] Initialize each distinct TFLint configuration once.
- [x] Parallelize each complete Terraform policy-example lifecycle.
- [x] Expose and forward `-ThrottleLimit` through public commands and `pr-check`.
- [x] Cover ordering, propagation, forwarding, and real worker overlap.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 pre-commit`
  - Unit: 890 passed, 7 skipped.
  - Component: 27 passed.
  - Build completed in 4 minutes 21 seconds.
- `git diff --check`

## Blockers or dependencies

- None.
