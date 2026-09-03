function Get-AvmTerraformBlockText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter(Mandatory)]
        [int] $OpenBraceIndex
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $depth = 0
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false

    for ($index = $OpenBraceIndex; $index -lt $Content.Length; $index++) {
        $current = $Content[$index]
        $next = if (($index + 1) -lt $Content.Length) { $Content[$index + 1] } else { [char]0 }

        if ($lineComment) {
            if ($current -eq "`n") {
                $lineComment = $false
            }
            continue
        }
        if ($blockComment) {
            if ($current -eq '*' -and $next -eq '/') {
                $blockComment = $false
                $index++
            }
            continue
        }
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            }
            elseif ($current -eq '\') {
                $escaped = $true
            }
            elseif ($current -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($current -eq '#') {
            $lineComment = $true
            continue
        }
        if ($current -eq '/' -and $next -eq '/') {
            $lineComment = $true
            $index++
            continue
        }
        if ($current -eq '/' -and $next -eq '*') {
            $blockComment = $true
            $index++
            continue
        }
        if ($current -eq '"') {
            $inString = $true
            continue
        }
        if ($current -eq '{') {
            $depth++
            continue
        }
        if ($current -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Content.Substring($OpenBraceIndex + 1, $index - $OpenBraceIndex - 1)
            }
        }
    }

    throw [AvmConfigurationException]::new(
        'Could not parse a Terraform block while generating the credential-free policy test.')
}

function Find-AvmTerraformBlockOpenBrace {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter(Mandatory)]
        [string] $Name
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false

    for ($index = 0; $index -lt $Content.Length; $index++) {
        $current = $Content[$index]
        $next = if (($index + 1) -lt $Content.Length) { $Content[$index + 1] } else { [char]0 }

        if ($lineComment) {
            if ($current -eq "`n") { $lineComment = $false }
            continue
        }
        if ($blockComment) {
            if ($current -eq '*' -and $next -eq '/') {
                $blockComment = $false
                $index++
            }
            continue
        }
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($current -eq '\') { $escaped = $true }
            elseif ($current -eq '"') { $inString = $false }
            continue
        }

        if ($current -eq '#') {
            $lineComment = $true
            continue
        }
        if ($current -eq '/' -and $next -eq '/') {
            $lineComment = $true
            $index++
            continue
        }
        if ($current -eq '/' -and $next -eq '*') {
            $blockComment = $true
            $index++
            continue
        }
        if ($current -eq '"') {
            $inString = $true
            continue
        }
        if (($index + $Name.Length) -gt $Content.Length -or
            $Content.Substring($index, $Name.Length) -cne $Name) {
            continue
        }

        $before = if ($index -gt 0) { $Content[$index - 1] } else { [char]0 }
        $afterIndex = $index + $Name.Length
        $after = if ($afterIndex -lt $Content.Length) { $Content[$afterIndex] } else { [char]0 }
        if ($before -match '[A-Za-z0-9_-]' -or $after -match '[A-Za-z0-9_-]') {
            continue
        }
        while ($afterIndex -lt $Content.Length -and [char]::IsWhiteSpace($Content[$afterIndex])) {
            $afterIndex++
        }
        if ($afterIndex -lt $Content.Length -and $Content[$afterIndex] -eq '{') {
            return $afterIndex
        }
    }

    return -1
}

function Read-AvmTerraformHclDocument {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string] $ConftestPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $files = @(Get-ChildItem -LiteralPath $WorkingDirectory -File -Filter '*.tf' -ErrorAction Stop |
            Sort-Object FullName)
    if ($files.Count -eq 0) {
        return @()
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('parse')
    $arguments.Add('--parser')
    $arguments.Add('hcl2')
    $arguments.Add('--combine')
    foreach ($file in $files) {
        $arguments.Add($file.FullName)
    }

    $result = Invoke-AvmProcess `
        -FilePath $ConftestPath `
        -ArgumentList $arguments.ToArray() `
        -WorkingDirectory $WorkingDirectory `
        -Label 'conftest parse terraform configuration'

    try {
        return @($result.StdOut | ConvertFrom-Json -Depth 100 -ErrorAction Stop)
    }
    catch {
        throw [AvmProcessException]::new(
            "Could not parse conftest HCL JSON output: $($_.Exception.Message)")
    }
}

