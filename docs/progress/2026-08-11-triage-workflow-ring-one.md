# Ring 1 rollout of the hardened issue-triage workflow

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `myaschmitz-fuzzy-doodle`

## Outcome

Place the hardened agentic issue-triage workflow pair into the `canary-tooling`
overlay so it reaches `avm-ptn-example-repo` alone, leaving the other nine canary
repositories and the remaining fleet on the `root` version until the change is
validated in a live repository.

This is the first real use of the ring ladder wired in
`2026-08-11-staged-managed-file-rollout-rings.md`.

## Source

The pair was taken from `Azure/terraform-azurerm-avm-ptn-example-repo` PR #191,
which itself restored the validated pair from governance PR #527 at commit
`bc4bd547fad812429b22b419b4fe437c9ffcbc12`. `Azure/azure-verified-modules-tools`
PR #52 carries byte-identical content, but targets `root/` rather than a ring.

| File | SHA-256 |
| ---- | ------- |
| `issue-triage.md` | `5303b47df92f6ff587e7e244abdce024a08179099e204a4ba41612d6ad05ab56` |
| `issue-triage.lock.yml` | `4116deaa27696314d0d3ae7ad8395fff938e47cd519836fad77d2e0bd11b253a` |

Both hashes match the values stated in PR #191 and the files downloaded from
PR #52, so all three sources agree.

## Checklist

- [x] Confirm PR #191 and PR #52 carry identical bytes.
- [x] Place both files under the `canary-tooling` overlay.
- [x] Verify encoding, line endings, and trailing newline.
- [x] Verify the lock file is genuinely compiled from this markdown.
- [x] Validate the compiled shell and jq programs.
- [x] Validate the lock file as GitHub Actions YAML.
- [x] Confirm the model pin carries no mutable fallback.

## Validation

The lock file is generated, so the risk is that it drifts from its markdown or
carries a syntax error that only appears at runtime inside Actions. Each check
below targets one of those failure modes.

- **Lock/markdown sync** — independently recomputed the compiler's recorded
  `body_hash` as `sha256(markdown body, trimmed)` and reproduced
  `a5686f659ef2c95967e5b617b4d2e6e1c8647e66243d790927e4c0486429e06c` exactly.
  The pair is genuinely compiled from this markdown, not a hand-assembled hybrid.
- **Shell syntax** — extracted all 25 `run:` blocks and parsed each with
  `bash -n`; all pass, including the 447-line prefetch step and its heredoc.
- **jq syntax** — extracted and compiled all 21 jq programs with their variable
  bindings supplied; all compile, including the 108-line screening-index
  generator and the 38-line status contract.
- **Workflow YAML** — parses cleanly into six jobs (`activation`, `agent`,
  `detection`, `safe_outputs`, `update_cache_memory`, `conclusion`). The agent
  job holds read-only `issues` and `pull-requests`; only `safe_outputs` and
  `conclusion` hold write, so the model cannot write directly.
- **Model pin** — `claude-sonnet-5` at all four runtime injection points
  (`GH_AW_INFO_MODEL`, both `COPILOT_MODEL`, `GH_AW_ENGINE_MODEL`) plus the lock
  metadata `agent_model`. No `GH_AW_DEFAULT_MODEL_*` or `GH_AW_MODEL_*_COPILOT`
  indirection remains, so the workflow cannot silently inherit a different model.
- **Encoding** — UTF-8, no BOM, LF only, trailing newline present on both files.

## Blockers or dependencies

`Azure/azure-verified-modules-tools` PR #52 places the same content in `root/`.
Merging it would ship the change to the whole fleet immediately and defeat the
purpose of this ring, so the two are mutually exclusive for this change. PR #52
should be closed or retargeted before or alongside this work.
