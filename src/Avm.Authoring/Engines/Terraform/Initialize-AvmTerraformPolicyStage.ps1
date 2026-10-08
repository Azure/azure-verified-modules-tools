function Assert-AvmTerraformPolicyPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $StageRoot
    )

    $root = [System.IO.Path]::GetFullPath($StageRoot)
    $full = [System.IO.Path]::GetFullPath($Path)
    $relative = [System.IO.Path]::GetRelativePath($root, $full)
    if ([System.IO.Path]::IsPathRooted($relative) -or @($relative -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Policy configuration '$full' is outside its isolated staging directory. Use module sources inside the repository or downloaded by Terraform.")
    }
    $current = $root
    foreach ($segment in @('.') + @($relative -split '[\\/]')) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [AvmConfigurationException]::new(
                "Policy configuration '$full' traverses a link. Use regular files in the isolated module tree so provider safeguards cannot change another scope.")
        }
    }
}

function Get-AvmTerraformPolicyEnvironment {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $StageRoot,
        [hashtable] $Environment = @{}
    )

    foreach ($name in @('TF_CLI_ARGS', 'TF_CLI_ARGS_init', 'TF_CLI_ARGS_providers', 'TF_CLI_ARGS_validate', 'TF_CLI_ARGS_plan', 'TF_CLI_ARGS_show')) {
        $value = if ($Environment.ContainsKey($name)) { $Environment[$name] } else { [Environment]::GetEnvironmentVariable($name) }
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            throw [AvmConfigurationException]::new(
                "Unset '$name' for policy checks; extra Terraform arguments can bypass isolated planning. Supply inputs through .tfvars or TF_VAR_* instead.")
        }
    }
    $result = @{} + $Environment
    $result.TF_DATA_DIR = Join-Path $StageRoot 'data'
    $result.ARM_SKIP_PROVIDER_REGISTRATION = 'true'
    $result.ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'legacy'
    return $result
}