function Get-AvmTerraformLocalModuleDirectory {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string] $ConftestPath,

        [ValidateRange(0, 32)]
        [int] $Depth = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $directories = [System.Collections.Generic.List[string]]::new()
    $directories.Add((Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).ProviderPath)
    foreach ($document in @(Read-AvmTerraformHclDocument `
            -WorkingDirectory $WorkingDirectory `
            -ConftestPath $ConftestPath)) {
        if (-not $document.PSObject.Properties['contents']) { continue }
        $moduleProperty = $document.contents.PSObject.Properties['module']
        if ($null -eq $moduleProperty -or $null -eq $moduleProperty.Value) { continue }
        foreach ($moduleEntry in $moduleProperty.Value.PSObject.Properties) {
            $instances = @($moduleEntry.Value)
            if ($instances.Count -eq 0 -or -not $instances[0].PSObject.Properties['source']) { continue }
            $source = [string]$instances[0].source
            if (-not $source.StartsWith('.')) { continue }
            $modulePath = [System.IO.Path]::GetFullPath((Join-Path $WorkingDirectory $source))
            if (-not (Test-Path -LiteralPath $modulePath -PathType Container)) { continue }
            foreach ($directory in @(Get-AvmTerraformLocalModuleDirectory `
                    -WorkingDirectory $modulePath `
                    -ConftestPath $ConftestPath `
                    -Depth ($Depth + 1))) {
                if (-not $directories.Contains($directory)) {
                    $directories.Add($directory)
                }
            }
        }
    }
    return $directories.ToArray()
}

function Get-AvmTerraformMockProvider {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string[]] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string] $ConftestPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $providers = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::Ordinal)
    $addProvider = {
        param(
            [string] $Name,
            [string] $Source,
            [bool] $ExplicitSource,
            [bool] $Declared,
            [string] $Alias
        )

        if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
            throw [AvmConfigurationException]::new(
                "Terraform provider local name '$Name' cannot be represented in the generated policy test.")
        }
        if (-not $providers.ContainsKey($Name)) {
            $providers[$Name] = [pscustomobject]@{
                Source         = $Source
                ExplicitSource = $ExplicitSource
                Declared       = $Declared
                Aliases        = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::Ordinal)
            }
        }
        elseif ($providers[$Name].Source -cne $Source) {
            if ($providers[$Name].ExplicitSource -and $ExplicitSource) {
                throw [AvmConfigurationException]::new(
                    "Terraform provider local name '$Name' resolves to both '$($providers[$Name].Source)' and '$Source'.")
            }
            if ($ExplicitSource) {
                $providers[$Name].Source = $Source
                $providers[$Name].ExplicitSource = $true
            }
        }
        elseif ($ExplicitSource) {
            $providers[$Name].ExplicitSource = $true
        }
        if ($Declared) {
            $providers[$Name].Declared = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($Alias)) {
            if ($Alias -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') {
                throw [AvmConfigurationException]::new(
                    "Terraform provider alias '$Alias' cannot be represented in the generated policy test.")
            }
            $null = $providers[$Name].Aliases.Add($Alias)
        }
    }

    foreach ($directory in $WorkingDirectory) {
        foreach ($document in @(Read-AvmTerraformHclDocument `
                -WorkingDirectory $directory `
                -ConftestPath $ConftestPath)) {
            if (-not $document.PSObject.Properties['contents']) { continue }
            $terraformProperty = $document.contents.PSObject.Properties['terraform']
            foreach ($terraformBlock in $(if ($null -ne $terraformProperty) { @($terraformProperty.Value) } else { @() })) {
                $requiredProperty = $terraformBlock.PSObject.Properties['required_providers']
                foreach ($requiredProviders in $(if ($null -ne $requiredProperty) { @($requiredProperty.Value) } else { @() })) {
                    foreach ($providerProperty in $requiredProviders.PSObject.Properties) {
                        $source = if ($providerProperty.Value.PSObject.Properties['source']) {
                            [string]$providerProperty.Value.source
                        }
                        else {
                            'hashicorp/{0}' -f $providerProperty.Name
                        }
                        & $addProvider `
                            $providerProperty.Name `
                            $source `
                            ($providerProperty.Value.PSObject.Properties['source'] -ne $null) `
                            $true `
                            ''
                    }
                }
            }
            $providerBlocks = $document.contents.PSObject.Properties['provider']
            if ($null -ne $providerBlocks -and $null -ne $providerBlocks.Value) {
                foreach ($providerProperty in $providerBlocks.Value.PSObject.Properties) {
                    foreach ($instance in @($providerProperty.Value)) {
                        $source = if ($providers.ContainsKey($providerProperty.Name)) {
                            $providers[$providerProperty.Name].Source
                        }
                        else {
                            'hashicorp/{0}' -f $providerProperty.Name
                        }
                        $alias = if ($instance.PSObject.Properties['alias']) { [string]$instance.alias } else { '' }
                        & $addProvider $providerProperty.Name $source $false $false $alias
                    }
                }
            }
            foreach ($modeName in @('resource', 'data')) {
                $modeProperty = $document.contents.PSObject.Properties[$modeName]
                if ($null -eq $modeProperty -or $null -eq $modeProperty.Value) { continue }
                foreach ($typeProperty in $modeProperty.Value.PSObject.Properties) {
                    $separator = $typeProperty.Name.IndexOf('_')
                    if ($separator -le 0) { continue }
                    $providerName = $typeProperty.Name.Substring(0, $separator)
                    if ($providerName -eq 'terraform') { continue }
                    $source = if ($providers.ContainsKey($providerName)) {
                        $providers[$providerName].Source
                    }
                    else {
                        'hashicorp/{0}' -f $providerName
                    }
                    & $addProvider $providerName $source $false $false ''
                }
            }
        }
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($providers.Keys | Sort-Object)) {
        $result.Add([pscustomobject]@{
                Name           = $name
                Source         = $providers[$name].Source
                ExplicitSource = $providers[$name].ExplicitSource
                Declared       = $providers[$name].Declared
                Alias          = ''
            })
        foreach ($alias in @($providers[$name].Aliases | Sort-Object)) {
            $result.Add([pscustomobject]@{
                    Name           = $name
                    Source         = $providers[$name].Source
                    ExplicitSource = $providers[$name].ExplicitSource
                    Declared       = $providers[$name].Declared
                    Alias          = $alias
                })
        }
    }
    return $result.ToArray()
}

