# AVM documentation parity

`Test-AvmDocsParity.ps1` verifies a candidate Bicep documentation template
against checked-out AVM module READMEs. It compares generated README bytes and
semantic parameter paths and e2e example names exposed by the Bicep docs model.

```pwsh
./scripts/avm-docs/Test-AvmDocsParity.ps1 `
    -BicepPath <path-to-bicep> `
    -AvmRepositoryPath <path-to-bicep-registry-modules>
```

The default modules are `avm/res/storage/storage-account` and
`avm/res/network/virtual-network`. Validation used
`Azure/bicep-registry-modules` commit
`55c62d45eaf6675c09bf663616c3e7fdd8c4560f`.

`Invoke-AllAvmDocsParity.ps1` runs the byte-parity template across all eligible
modules in separate source and working checkouts. It records compiler failures
and semantic-model mismatches in its output reports; failed compilation does
not produce a README.

`bicepconfig.json` is copied to the root of the validation working checkout so
the Bicep CLI discovers its `documentation` settings for each source file. Its
example reassignments move multi-scope tests from parent stubs to the
corresponding `mg-scope`, `rg-scope`, and `sub-scope` modules while leaving
ordinary modules unchanged. The scripts use `bicep docs generate`; output-mode
calls add `--stdout`. The semantic index also flattens structured discriminator
cases and records exported type and variable names.
