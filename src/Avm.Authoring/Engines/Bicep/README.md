# Bicep engine

`avm init` scaffolds a local module; `-Proposed` creates only metadata. The
repeatable Bicep chain formats, lints, validates, compiles `main.bicep` into
`main.json`, and renders documentation without deploying or publishing.

`avm docs` uses the pinned Bicep CLI and a versioned Scriban template selected
by the nearest `bicepconfig.json` through `documentation.template.file`. The
path must be relative to that config and point to an exact copy of the
packaged template in `Resources/bicep/`. Source files and compiled JSON
supply generated content; authored Notes live in an adjacent
`README.notes.md` body-only sidecar. Run `avm docs export-notes` once to
extract existing Notes without overwriting an existing sidecar. Use
`avm docs -CheckDrift` to compare without writes; `-IncludeRenderedContent`
returns generated text only in drift mode.

The registry's existing generator and CI remain authoritative until the
independent full-registry byte comparison matches every source-backed README
apart from the eight separately reported Key Vault JSON-example comments,
and verifies the source-less READMEs separately. Do not bulk regenerate or
replace the registry's generator based on component tests alone.