function New-AvmTerraformPolicyTest {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string] $ModuleRoot,

        [Parameter(Mandatory)]
        [string] $ConftestPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $moduleDirectories = @(Get-AvmTerraformLocalModuleDirectory `
            -WorkingDirectory $ModuleRoot `
            -ConftestPath $ConftestPath)
    $exampleDirectories = @(Get-AvmTerraformLocalModuleDirectory `
            -WorkingDirectory $WorkingDirectory `
            -ConftestPath $ConftestPath)
    $moduleProviders = @(Get-AvmTerraformMockProvider `
            -WorkingDirectory $moduleDirectories `
            -ConftestPath $ConftestPath)
    $exampleProviders = @(Get-AvmTerraformMockProvider `
            -WorkingDirectory $WorkingDirectory `
            -ConftestPath $ConftestPath)
    $exampleByName = @{}
    foreach ($provider in $exampleProviders | Where-Object { [string]::IsNullOrWhiteSpace($_.Alias) }) {
        $exampleByName[$provider.Name] = $provider
    }

    $missingProviders = [System.Collections.Generic.List[object]]::new()
    foreach ($provider in $moduleProviders | Where-Object { [string]::IsNullOrWhiteSpace($_.Alias) }) {
        if (-not $exampleByName.ContainsKey($provider.Name)) {
            $missingProviders.Add($provider)
            continue
        }
        $exampleProvider = $exampleByName[$provider.Name]
        if ($exampleProvider.Source -cne $provider.Source) {
            if ($exampleProvider.Declared) {
                throw [AvmConfigurationException]::new(
                    "Terraform provider local name '$($provider.Name)' resolves to both '$($exampleProvider.Source)' and '$($provider.Source)'.")
            }
            $missingProviders.Add($provider)
        }
    }

    if ($missingProviders.Count -gt 0) {
        $requiredFile = $null
        $requiredContent = ''
        $requiredOpenBrace = -1
        foreach ($file in @(Get-ChildItem -LiteralPath $WorkingDirectory -File -Filter '*.tf' -ErrorAction Stop)) {
            $content = [System.IO.File]::ReadAllText($file.FullName)
            $openBrace = Find-AvmTerraformBlockOpenBrace `
                -Content $content `
                -Name 'required_providers'
            if ($openBrace -ge 0) {
                $requiredFile = $file.FullName
                $requiredContent = $content
                $requiredOpenBrace = $openBrace
                break
            }
        }

        $providerLines = [System.Collections.Generic.List[string]]::new()
        foreach ($provider in $missingProviders) {
            $providerLines.Add(('    {0} = {{' -f $provider.Name))
            $providerLines.Add(('      source = "{0}"' -f $provider.Source))
            $providerLines.Add('    }')
        }

        if ($null -ne $requiredFile) {
            $block = Get-AvmTerraformBlockText `
                -Content $requiredContent `
                -OpenBraceIndex $requiredOpenBrace
            $closeBrace = $requiredOpenBrace + $block.Length + 1
            $insertion = "`n" + ($providerLines -join "`n") + "`n  "
            $updated = $requiredContent.Insert($closeBrace, $insertion)
            [System.IO.File]::WriteAllText(
                $requiredFile,
                $updated,
                [System.Text.UTF8Encoding]::new($false))
        }
        else {
            $terraformLines = [System.Collections.Generic.List[string]]::new()
            $terraformLines.Add('terraform {')
            $terraformLines.Add('  required_providers {')
            foreach ($line in $providerLines) {
                $terraformLines.Add($line)
            }
            $terraformLines.Add('  }')
            $terraformLines.Add('}')
            [System.IO.File]::WriteAllText(
                (Join-Path $WorkingDirectory 'avm-policy-providers.tf'),
                ($terraformLines -join "`n") + "`n",
                [System.Text.UTF8Encoding]::new($false))
        }
    }

    $providers = @(Get-AvmTerraformMockProvider `
            -WorkingDirectory @($moduleDirectories + $exampleDirectories | Select-Object -Unique) `
            -ConftestPath $ConftestPath)
    $testDirectoryName = '.avm-policy-tests-' + [guid]::NewGuid().ToString('N')
    $testDirectoryPath = Join-Path $WorkingDirectory $testDirectoryName
    $null = New-Item -ItemType Directory -Path $testDirectoryPath -Force -ErrorAction Stop

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($provider in $providers) {
        $lines.Add(('mock_provider "{0}" {{' -f $provider.Name))
        if (-not [string]::IsNullOrWhiteSpace($provider.Alias)) {
            $lines.Add(('  alias = "{0}"' -f $provider.Alias))
        }
        $lines.Add('  override_during = plan')
        $lines.Add('}')
        $lines.Add('')
    }

    $lines.Add('run "avm_policy_plan" {')
    $lines.Add('  command = plan')
    $lines.Add('}')

    $testPath = Join-Path $testDirectoryPath 'avm-policy.tftest.hcl'
    [System.IO.File]::WriteAllText(
        $testPath,
        ($lines -join "`n") + "`n",
        [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        WorkingDirectory = $WorkingDirectory
        DirectoryName    = $testDirectoryName
        DirectoryPath    = $testDirectoryPath
        TestPath      = $testPath
        Providers     = $providers
    }
}