function Read-AvmTerraformPolicyConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $StageRoot,
        [Parameter(Mandatory)] [string] $ConftestPath
    )

    Assert-AvmTerraformPolicyPath -Path $Path -StageRoot $StageRoot
    $directoryFiles = @(Get-ChildItem -LiteralPath $Path -File -Force | Where-Object { -not $_.Name.StartsWith('.') })
    if (@($directoryFiles | Where-Object { $_.Name -cmatch '\.(tfquery|tfmigrate)\.(hcl|json)$' }).Count -gt 0) {
        throw [AvmConfigurationException]::new(
            "Policy configuration '$Path' contains query or state-migration files outside normal provider override precedence. Use a dedicated example without those files for policy checks.")
    }
    $files = @($directoryFiles | Where-Object {
            ($_.Name -clike '*.tf' -or $_.Name -clike '*.tf.json') -and
            -not $_.Name.EndsWith('~')
        })
    $documents = [System.Collections.Generic.List[object]]::new()
    $hclFiles = @($files | Where-Object { $_.Name -clike '*.tf' })
    foreach ($file in $files) {
        Assert-AvmTerraformPolicyPath -Path $file.FullName -StageRoot $StageRoot
    }
    if ($hclFiles.Count -gt 0) {
        $parsed = Invoke-AvmProcess -FilePath $ConftestPath `
            -ArgumentList (@('parse', '--parser', 'hcl2', '--combine') + @($hclFiles.FullName)) `
            -WorkingDirectory $Path -IgnoreExitCode
        if ($parsed.ExitCode -ne 0) {
            throw [AvmConfigurationException]::new(
                "Cannot parse Terraform configuration in '$Path' for provider-registration safeguards. Correct the HCL before retrying policy checks.")
        }
        try {
            $records = ConvertFrom-Json -InputObject $parsed.StdOut -AsHashtable -Depth 100 -NoEnumerate -ErrorAction Stop
        }
        catch [System.ArgumentException] {
            throw [AvmConfigurationException]::new("The HCL parser returned invalid JSON for '$Path'. Reinstall the configured Conftest tool.")
        }
        if ($records -isnot [array] -or $records.Count -ne $hclFiles.Count) {
            throw [AvmConfigurationException]::new("The HCL parser did not return every Terraform file in '$Path'. Policy planning is blocked.")
        }
        $remaining = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($file in $hclFiles) { $null = $remaining.Add($file.FullName) }
        foreach ($record in $records) {
            if ($record -isnot [System.Collections.IDictionary] -or -not $record.Contains('path') -or -not $record.Contains('contents') -or
                $record.path -isnot [string] -or
                -not $remaining.Remove($record.path) -or $record.contents -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new("The HCL parser returned an incomplete or ambiguous file set for '$Path'. Policy planning is blocked.")
            }
            $documents.Add($record.contents)
        }
    }
    foreach ($file in @($files | Where-Object { $_.Name -clike '*.tf.json' })) {
        try {
            $document = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file.FullName)) -AsHashtable -Depth 100 -ErrorAction Stop
        }
        catch [System.ArgumentException] {
            throw [AvmConfigurationException]::new("Cannot parse Terraform JSON configuration '$($file.FullName)' for provider safeguards.")
        }
        if ($document -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new("Terraform JSON configuration '$($file.FullName)' must be an object.")
        }
        $documents.Add($document)
    }

    $sources = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $providers = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $hasModules = $false
    $hasBackend = $false
    foreach ($document in $documents) {
        if ($document.Contains('module')) {
            if ($document.module -isnot [System.Collections.IDictionary]) {
                throw [AvmConfigurationException]::new("Cannot inspect module declarations in '$Path'. Correct the configuration before policy checks.")
            }
            if ($document.module.Count -gt 0) { $hasModules = $true }
        }
        if ($document.Contains('terraform')) {
            foreach ($terraform in @($document.terraform)) {
                if ($terraform -isnot [System.Collections.IDictionary]) {
                    throw [AvmConfigurationException]::new("Cannot inspect a Terraform block in '$Path' for provider safeguards.")
                }
                if ($terraform.Contains('backend') -or $terraform.Contains('cloud')) { $hasBackend = $true }
                if (-not $terraform.Contains('required_providers')) { continue }
                foreach ($requirements in @($terraform.required_providers)) {
                    if ($requirements -isnot [System.Collections.IDictionary]) {
                        throw [AvmConfigurationException]::new("Cannot inspect required_providers in '$Path'. Use explicit provider source addresses.")
                    }
                    foreach ($name in $requirements.Keys) {
                        $requirement = $requirements[$name]
                        $source = "hashicorp/$name"
                        if ($requirement -is [System.Collections.IDictionary] -and $requirement.Contains('source')) {
                            if ($requirement.source -isnot [string] -or $requirement.source -cnotmatch '^(?:[a-zA-Z0-9.-]+/)?[a-zA-Z0-9-]+/[a-zA-Z0-9-]+$') {
                                throw [AvmConfigurationException]::new("Provider '$name' in '$Path' must have a static source address for policy safeguards.")
                            }
                            $source = $requirement.source
                        }
                        if (($source -split '/').Count -eq 2) { $source = "registry.terraform.io/$source" }
                        $source = $source.ToLowerInvariant()
                        if ($sources.ContainsKey($name) -and $sources[$name] -cne $source) {
                            throw [AvmConfigurationException]::new("Provider '$name' in '$Path' has conflicting source declarations. Consolidate them before policy checks.")
                        }
                        $sources[$name] = $source
                    }
                }
            }
        }
        if (-not $document.Contains('provider')) { continue }
        if ($document.provider -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new("Cannot inspect provider blocks in '$Path'. Policy planning is blocked.")
        }
        foreach ($name in $document.provider.Keys) {
            foreach ($provider in @($document.provider[$name])) {
                if ($provider -isnot [System.Collections.IDictionary]) {
                    throw [AvmConfigurationException]::new("Cannot inspect provider '$name' in '$Path'. Policy planning is blocked.")
                }
                $alias = ''
                if ($provider.Contains('alias')) {
                    if ($provider.alias -isnot [string] -or $provider.alias -cnotmatch '^[\p{L}_][\p{L}\p{N}_-]*$') {
                        throw [AvmConfigurationException]::new("Provider '$name' in '$Path' must have a static alias for policy safeguards.")
                    }
                    $alias = $provider.alias
                }
                $key = "$name`0$alias"
                $configured = @($provider.Keys | Where-Object { $_ -cnotin @('alias', 'version') }).Count -gt 0
                if ($providers.ContainsKey($key)) { $configured = $configured -or $providers[$key].Configured }
                $providers[$key] = [pscustomobject]@{ Name = $name; Alias = $alias; Configured = $configured }
            }
        }
    }
    return [pscustomobject]@{
        Path       = $Path
        Files      = $files
        Sources    = $sources
        Providers  = @($providers.Values)
        HasModules = $hasModules
        HasBackend = $hasBackend
    }
}

function Get-AvmTerraformPolicyProviderSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Payload
    )

    try {
        $schema = ConvertFrom-Json -InputObject $Payload -AsHashtable -Depth 100 -ErrorAction Stop
    }
    catch [System.ArgumentException] {
        throw [AvmConfigurationException]::new('Terraform returned invalid provider schemas. Policy planning is blocked; reinitialize the configured providers.')
    }
    if ($schema -isnot [System.Collections.IDictionary] -or -not $schema.Contains('provider_schemas') -or
        $schema.provider_schemas -isnot [System.Collections.IDictionary]) {
        throw [AvmConfigurationException]::new('Terraform did not return provider_schemas. Policy planning is blocked.')
    }
    $settings = @{}
    foreach ($address in $schema.provider_schemas.Keys) {
        $source = $address.ToLowerInvariant()
        $providerName = ($source -split '/')[-1]
        if ($providerName -notin @('azurerm', 'azapi')) { continue }
        if ($source -notin @('registry.terraform.io/hashicorp/azurerm', 'registry.terraform.io/azure/azapi')) {
            throw [AvmConfigurationException]::new("Policy checks cannot enforce automatic registration for '$address'. Use the official AzureRM or AzAPI provider source.")
        }
        $provider = $schema.provider_schemas[$address]
        if ($provider -isnot [System.Collections.IDictionary] -or -not $provider.Contains('provider') -or
            $provider.provider -isnot [System.Collections.IDictionary] -or -not $provider.provider.Contains('block') -or
            $provider.provider.block -isnot [System.Collections.IDictionary] -or -not $provider.provider.block.Contains('attributes') -or
            $provider.provider.block.attributes -isnot [System.Collections.IDictionary]) {
            throw [AvmConfigurationException]::new("Provider '$address' has no inspectable configuration schema. Policy planning is blocked.")
        }
        $attributes = $provider.provider.block.attributes
        $required = @{ skip_provider_registration = 'bool' }
        $values = @{ skip_provider_registration = $true }
        if ($providerName -eq 'azurerm' -and $attributes.Contains('resource_provider_registrations')) {
            $required = @{ resource_provider_registrations = 'string'; resource_providers_to_register = @('list', 'string') }
            $values = @{ resource_provider_registrations = 'none'; resource_providers_to_register = @() }
            if ($attributes.Contains('skip_provider_registration')) {
                $required.skip_provider_registration = 'bool'
                $values.skip_provider_registration = $false
            }
        }
        foreach ($name in $required.Keys) {
            if (-not $attributes.Contains($name) -or $attributes[$name] -isnot [System.Collections.IDictionary] -or
                -not $attributes[$name].Contains('optional') -or $attributes[$name].optional -isnot [bool] -or
                -not $attributes[$name].optional -or -not $attributes[$name].Contains('type') -or
                (ConvertTo-Json -InputObject $attributes[$name].type -Compress) -cne (ConvertTo-Json -InputObject $required[$name] -Compress)) {
                throw [AvmConfigurationException]::new("Provider '$address' has an unsupported '$name' schema. Select a supported AzureRM/AzAPI version before policy checks.")
            }
        }
        $settings[$source] = $values
    }
    return $settings
}

