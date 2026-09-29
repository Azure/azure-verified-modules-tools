# Bicep README authoring

**Status**: in-progress
**Started**: 2026-09-28
**Updated**: 2026-09-29
**Branch**: `jaredfholgate-interactive-metadata-initialization`

## Outcome

Render Bicep module documentation from the pinned Bicep CLI and an original,
versioned AVM Scriban template selected through the nearest repository-owned
`bicepconfig.json`. Generate or check root and child READMEs without replacing
authored Notes. Provide a separate, one-time command that extracts legacy
Notes into immutable, adjacent `README.notes.md` files. Preserve Terraform
documentation and metadata-only proposal behavior. Do not change the Bicep
registry or retire its existing generator and CI in this slice.

## Checklist

- [x] Pin an exact Bicep release with the sanctioned updater and review its
      documentation command and cross-platform release assets.
- [x] Package a versioned original template and require an equal, tracked
      repository copy referenced from the nearest Bicep configuration.
- [x] Add Bicep README generation, guarded transactional writes, and
      read-only drift checks; keep Notes sidecars as the sole authored input.
- [x] Add idempotent, fenced-heading-aware legacy Notes extraction that never
      overwrites a sidecar.
- [ ] Independently render all 574 source-backed READMEs without errors;
      compare raw bytes, allowing only the explicitly approved eight-line
      vault example-comment difference and, until their correction lands,
      four exact H1-only differences; preserve and hash-check the three
      source-less READMEs. Never use README text as a generator input.
- [x] Cover templates, root/child/scope examples, Notes/no-Notes, CLI errors,
      `-WhatIf`, drift, migration, and Terraform dispatch with focused tests.
- [x] Reject referenced test examples with unknown or missing required
      parameters against their actual target module without writing a README.
- [x] Update user-facing documentation and the implementation spec/plan.
- [x] Pass `./build.ps1 pre-commit` for the non-cutover renderer draft.
- [ ] Complete the full-registry comparison, mark this slice complete,
      and push any final parity corrections.

## Validation

`./build.ps1 pre-commit` passed after the post-`8b2dfe99` generic fixes:
layout, lint, 1,879 unit tests (nine skipped), and the component shards
passed with zero errors and 49 existing test warnings. Focused parser/alias,
reference-based example placeholder, and role tests passed. A pinned-CLI
integration test rendered two reassigned e2e examples in a scoped child and
confirmed all three code formats without writing a README; its expanded
fixture covers nested aliases, direct secure objects, sibling role inheritance,
inline and indented examples, recursive compiled defaults, and exact fence
boundaries. Other pinned-CLI fixtures cover multiline descriptions,
DevTestLab preview Learn fallbacks, numeric and string allowed values, and
root role lists. All nine resource-group example code blocks matched saved
published examples exactly.

