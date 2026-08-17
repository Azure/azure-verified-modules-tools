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

`bicepdocsconfig.json` is passed to every docs invocation. Its example
reassignments move multi-scope tests from parent stubs to the corresponding
`mg-scope`, `rg-scope`, and `sub-scope` modules while leaving ordinary modules
unchanged. The semantic index also flattens structured discriminator cases to
the parameter paths used by existing AVM READMEs.
