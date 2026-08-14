# AVM documentation parity

`Test-AvmDocsParity.ps1` verifies a candidate Bicep documentation template
against checked-out AVM module READMEs. It compares generated README bytes and
the semantic parameter paths and e2e example names exposed by the Bicep docs
model.

```pwsh
./scripts/avm-docs/Test-AvmDocsParity.ps1 `
    -BicepPath <path-to-bicep> `
    -AvmRepositoryPath <path-to-bicep-registry-modules>
```

The default modules are `avm/res/storage/storage-account` and
`avm/res/network/virtual-network`. Validation used
`Azure/bicep-registry-modules` commit
`55c62d45eaf6675c09bf663616c3e7fdd8c4560f`.