The first independent full-registry comparison on frozen template snapshot
`80fdc68c` accounted for all 577 READMEs: 574 source-backed selections,
424 successful renders with zero byte matches, 150 render failures, 53 Notes
sidecars, and three unchanged source-less READMEs. Of the 150 failures, 137
were source-example inline-comment parsing, 12 were PowerShell `keys` property
collisions, and one is a genuine upstream Bicep compile failure. The two
helper issues were fixed; a subsequent eight-module comparison rendered all
eight formerly failing examples. On later frozen template snapshot `e22317e0`,
resource-group and management-group READMEs matched their published bytes
exactly. The next frozen comparison matched common-types, role-assignment
root, and all three role-assignment scopes byte-for-byte. Frozen snapshot
`daeea9cc` matched seven of eight representative role-assignment/key-vault
READMEs; the vault root differed by exactly eight inserted JSON-example
section-comment lines. The second independent full-registry comparison on
that snapshot accounted for all 577 READMEs: 574 selected, 380 raw-byte
matches, 180 mismatches, 14 render errors, and three unchanged source-less
files. The 14 new errors came from eagerly conflating unrelated nested role
maps that share a suffix. An uncommitted revision defers role matching to
documented parameters, preserves qualified identifiers, restores numeric
enum sorting and compiled resource traversal order, and fixes nested
pattern-module titles. Focused component/unit and pinned-CLI tests passed;
the full comparison has not yet been repeated. This is **not** full parity.
Frozen representative snapshot `054bc739` rendered all 24 selected modules
but matched none: two global newline additions had overcorrected the layout.
An eight-module role/vault check on that snapshot matched one README and
identified the same overcorrection. The subsequent `484edf52` template
restricts blank insertion to sibling details and nested sections, and
recognizes required synthetic dictionary keys. Its eight-module role/vault
check matched two READMEs with zero render errors; its 24-module comparison
matched three, with zero render errors, 17 whitespace-only mismatches and
four substantive mismatches. Root enum allowed values were missing in three
scope READMEs and one vault child, so the template now restores compiled
allowed values for root parameters. It also restores compiled description
trailing newlines omitted by the native model, and skips recursion into
undocumented synthetic properties. Frozen revision `592d2fdf` rendered all
32 representative modules with zero errors: seven of 24 and two of eight
matched bytes, and the only nonblank differences outside the approved vault
comments were in the two web/site roots. The next revision `c45e0664`
addresses the common missing blank before Outputs, resource-derived native
enum values without compiled allowed values, unique/ancestor role lookup,
and fenced, sorted object defaults. Focused unit tests, two real-CLI
integration tests, 21 component tests, and lint passed. Frozen `c45e0664`
rendered all 32 representatives without errors, but `defaultValueFence`
also applied to scalar defaults and regressed seven role/vault READMEs.
An in-memory diagnostic replacing only those scalar fences found 27 of 32
exact, the vault root with exactly its approved eight comments, and four
files with seven extra blank lines; this is not a fresh renderer result.
Revision `c3cc4b41` fences only multiline defaults and passes pinned-CLI
tests for scalar and sorted object defaults. Frozen `c6be8cc2` suppressed
seven extra deep-union/fenced-default sibling gaps, but its actual 32-file
comparison exposed an extra blank after inline scalar defaults and one
missing blank after a plain object's last visible child. After targeted
fixes, frozen `41d1f9f5` passed the independent 32-file representative
comparison: 24/24 exact in five module trees, 7/8 exact in role/Vault
modules, and the Vault root differs only by the strictly checked,
user-approved eight historical JSON comment lines. All 32 rendered, four
Notes sidecars were supplied, and no registry source was changed. Two
pinned-CLI integration tests pass with exact newline boundary assertions.
The complete comparison on this template accounted for all 577 READMEs:
574 source-backed files selected, 573 rendered, 433 exact byte matches,
one Vault root satisfying only the approved eight-comment exception,
139 unexpected byte mismatches, one genuine Bicep compile failure,
three source-less READMEs preserved, and 53 Notes sidecars. Of the
139 mismatches, 40 differ only in blank lines, three in other whitespace,
and 96 in content. They are being grouped by root cause before the next
renderer revision. This is **not** full parity, and no registry README has
been regenerated.