function ConvertFrom-AvmTerraformTestPlan {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Output
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $plans = [System.Collections.Generic.List[object]]::new()
    $terraformVersion = ''
    foreach ($line in @($Output -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        }
        catch {
            continue
        }
        if ($event.type -eq 'version' -and $event.PSObject.Properties['terraform']) {
            $terraformVersion = [string]$event.terraform
        }
        if ($event.type -eq 'test_plan' -and $event.PSObject.Properties['test_plan']) {
            $plans.Add($event.test_plan)
        }
    }

    if ($plans.Count -ne 1) {
        throw [AvmProcessException]::new(
            "terraform test returned $($plans.Count) plan events; exactly one was expected.")
    }

    $plan = $plans[0]
    if (-not $plan.PSObject.Properties['format_version'] -and
        $plan.PSObject.Properties['plan_format_version']) {
        $plan | Add-Member -NotePropertyName 'format_version' -NotePropertyValue $plan.plan_format_version
    }
    if (-not $plan.PSObject.Properties['terraform_version'] -and
        -not [string]::IsNullOrWhiteSpace($terraformVersion)) {
        $plan | Add-Member -NotePropertyName 'terraform_version' -NotePropertyValue $terraformVersion
    }

    return ($plan | ConvertTo-Json -Depth 100 -Compress)
}

function Get-AvmTerraformPolicyConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string] $ConftestPath
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    return [pscustomobject]@{
        root_module = Get-AvmTerraformPolicyModuleConfiguration `
            -WorkingDirectory $WorkingDirectory `
            -ConftestPath $ConftestPath
    }
}

function Get-AvmTerraformPolicyModuleConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkingDirectory,

        [Parameter(Mandatory)]
        [string] $ConftestPath,

        [ValidateRange(0, 32)]
        [int] $Depth = 0
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $documents = @(Read-AvmTerraformHclDocument `
            -WorkingDirectory $WorkingDirectory `
            -ConftestPath $ConftestPath)

    $resources = [System.Collections.Generic.List[object]]::new()
    $moduleCalls = [ordered]@{}
    foreach ($document in $documents) {
        if (-not $document.PSObject.Properties['contents']) {
            continue
        }
        foreach ($modeEntry in @(
                [pscustomobject]@{ Name = 'resource'; Mode = 'managed' }
                [pscustomobject]@{ Name = 'data'; Mode = 'data' }
            )) {
            $mode = $document.contents.PSObject.Properties[$modeEntry.Name]
            if ($null -eq $mode -or $null -eq $mode.Value) {
                continue
            }
            foreach ($typeProperty in $mode.Value.PSObject.Properties) {
                foreach ($nameProperty in $typeProperty.Value.PSObject.Properties) {
                    $instances = @($nameProperty.Value)
                    if ($instances.Count -eq 0) {
                        continue
                    }
                    $expressions = [ordered]@{}
                    foreach ($attribute in $instances[0].PSObject.Properties) {
                        $expression = ConvertTo-AvmTerraformPolicyExpression -Value $attribute.Value
                        if ($null -ne $expression) {
                            $expressions[$attribute.Name] = $expression
                        }
                    }
                    $resources.Add([pscustomobject][ordered]@{
                            address     = ('{0}.{1}' -f $typeProperty.Name, $nameProperty.Name)
                            mode        = $modeEntry.Mode
                            type        = $typeProperty.Name
                            name        = $nameProperty.Name
                            expressions = [pscustomobject]$expressions
                        })
                }
            }
        }
        $moduleProperty = $document.contents.PSObject.Properties['module']
        if ($null -eq $moduleProperty -or $null -eq $moduleProperty.Value) {
            continue
        }
        foreach ($modulePropertyEntry in $moduleProperty.Value.PSObject.Properties) {
            $instances = @($modulePropertyEntry.Value)
            if ($instances.Count -eq 0 -or
                -not $instances[0].PSObject.Properties['source']) {
                continue
            }
            $source = [string]$instances[0].source
            if (-not $source.StartsWith('.')) {
                continue
            }
            $modulePath = [System.IO.Path]::GetFullPath((Join-Path $WorkingDirectory $source))
            if (-not (Test-Path -LiteralPath $modulePath -PathType Container)) {
                continue
            }
            $moduleCalls[$modulePropertyEntry.Name] = [pscustomobject][ordered]@{
                source = $source
                module = Get-AvmTerraformPolicyModuleConfiguration `
                    -WorkingDirectory $modulePath `
                    -ConftestPath $ConftestPath `
                    -Depth ($Depth + 1)
            }
        }
    }

    return [pscustomobject][ordered]@{
        resources    = $resources.ToArray()
        module_calls = [pscustomobject]$moduleCalls
    }
}

function ConvertTo-AvmTerraformPolicyExpression {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        $Value
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Value -is [string]) {
        $references = @(Get-AvmTerraformPolicyReference -Value $Value)
        if ($references.Count -gt 0) {
            return [pscustomobject][ordered]@{ references = $references }
        }
        return [pscustomobject][ordered]@{ constant_value = $Value }
    }
    if ($null -eq $Value -or
        $Value -is [bool] -or
        $Value -is [byte] -or
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [decimal] -or
        $Value -is [double]) {
        return [pscustomobject][ordered]@{ constant_value = $Value }
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        return @($Value | ForEach-Object {
                ConvertTo-AvmTerraformPolicyExpression -Value $_
            })
    }
    if ($Value -is [pscustomobject]) {
        $converted = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $converted[$property.Name] = ConvertTo-AvmTerraformPolicyExpression -Value $property.Value
        }
        $references = @(Get-AvmTerraformPolicyReference -Value $Value)
        if ($references.Count -gt 0) {
            $converted['references'] = $references
        }
        return [pscustomobject]$converted
    }

    return [pscustomobject][ordered]@{ constant_value = $Value }
}

function Get-AvmTerraformPolicyReference {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        $Value
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $references = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($Value)
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($item -is [string]) {
            foreach ($interpolation in [regex]::Matches(
                    $item,
                    '(?<!\$)\$\{(?<expression>[^}]+)\}',
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                $expression = $interpolation.Groups['expression'].Value
                foreach ($traversal in [regex]::Matches(
                        $expression,
                        '(?<reference>[A-Za-z_][A-Za-z0-9_-]*(?:(?:\.[A-Za-z0-9_-]+)|(?:\[[^\]]+\]))+)',
                        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                    $reference = $traversal.Groups['reference'].Value -replace '\[\*\]', ''
                    $null = $references.Add($reference)
                }
            }
        }
        elseif ($item -is [System.Collections.IEnumerable] -and $item -isnot [pscustomobject]) {
            foreach ($child in $item) { $queue.Enqueue($child) }
        }
        elseif ($item -is [pscustomobject]) {
            foreach ($property in $item.PSObject.Properties) { $queue.Enqueue($property.Value) }
        }
    }

    return @($references | Sort-Object)
}

function Invoke-AvmTerraformPolicyExample {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Example,

        [Parameter(Mandatory)]
        $Options
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $envVars = @{}
    $primaryError = $null
    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluated = 0

    try {
        Invoke-AvmScriptHook `
            -HookPath (Join-Path $Example.StagedPath 'pre.ps1') `
            -WorkingDirectory $Example.StagedPath `
            -Label ("policy {0} pre.ps1" -f $Example.Name)

        $envVars = ConvertFrom-AvmDotEnv -Path (Join-Path $Example.StagedPath '.env')

        $terraformLock = Lock-AvmTerraformPluginCache `
            -WorkingDirectory $Example.StagedPath `
            -EnvVars $envVars
        try {
            $test = New-AvmTerraformPolicyTest `
                -WorkingDirectory $Example.StagedPath `
                -ModuleRoot $Options.ModuleRoot `
                -ConftestPath $Options.ConftestPath
            $null = Invoke-AvmTerraformInit `
                -TerraformPath $Options.TerraformPath `
                -WorkingDirectory $test.WorkingDirectory `
                -EnvVars $envVars `
                -Label ("terraform init ({0})" -f $Example.Name) `
                -NoColor `
                -TestDirectory $test.DirectoryName `
                -SkipPluginCacheLock

            $testResult = Invoke-AvmProcess `
                -FilePath $Options.TerraformPath `
                -ArgumentList @(
                    'test'
                    '-json'
                    '-verbose'
                    '-no-color'
                    ('-test-directory={0}' -f $test.DirectoryName)
                ) `
                -WorkingDirectory $test.WorkingDirectory `
                -EnvVars $envVars `
                -Label ("terraform test policy plan ({0})" -f $Example.Name)
        }
        finally {
            if ($null -ne $terraformLock) {
                $terraformLock.Dispose()
            }
        }

        $planJsonPath = Join-Path $Example.StagedPath 'tfplan.json'
        $plan = ConvertFrom-AvmTerraformTestPlan -Output ([string]$testResult.StdOut) |
            ConvertFrom-Json -Depth 100
        $plan | Add-Member `
            -NotePropertyName 'configuration' `
            -NotePropertyValue (Get-AvmTerraformPolicyConfiguration `
                -WorkingDirectory $Example.StagedPath `
                -ConftestPath $Options.ConftestPath)
        [System.IO.File]::WriteAllText(
            $planJsonPath,
            ($plan | ConvertTo-Json -Depth 100 -Compress),
            [System.Text.UTF8Encoding]::new($false))

        $localExceptions = Join-Path $Example.StagedPath 'exceptions'
        $policyRuns = @(
            [pscustomobject]@{ Name = 'APRL'; Path = $Options.AprlPath }
            [pscustomobject]@{ Name = 'AVMSEC'; Path = $Options.AvmsecPath }
        )

        foreach ($policyRun in $policyRuns) {
            $arguments = [System.Collections.Generic.List[string]]::new()
            $arguments.Add('test')
            $arguments.Add('--all-namespaces')
            $arguments.Add('--policy')
            $arguments.Add([string]$policyRun.Path)
            $arguments.Add('--policy')
            $arguments.Add($Options.DefaultExceptions)
            if (Test-Path -LiteralPath $localExceptions -PathType Container) {
                $arguments.Add('--policy')
                $arguments.Add($localExceptions)
            }
            $arguments.Add('--output')
            $arguments.Add('json')
            $arguments.Add('tfplan.json')

            $policyResult = Invoke-AvmProcess `
                -FilePath $Options.ConftestPath `
                -ArgumentList $arguments.ToArray() `
                -WorkingDirectory $Example.StagedPath `
                -EnvVars $envVars `
                -Label ("conftest {0} ({1})" -f $policyRun.Name, $Example.Name) `
                -IgnoreExitCode

            $parsed = ConvertFrom-AvmPolicyResult `
                -Result $policyResult `
                -ExamplePath $Example.RelativePath `
                -PolicyName $policyRun.Name
            $evaluated += $parsed.Evaluated
            foreach ($issue in $parsed.Issues) {
                $issues.Add($issue)
            }
        }
    }
    catch {
        $primaryError = $_
    }

    try {
        Invoke-AvmScriptHook `
            -HookPath (Join-Path $Example.StagedPath 'post.ps1') `
            -WorkingDirectory $Example.StagedPath `
            -EnvVars $envVars `
            -Label ("policy {0} post.ps1" -f $Example.Name)
    }
    catch {
        if ($null -eq $primaryError) {
            throw
        }
        Write-AvmLog `
            -Level Warning `
            -File (Join-Path $Example.RelativePath 'post.ps1') `
            -Message ("Policy post hook also failed; preserving the primary error: {0}" -f $_.Exception.Message)
    }

    if ($null -ne $primaryError) {
        throw $primaryError
    }

    return [pscustomobject]@{
        Evaluated = $evaluated
        Issues    = $issues.ToArray()
    }
}

function Get-AvmConftestOverrideWarning {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string[]] $ExamplePath
    )

    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath
    $warnings = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($example in $ExamplePath) {
        $exceptionsPath = Join-Path $example 'exceptions'
        if (-not (Test-Path -LiteralPath $exceptionsPath -PathType Container)) {
            continue
        }

        $exceptionFiles = @(
            Get-ChildItem `
                -LiteralPath $exceptionsPath `
                -Filter '*.rego' `
                -File `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Sort-Object FullName
        )
        foreach ($exceptionFile in $exceptionFiles) {
            $file = [System.IO.Path]::GetRelativePath($rootFull, $exceptionFile.FullName).Replace('\', '/')
            $text = [System.IO.File]::ReadAllText($exceptionFile.FullName)
            $rules = @(
                @(
                    foreach ($exceptionMatch in [regex]::Matches($text, '(?ms)\bexception\s+contains\s+rules\s+if\s*\{(?<block>[^{}]*)\}')) {
                        foreach ($ruleListMatch in [regex]::Matches($exceptionMatch.Groups['block'].Value, '(?ms)\brules\s*(?::=|=)\s*\[(?<body>.*?)\]')) {
                            foreach ($ruleMatch in [regex]::Matches($ruleListMatch.Groups['body'].Value, '["''](?<rule>[^"'']+)["'']')) {
                                [string]$ruleMatch.Groups['rule'].Value
                            }
                        }
                    }
                ) | Select-Object -Unique
            )

            if ($rules.Count -gt 0) {
                foreach ($rule in $rules) {
                    $key = "$file`0$rule"
                    if (-not $seen.Add($key)) {
                        continue
                    }
                    $warnings.Add([pscustomobject][ordered]@{
                            File    = $file
                            Rule    = $rule
                            Message = ("Conftest override exempts rule '{0}'." -f $rule)
                        })
                }
            }
            elseif ($text -cmatch '\bexception\s+contains\s+rules\s+if\b') {
                $key = "$file`0"
                if ($seen.Add($key)) {
                    $warnings.Add([pscustomobject][ordered]@{
                            File    = $file
                            Rule    = ''
                            Message = 'Conftest override file found, but no exempted rules could be parsed.'
                        })
                }
            }
        }
    }

    return $warnings.ToArray()
}