function Set-AvmTerraformPolicyProviderOverride {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)] $Configuration,
        [Parameter(Mandatory)] [hashtable] $Settings
    )

    $providers = [ordered]@{}
    foreach ($provider in $Configuration.Providers) {
        if (-not $provider.Configured) { continue }
        $source = if ($Configuration.Sources.ContainsKey($provider.Name)) {
            $Configuration.Sources[$provider.Name]
        }
        else {
            "registry.terraform.io/hashicorp/$($provider.Name)".ToLowerInvariant()
        }
        if (-not $Settings.ContainsKey($source)) {
            if (($source -split '/')[-1] -in @('azurerm', 'azapi')) {
                throw [AvmConfigurationException]::new("Provider '$($provider.Name)' in '$($Configuration.Path)' does not match a protected provider schema. Declare its official required_providers source.")
            }
            continue
        }
        $values = @{} + $Settings[$source]
        if ($provider.Alias) { $values.alias = $provider.Alias }
        if (-not $providers.Contains($provider.Name)) { $providers[$provider.Name] = @() }
        $providers[$provider.Name] += $values
    }
    if ($providers.Count -eq 0) { return }

    $lastName = ''
    $lastKey = ''
    foreach ($file in $Configuration.Files) {
        if ($file.Name -cnotmatch '(^override|_override)\.tf(\.json)?$') { continue }
        $key = [Convert]::ToHexString([System.Text.Encoding]::UTF8.GetBytes($file.Name))
        if ([System.StringComparer]::Ordinal.Compare($key, $lastKey) -gt 0) {
            $lastName = $file.Name
            $lastKey = $key
        }
    }
    $name = if ($lastName) { "$lastName.avm_override.tf.json" } else { 'avm_provider_safety_override.tf.json' }
    $destination = Join-Path $Configuration.Path $name
    if ([System.Text.Encoding]::UTF8.GetByteCount($name) -gt 255 -or (Test-Path -LiteralPath $destination)) {
        throw [AvmConfigurationException]::new("Cannot create a final provider override in '$($Configuration.Path)'. Shorten or rename the authored override filenames.")
    }
    if (-not $PSCmdlet.ShouldProcess($destination, 'Disable automatic Azure provider registration in the staged policy configuration')) {
        throw [System.OperationCanceledException]::new('Policy provider safeguards were not approved; planning is blocked.')
    }
    $json = ConvertTo-Json -InputObject @{ provider = $providers } -Depth 20
    [System.IO.File]::WriteAllText($destination, $json.ReplaceLineEndings("`n") + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Initialize-AvmTerraformPolicyStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $StageRoot,
        [Parameter(Mandatory)] [string] $TerraformPath,
        [Parameter(Mandatory)] [string] $ConftestPath,
        [Parameter(Mandatory)] [hashtable] $EnvVars
    )

    $root = Read-AvmTerraformPolicyConfiguration -Path $WorkingDirectory -StageRoot $StageRoot -ConftestPath $ConftestPath
    if ($root.HasBackend) {
        throw [AvmConfigurationException]::new(
            "Policy example '$WorkingDirectory' declares a backend or cloud execution. Use a local, backend-free example so provider safeguards are enforced in isolated staging.")
    }
    $null = Invoke-AvmTerraformInit -TerraformPath $TerraformPath -WorkingDirectory $WorkingDirectory `
        -EnvVars $EnvVars -NoColor -SkipPluginCacheLock -PreserveDependencySelections `
        -Label 'terraform init (policy safeguards)'

    $directories = @()
    $manifestPath = Join-Path -Path $EnvVars.TF_DATA_DIR -ChildPath 'modules' -AdditionalChildPath 'modules.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Assert-AvmTerraformPolicyPath -Path $manifestPath -StageRoot $StageRoot
        $payload = [System.IO.File]::ReadAllText($manifestPath)
        $directories = @(ConvertFrom-AvmTerraformModuleManifest -Payload $payload -WorkingDirectory $WorkingDirectory)
        $manifest = ConvertFrom-Json -InputObject $payload -AsHashtable
        $rootRecord = @($manifest.Modules | Where-Object { $_.Key -ceq '' })[0]
        $manifestRoot = [System.IO.Path]::GetFullPath($rootRecord.Dir, $WorkingDirectory)
        if ([System.IO.Path]::GetRelativePath($WorkingDirectory, $manifestRoot) -cne '.') {
            throw [AvmConfigurationException]::new('The installed module manifest does not identify this isolated example as its root. Policy planning is blocked.')
        }
    }
    elseif ($root.HasModules) {
        throw [AvmConfigurationException]::new("Terraform did not produce an installed module manifest for '$WorkingDirectory'. Policy planning is blocked.")
    }
    $configurations = [System.Collections.Generic.List[object]]::new()
    $configurations.Add($root)
    foreach ($directory in $directories) {
        if ($directory -ceq $WorkingDirectory) { continue }
        $configurations.Add((Read-AvmTerraformPolicyConfiguration -Path $directory -StageRoot $StageRoot -ConftestPath $ConftestPath))
    }
    $schema = Invoke-AvmProcess -FilePath $TerraformPath -ArgumentList @('providers', 'schema', '-json') `
        -WorkingDirectory $WorkingDirectory -EnvVars $EnvVars -Label 'terraform provider schemas (policy safeguards)'
    $settings = Get-AvmTerraformPolicyProviderSetting -Payload $schema.StdOut
    $azureRm = 'registry.terraform.io/hashicorp/azurerm'
    # Implicit and inherited configurations use skip=true/legacy; explicit modern blocks use skip=false/none.
    if ($settings.ContainsKey($azureRm) -and -not $settings[$azureRm].ContainsKey('skip_provider_registration')) {
        $EnvVars.ARM_RESOURCE_PROVIDER_REGISTRATIONS = 'none'
    }
    foreach ($configuration in $configurations) {
        Set-AvmTerraformPolicyProviderOverride -Configuration $configuration -Settings $settings
    }
    $validation = Invoke-AvmProcess -FilePath $TerraformPath -ArgumentList @('validate', '-json') `
        -WorkingDirectory $WorkingDirectory -EnvVars $EnvVars -Label 'terraform validate (policy safeguards)' -IgnoreExitCode
    try {
        $validated = ConvertFrom-Json -InputObject $validation.StdOut -AsHashtable -ErrorAction Stop
    }
    catch [System.ArgumentException] {
        throw [AvmConfigurationException]::new('Terraform returned invalid validation output after provider safeguards; policy planning is blocked.')
    }
    if ($validation.ExitCode -ne 0 -or $validated -isnot [System.Collections.IDictionary] -or
        -not $validated.Contains('valid') -or $validated.valid -isnot [bool] -or -not $validated.valid) {
        throw [AvmConfigurationException]::new(
            "Terraform configuration in '$WorkingDirectory' failed validation after provider safeguards. Run terraform validate on the source and correct the configuration; no policy plan was started.")
    }
    if ($settings.Count -gt 0) {
        Write-AvmLog 'policy: automatic AzureRM/AzAPI provider registration is disabled in the staged plan.' -Level Info | Out-Null
    }
}
