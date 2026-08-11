# Ring 1 rollout of the hardened issue-triage workflow

Status: complete
Started: 2026-08-11
Completed: 2026-08-11
Branch: myaschmitz-fuzzy-doodle

## Outcome

The hardened agentic issue-triage pair sits in the `canary-tooling` overlay, so
it reaches `avm-ptn-example-repo` alone while the other nine canary repositories
and the rest of the fleet stay on the `root` version. First real use of the ring
ladder from `2026-08-11-staged-managed-file-rollout-rings.md`.

Content is byte-identical to `Azure/terraform-azurerm-avm-ptn-example-repo`
PR #191, which restored the validated pair from governance PR #527 at
`bc4bd547fad812429b22b419b4fe437c9ffcbc12`.

| File | SHA-256 |
| ---- | ------- |
| `issue-triage.md` | `5303b47df92f6ff587e7e244abdce024a08179099e204a4ba41612d6ad05ab56` |
| `issue-triage.lock.yml` | `4116deaa27696314d0d3ae7ad8395fff938e47cd519836fad77d2e0bd11b253a` |

## Checklist

- [x] Place both files under the `canary-tooling` overlay.
- [x] Verify the lock file is genuinely compiled from its markdown.
- [x] Validate the compiled shell and jq programs.
- [x] Validate the lock file as GitHub Actions YAML.
- [x] Confirm the model pin carries no mutable fallback.
- [x] Verify encoding, line endings, and trailing newline.

## Validation

`.lock.yml` is generated, so the risks are drift from its markdown and syntax
errors that only surface at runtime inside Actions.

- Lock/markdown sync — reproduced the recorded `body_hash` as
  `sha256(markdown body, trimmed)` =
  `a5686f659ef2c95967e5b617b4d2e6e1c8647e66243d790927e4c0486429e06c`. Genuine
  compile, not a hand-assembled hybrid.
- Shell — all 25 compiled `run:` blocks parse with `bash -n`, including the
  447-line prefetch step.
- jq — all 21 jq programs compile with their variable bindings supplied.
- YAML — parses into six jobs; the `agent` job is read-only, and only
  `safe_outputs` and `conclusion` hold write.
- Model pin — `claude-sonnet-5` at all four injection points plus lock metadata,
  with no `GH_AW_DEFAULT_MODEL_*` indirection remaining.
- Encoding — UTF-8, no BOM, LF only, trailing newline.

## Blockers or dependencies

- `Azure/azure-verified-modules-tools` PR #52 carries the same content in
  `root/`, which would ship it fleet-wide and bypass this ring. Superseded by
  this slice; retained as the record of the port from the governance repo.