function Invoke-AvmTerraformCheckPolicy {
    <#
    .SYNOPSIS
        Evaluate Terraform examples against the pinned APRL and AVMSEC policies.

    .DESCRIPTION
        Implements the legacy AVM pr-check policy lifecycle without mutating the
        repository. The module is copied beneath the AVM cache, then every direct
        examples/* directory is evaluated independently with bounded parallelism:

          - examples carrying .e2eignore are skipped
          - pre.ps1 runs when present; pre.sh is rejected with migration guidance
          - .env is loaded into Terraform and Conftest subprocesses
          - terraform init and a generated mock-provider test produce a
            credential-free plan-JSON input
          - APRL and AVMSEC run separately with all namespaces enabled
          - the pinned AVMSEC exemptions and that example's local exceptions/
            directory are included in both evaluations
          - post.ps1 runs after the example; post.sh is rejected likewise

        The staging directory is deliberately beneath the policy bundle cache.
        Conftest strips the drive letter from --policy paths on Windows;
        keeping the working tree and bundles on one volume preserves resolution.

        Conftest output is captured as JSON rather than streamed. The legacy
        command used --quiet; omitting that switch here has the same user-visible
        silence while retaining success records needed for the Evaluated count.

    .PARAMETER Context
        Terraform module context produced by Get-AvmModuleContext.

    .PARAMETER AllowPathFallback
        Allow Terraform and Conftest to resolve from PATH.

    .PARAMETER ThrottleLimit
        Maximum number of independent examples to evaluate at once. Defaults to
        one for direct engine calls.

    .OUTPUTS
        A Terraform engine result with Status, Evaluated, and Issues.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Context,

        [switch] $AllowPathFallback,

        [ValidateRange(1, 32)]
        [int] $ThrottleLimit = 1
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if ($Context.Ecosystem -ne 'terraform') {
        throw [System.ArgumentException]::new(
            "Invoke-AvmTerraformCheckPolicy requires a terraform context (got Ecosystem='$($Context.Ecosystem)').")
    }

    $conftest = Resolve-AvmTool -Name 'conftest' -AllowPathFallback:$AllowPathFallback
    $terraform = Resolve-AvmTool -Name 'terraform' -AllowPathFallback:$AllowPathFallback
    $aprlAsset = Resolve-AvmPolicyBundle -Name 'avm-policy-aprl'
    $avmsecAsset = Resolve-AvmPolicyBundle -Name 'avm-policy-avmsec'

    $defaultExceptionSource = Join-Path $avmsecAsset.Path 'avm_exceptions.rego.bak'
    if (-not (Test-Path -LiteralPath $defaultExceptionSource -PathType Leaf)) {
        throw [AvmConfigurationException]::new(
            "The pinned AVMSEC bundle does not contain the default exemption policy: '$defaultExceptionSource'.")
    }

    $examplesRoot = Join-Path $Context.Root 'examples'
    $examplePaths = @()
    if (Test-Path -LiteralPath $examplesRoot -PathType Container) {
        $examplePaths = @(Get-ChildItem -LiteralPath $examplesRoot -Directory -ErrorAction Stop |
                ForEach-Object FullName)
        [System.Array]::Sort($examplePaths, [System.StringComparer]::Ordinal)
    }

    $activeExamples = @($examplePaths | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $_ '.e2eignore') -PathType Leaf)
        })
    if ($activeExamples.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Engine     = 'terraform'
            Tool       = ('{0}/{1}' -f $conftest.Name, $conftest.Version)
            ToolPath   = $conftest.Path
            ToolSource = $conftest.Source
            Status     = 'skipped'
            Evaluated  = 0
            Issues     = @()
        }
    }

    foreach ($warning in (Get-AvmConftestOverrideWarning -Root $Context.Root -ExamplePath $activeExamples)) {
        Write-AvmLog `
            -Message $warning.Message `
            -Level Warning `
            -File $warning.File
    }

    $shellHooks = [System.Collections.Generic.List[string]]::new()
    foreach ($sourceExample in $activeExamples) {
        $exampleName = Split-Path -Path $sourceExample -Leaf
        foreach ($hookName in @('pre.sh', 'post.sh')) {
            if (Test-Path -LiteralPath (Join-Path $sourceExample $hookName) -PathType Leaf) {
                $shellHooks.Add(('examples/{0}/{1}' -f $exampleName, $hookName))
            }
        }
    }
    if ($shellHooks.Count -gt 0) {
        throw [AvmConfigurationException]::new(
            ("The terraform policy engine runs PowerShell hooks only. Refactor these shell hooks to '.ps1': {0}" -f ($shellHooks -join ', ')))
    }

    $stageParent = Join-Path (Get-AvmFolder -Kind Cache) 'policy-stage'
    $stageRoot = Join-Path $stageParent ('avm-policy-' + [guid]::NewGuid().ToString('N'))
    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluated = 0
    $streamOutput = Test-AvmVerboseEnabled
    $effectiveThrottle = if ($streamOutput) { 1 } else { $ThrottleLimit }

    try {
        Copy-AvmTerraformModuleTree -SourceRoot $Context.Root -DestinationRoot $stageRoot

        $defaultExceptions = Join-Path `
            -Path $stageRoot `
            -ChildPath 'policy' `
            -AdditionalChildPath 'default_exceptions'
        $null = New-Item -ItemType Directory -Path $defaultExceptions -Force -ErrorAction Stop
        Copy-Item `
            -LiteralPath $defaultExceptionSource `
            -Destination (Join-Path $defaultExceptions 'avm_exceptions.rego') `
            -Force `
            -ErrorAction Stop

        $examples = [System.Collections.Generic.List[object]]::new()
        for ($exampleIndex = 0; $exampleIndex -lt $activeExamples.Count; $exampleIndex++) {
            $sourceExample = $activeExamples[$exampleIndex]
            $relativeExample = [System.IO.Path]::GetRelativePath($Context.Root, $sourceExample)
            $stagedExample = Join-Path $stageRoot $relativeExample
            $exampleName = Split-Path -Path $sourceExample -Leaf
            Write-AvmLog `
                -Level Info `
                -Message ("policy: example {0}/{1} = {2}" -f ($exampleIndex + 1), $activeExamples.Count, $exampleName) |
                Out-Null
            $examples.Add([pscustomobject]@{
                    Name         = $exampleName
                    RelativePath = $relativeExample
                    StagedPath   = $stagedExample
                })
        }

        Write-AvmLog `
            -Level Verbose `
            -Message ("policy: processing examples with {0} worker(s)" -f $effectiveThrottle) |
            Out-Null
        $options = [pscustomobject]@{
            TerraformPath     = $terraform.Path
            ConftestPath      = $conftest.Path
            AprlPath          = $aprlAsset.Path
            AvmsecPath        = $avmsecAsset.Path
            DefaultExceptions = $defaultExceptions
            ModuleRoot        = $stageRoot
        }
        $exampleResults = @(
            Invoke-AvmParallel `
                -InputObject $examples.ToArray() `
                -FunctionName 'Invoke-AvmTerraformPolicyExample' `
                -Argument $options `
                -ThrottleLimit $effectiveThrottle
        )
        foreach ($exampleResult in $exampleResults) {
            $evaluated += $exampleResult.Evaluated
            foreach ($issue in $exampleResult.Issues) {
                $issues.Add($issue)
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item `
                -LiteralPath $stageRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue `
                -ProgressAction SilentlyContinue
        }
    }

    $status = if (@($issues | Where-Object { $_.Severity -eq 'error' }).Count -gt 0) { 'fail' } else { 'pass' }
    return [pscustomobject][ordered]@{
        Engine     = 'terraform'
        Tool       = ('{0}/{1}' -f $conftest.Name, $conftest.Version)
        ToolPath   = $conftest.Path
        ToolSource = $conftest.Source
        Status     = $status
        Evaluated  = $evaluated
        Issues     = $issues.ToArray()
    }
}

function ConvertFrom-AvmPolicyResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [string] $ExamplePath,

        [Parameter(Mandatory)]
        [string] $PolicyName
    )

    if ($Result.ExitCode -notin @(0, 1)) {
        $summary = "conftest $PolicyName exited with code $($Result.ExitCode)."
        $message = Add-AvmProcessFailureDetail `
            -Message $summary `
            -StdOut $Result.StdOut `
            -StdErr $Result.StdErr
        if ($message -ceq $summary) {
            $message += [Environment]::NewLine + '  conftest produced no diagnostic.'
        }
        throw [AvmProcessException]::new(
            $message)
    }

    $payload = if ($Result.StdOut) { $Result.StdOut.Trim() } else { '' }
    if ($Result.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($payload)) {
        $summary = "conftest $PolicyName exited before evaluating a policy."
        $message = Add-AvmProcessFailureDetail `
            -Message $summary `
            -StdOut $Result.StdOut `
            -StdErr $Result.StdErr
        if ($message -ceq $summary) {
            $message += [Environment]::NewLine + '  conftest produced no result.'
        }
        throw [AvmProcessException]::new(
            $message)
    }

    $records = @()
    if (-not [string]::IsNullOrWhiteSpace($payload)) {
        try {
            $records = @($payload | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            throw [AvmProcessException]::new(
                "Could not parse conftest $PolicyName JSON output: $($_.Exception.Message)")
        }
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $evaluated = 0
    $issueFile = [System.IO.Path]::Combine($ExamplePath, 'tfplan.json').Replace('\', '/')
    foreach ($record in $records) {
        if (-not $record) { continue }
        $namespace = if ($record.PSObject.Properties['namespace']) {
            [string]$record.namespace
        }
        else {
            $PolicyName.ToLowerInvariant()
        }

        if ($record.PSObject.Properties['successes']) {
            $evaluated += [int]$record.successes
        }
        foreach ($bucket in @('failures', 'warnings', 'exceptions')) {
            if ($record.PSObject.Properties[$bucket] -and $record.$bucket) {
                $evaluated += @($record.$bucket).Count
            }
        }

        foreach ($bucket in @(
                [pscustomobject]@{ Name = 'failures'; Severity = 'error' }
                [pscustomobject]@{ Name = 'warnings'; Severity = 'warning' }
            )) {
            if (-not $record.PSObject.Properties[$bucket.Name] -or -not $record.($bucket.Name)) {
                continue
            }
            foreach ($finding in @($record.($bucket.Name))) {
                $message = if ($finding.PSObject.Properties['msg']) { [string]$finding.msg } else { '' }
                $issues.Add([pscustomobject][ordered]@{
                        File     = $issueFile
                        Line     = 0
                        Column   = 0
                        Severity = $bucket.Severity
                        Code     = $namespace
                        Message  = $message
                    })
            }
        }
    }

    return [pscustomobject][ordered]@{
        Evaluated = $evaluated
        Issues    = $issues.ToArray()
    }
}
