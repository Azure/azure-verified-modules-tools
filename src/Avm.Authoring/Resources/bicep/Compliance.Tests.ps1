#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

foreach ($suite in $Convention.SuiteFiles) {
    if ([System.IO.Path]::GetFileName($suite) -ceq 'Metadata.Tests.ps1') {
        . $suite -Validations $Convention.MetadataValidations -Convention $Convention
    }
    else {
        . $suite -Convention $Convention
    }
}