The next frozen focused comparison (`2d039d81` template) kept the earlier
32 controls unchanged: 31 byte-identical plus the exact Vault exception.
It rendered 74 additional READMEs: 61 exact and 13 mismatched, with 17
previously failing files now exact and no regression among prior matches.
The remaining focused differences identify nested compiled aliases, role-map
selection, source-authored category spellings, array spacing, and examples.
Subsequent generic fixes cover one-level array item aliases, dynamically
recognized one-word description categories, and spacing around fenced
defaults and Allowed blocks. Frozen focused snapshot `8c9bca24` rendered all
106 selected READMEs: 98 byte-exact, one strict Vault comment exception, one
separately approved H1-only correction, and six genuine mismatches, with
no previously exact file regressing. The six remaining focused files expose
compiled aliases nested under array items, sibling-dependent role-list
inheritance, secure-object children, recursive object defaults, source-backed
example indentation or inline examples, and one historically stale VM SKU
placeholder. Generic fixes for the first five patterns have targeted unit
and pinned-CLI integration coverage. The complete independent scan of older
snapshot `8c9bca24` accounted for all 577: 574 source-backed selections,
512 byte-exact, three source-less preserved, one strict Vault and four H1-only
approved differences, 56 genuine byte mismatches, and one genuine BCP426
compilation failure. Those 56 files are being classified by cause. A newer
frozen focused comparison on `8b2dfe99` rendered the same 106 files:
103 byte-exact, two unchanged strict exceptions, and only the VM root
with three stale Linux-max SKU placeholder lines; all five other formerly
mismatched files now match, with no previous byte-exact regressions. The
full-registry scan for this newer candidate remains pending. Focused
results do **not** prove full-registry parity.
The complete independent comparison on that same frozen `8b2dfe99` snapshot
subsequently accounted for all 577: 574 selected, 527 byte-exact,
three source-less preserved, one strict Vault and four H1-only approved
differences, 41 unexpected mismatches, and the same BCP426 render failure.
It made 17 previously mismatched files exact but **regressed two previously
byte-exact Machine Learning Services workspace READMEs** outside the
focused set, each losing roughly 20 KB of parameter content. Their
compiled secure objects are reached through references and contain
discriminator cases; only direct plain secure-object properties should
hide their children. The helper now distinguishes those paths. A
compiled-output fallback preserves `securestring` for nullable secure
outputs in the host-pool README, and fenced array-object defaults now
sort nested keys through the same recursive renderer as object defaults.
Unit tests, the pinned-CLI scoped fixture, Bicep docs components, and lint
pass. A new independent focused comparison includes both previously
regressed Machine Learning paths, host-pool, complex-array defaults, and
earlier exact controls. Frozen snapshot `26298f3b` selected 142
source-backed READMEs in 34 module trees: 141 rendered, 133 byte-exact,
the same strict Vault and storage-title exceptions, six unapproved
mismatches (the old VM SKU baseline and five unchanged whitespace-only
files), and one new render failure. Both Machine Learning regressions,
host-pool secure output, and the service-health complex-array defaults
are now byte-exact; no previously exact file regressed in this focused
set. The render failure exposed a legitimate object-shaped compiled
`metadata.example` for IaaS VM Cosmos DB `tags` that the current helper
incorrectly rejects. Its checked-in README contains the historical
PowerShell object type name rather than the object's contents. Resolve
that case before a full scan; this focused result does **not** establish
full-registry parity.

The user chose to render that object as a meaningful fenced Bicep example
and correct only its published README line, with no renderer or comparator
exception. Candidate `26f65a1d` now accepts object-shaped compiled examples
and sorts their properties in Scriban. It also captures parameter and
variant output to normalize trailing blank lines and avoids an extra blank
between a fenced default and its discriminator. A pinned-CLI fixture checks
the four-key object, nested array defaults, nullable secure output, and
these section/variant boundaries. Focused compiled-helper unit tests,
the pinned-CLI fixture, 23 docs/Notes component tests, and lint pass.
At that point the independent 142-file focused comparison and full gate
were pending.
Frozen `26f65a1d` then rendered all 142 focused files after its disposable
checkout received one missing, tracked shared source asset: 136 byte-exact,
two unchanged strict exceptions, the historical VM SKU and IaaS object
example differences, and one extra blank line each in managed-environment
and recovery-services vault. No prior exact control regressed. The generated
IaaS README has eight additional missing `Required. ` / `Optional. `
prefixes in nested descriptions: `category_description` had removed every
occurrence rather than only the first leading prefix. The user-approved
object-example-only README correction is in draft
[registry pull request 7410](https://github.com/Azure/bicep-registry-modules/pull/7410),
not the main baseline. The generic prefix fix has pinned-CLI coverage.
A separate fixture reproduced the remaining newline cause: a nullable,
default-free root discriminator with no direct properties produced three
line feeds before the next root heading; the renderer now suppresses the
redundant separator and the fixture checks for two. Frozen `3c64b27e`
rendered all 142 focused source-backed READMEs: 138 byte-exact against
the old main baseline, the two unchanged strict Vault/storage exceptions,
and only two deliberate old-baseline mismatches. The generated IaaS and
VM READMEs match the corresponding corrected documents in draft
[registry pull request 7410](https://github.com/Azure/bicep-registry-modules/pull/7410)
byte-for-byte, while their old-main baselines still fail. Both formerly
extra-blank-line READMEs now match, and none of the previous exact
controls regressed. `./build.ps1 pre-commit` passed on this candidate:
five tasks, zero errors, 1,879 unit tests passed (nine skipped), and
49 existing warnings. The non-cutover renderer was committed and pushed
as `eec697d`; the existing registry generator and CI remain active.

The independent full comparison of that same frozen renderer accounted
for all 577 READMEs: 574 source-backed selections, 573 rendered,
552 source-backed byte-exact, three source-less byte-exact, five strict
temporary approvals, 16 unexpected old-main byte mismatches, and one
upstream BCP426 render failure. It supplied 53 Notes sidecars and made
25 formerly failing paths exact compared with the prior full scan,
without regressing a previously exact or approved path. Nevertheless,
the already-failing CICD agents and runners README now loses two
previously rendered Allowed blocks, including `computeTypes`; this
within-file regression must be fixed rather than hidden by file totals.
The IaaS object example and VM SKU content remain old-main failures
but exactly match the corrected draft registry READMEs. Six other
unexpected differences require source/test history review: the
conversation-knowledge-mining usage tests pass names missing from their
module and omit its required `azureAiServiceLocation`, so their newly
rendered examples must not be published as valid. Three differences
concern allowed values or limits, four expose extra nested child
content, and one is a header blank line. Fix the generic renderer
differences and repeat the full comparison before claiming parity.

The next candidate retains array-item union constraints and
allowed object values from compiled aliases instead of discarding them,
uses compiled bounds on nested properties, quotes non-identifier keys
in Allowed blocks, and omits synthesized resource-derived children
without compiled fields and inline tuple-array children. These rules
cover the missing CICD, Redis, and metric-alert content, extra
security/cognitive/Mongo content, and the hybrid cluster's tuple child.
Focused compiled-helper unit tests, all three real pinned-CLI scoped
fixtures, 20 Bicep docs components, and lint pass. The independent
frozen25 focused comparison rendered all 159 selected READMEs across
42 module trees: 152 old-main byte-exact, two unchanged strict
historical approvals, and five old-main failures. Six requested
former mismatches (Redis, metric alert, security-center, two cognitive
services files, and Mongo) are now exact, as are eight additional child
READMEs. The previously lost CICD Allowed blocks are restored, and
none of the 138 previously exact controls regressed. The remaining
CICD difference is only a historically duplicated variant table.
Hybrid's unsupported tuple child is gone; its remaining differences
are three skipped-test notes and a connected-cluster cross-reference.
Dev Center still differs by one header blank line, while IaaS and VM
still match the corrected registry draft rather than old main. These
five old-main failures have not been approved as comparator exceptions.
The isolated Dev Center blank, CICD duplicate, and hybrid discrepancies
need separate source or documentation decisions. This focused result
is **not** a full 577-file gate; the latest full gate remains failed.
`./build.ps1 pre-commit` passed on this generic correction: five tasks,
zero errors, and 49 existing test warnings. Lint recovered from the
known transient analyzer-engine exception.
The user chose to fail a README that references an invalid test example,
rather than omit the example. The next candidate validates the test's
parameters against its actual target module, including ancestor targets
reassigned to child documentation; reports unknown and missing required
names; and prevents partial README writes. Compiled templates are reused
within a docs invocation instead of rebuilding an ancestor for each
child. Focused required-parameter unit tests (2/2), Bicep docs components
(22/22), real pinned-CLI scoped integration tests (3/3), and lint pass.
`./build.ps1 pre-commit` passed on this candidate: five tasks, zero
errors, and 49 existing warnings. Committed and pushed as `cc46f78`.
The independently frozen 190-file candidate rendered 159 of 160
focused old-main source-backed READMEs. All 159 generated files are
byte-identical to the preceding frozen candidate: 152 match old main,
two retain the same strict historical approvals, and five retain the
same old-main differences. The sole render failure is the invalid
conversation-knowledge-mining sandbox test: it supplies undeclared
`aiServiceLocation` and `usecase`, omits required
`azureAiServiceLocation`, and produces no README. The subsequent
full independent frozen candidate26 diagnostic accounted for all 577
paths on the unchanged old-main source and baseline: 574 source-backed
selected, 572 rendered, 558 old-main byte-exact, three source-less
byte-exact, five unchanged strict approvals, nine unapproved old-main
differences, and two render failures. All nine differences and the four
heading-approved paths match the 13 corrected README blobs in draft
[registry pull request 7410](https://github.com/Azure/bicep-registry-modules/pull/7410)
byte-for-byte. The only render failures are the known-invalid
conversation-knowledge-mining sandbox test and toolkit's BCP426
compilation error; no other invalid-test failures or regressions
among previously exact or approved paths were found. The old-main
gate remains **failed**: these draft bytes are not comparator
allowances, and neither upstream source correction is merged.
The separately approved Conversation test repair, including corrected
descriptions for both examples, is committed in draft
[registry pull request 7415](https://github.com/Azure/bicep-registry-modules/pull/7415)
at `3ee2feac0394095d2fca17814712f786710fd635`. An independent
single-module render using that immutable source and the same frozen
renderer produced the README without errors (66,774 bytes; SHA-256
`77F60279B4F21E709B5F14ACEBDDBA3FF405A247CC1EACF9FEB97683FA1028BA`).
Compared with old main, the only differences are two complete,
valid three-format usage examples (178 added lines) and removal of
one user-approved stale blank line after the introduction. This
bounded check does not replace a full scan on the eventual merged
source and README baseline; no registry README or baseline was changed
by this renderer slice.

## Blockers and dependencies

The registry comparison must confirm 574 independently rendered byte matches
plus three unchanged source-less documents, or report exact differences.
The checked-in vault Example 2+ JSON omits eight section comments that the
current legacy generator would add. The user approved reporting only this
specific historical difference as a documented comparison exception, not
altering the renderer or claiming the vault README is byte-identical. Every
other byte and module remains subject to the full regression gate. The
earlier 180-mismatch full scan included missing discriminated-union
variants, which the current Scriban template renders. The latest
frozen full comparison has nine unapproved old-main differences, all
matching the corresponding corrected README bytes in the unmerged
registry draft, plus the two expected source-backed render failures.
The prior missing CICD Allowed blocks and other structural mismatches
are resolved without regressing previously exact or approved paths.
Any updated registry source or baseline needs a fresh full comparison.
Two conversation-knowledge-mining e2e tests reference undeclared
parameter names and omit a required module parameter; the prior
native example reader formatted them without validating their parameters.
The current reader rejects the example with actionable names and
does not publish a README.
The user chose to stop rendering a README that references an invalid
test and report its unknown and missing required parameter names; the
user separately approved repairing those upstream tests in the registry.
The source repair is committed but unmerged on its own branch;
old-main comparison must report the invalid example until the
corrected tests and README are merged.
`avm/ptn/app/container-job-toolkit`
has a genuine
upstream Bicep BCP426 compile failure. Its source fix is in
[registry pull request 7407](https://github.com/Azure/bicep-registry-modules/pull/7407);
re-evaluate any affected README baseline after that change lands. The renderer
must not mask the failure. Four historical README titles disagree with existing
canonical module types; the user approved correcting just their first lines in
draft [registry pull request 7410](https://github.com/Azure/bicep-registry-modules/pull/7410).
Until it merges, check only those exact H1 replacements as explicit,
fail-closed comparison allowances; then deliberately re-pin the README
baseline and remove the allowances. The VM `linux.max` test's longstanding
literal SKU differs from the published README placeholder, and the legacy
converter does not contain a generic SKU rewrite. The user chose to publish
the source literal in all three example formats; draft
[registry pull request 7410](https://github.com/Azure/bicep-registry-modules/pull/7410)
changes exactly those README lines. The old baseline must continue to fail
without any renderer exception until that correction merges and the
independent gate is deliberately re-pinned. Do not bulk regenerate READMEs, replace
the existing generator or CI, or claim parity until the entire 577-file
gate is green under the narrowly approved exception.
