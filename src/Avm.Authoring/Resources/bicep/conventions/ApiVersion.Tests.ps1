#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary] $Convention
)

$Convention.NativeApiVersionExpected = 1
$cases = @(@{
        IssuePath         = $Convention.Root
        Specs             = $Convention.ApiSpecs
        UnavailableReason = $Convention.ApiSpecsUnavailableReason
        Modules           = $Convention.ApiVersionInputs
    })

Describe 'Bicep resource API versions' -ForEach $cases {
    It 'has an available provider API catalog' -Tag 'avm.bicep.api-specs-unavailable' {
        $UnavailableReason | Should -BeNullOrEmpty
        $Specs | Should -BeOfType ([System.Collections.IDictionary])
    }
    if ([string]::IsNullOrEmpty($UnavailableReason) -and $Specs -is [System.Collections.IDictionary] -and $Modules.Count -gt 0) {
        Context 'Compiled module <IssuePath>' -ForEach $Modules {
            $Convention.NativeApiVersionExpected++
            It 'exposes inspectable recursive resources' -Tag 'avm.bicep.api-resources-uninspectable' {
                $ReadError | Should -BeNullOrEmpty
            }
            if (-not $ReadError -and $Resources.Count -gt 0) {
                Context 'Resource <Type> (<Api>)' -ForEach $Resources {
                    $Convention.NativeApiVersionExpected++
                    It 'is an object with a canonical resource type' -Tag 'avm.bicep.api-resource-invalid' {
                        $Resource | Should -BeOfType ([System.Collections.IDictionary])
                        $Type | Should -BeOfType ([string])
                        $Type | Should -MatchExactly '^[A-Za-z0-9.-]+(?:/[A-Za-z0-9.-]+)+\z'
                    }
                    if ($Resource -is [System.Collections.IDictionary] -and $Type -is [string] -and
                        $Type -cmatch '^[A-Za-z0-9.-]+(?:/[A-Za-z0-9.-]+)+\z') {
                        $Convention.NativeApiVersionExpected++
                        It 'declares a dated API version' -Tag 'avm.bicep.api-version-invalid' {
                            $Api | Should -BeOfType ([string])
                            $Api | Should -MatchExactly '^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[A-Za-z0-9-]+)?\z'
                            $date = [datetime]::MinValue
                            [datetime]::TryParseExact($Api.Substring(0, 10), 'yyyy-MM-dd',
                                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date) |
                                Should -BeTrue
                        }
                        $date = [datetime]::MinValue
                        if ($Api -is [string] -and $Api -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[A-Za-z0-9-]+)?\z' -and
                            [datetime]::TryParseExact($Api.Substring(0, 10), 'yyyy-MM-dd',
                                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
                            $parts = $Type.Split('/')
                            $provider = $parts[0]
                            $resourceType = $parts[1..($parts.Length - 1)] -join '/'
                            $extensionProviders = @{
                                diagnosticSettings = 'Microsoft.Insights'
                                locks              = 'Microsoft.Authorization'
                                roleAssignments    = 'Microsoft.Authorization'
                                privateEndpoints   = 'Microsoft.Network'
                            }
                            if ($extensionProviders.ContainsKey($parts[-1])) {
                                $provider = $extensionProviders[$parts[-1]]
                                $resourceType = $parts[-1]
                            }
                            $providers = @($Specs.psbase.Keys | Where-Object { $_ -eq $provider })
                            $providerData = @(@{
                                    Provider      = $provider
                                    ResourceType  = $resourceType
                                    Providers     = $providers
                                    ProviderSpecs = if ($providers.Count -eq 1) { $Specs[$providers[0]] } else { $null }
                                })
                            Context 'Catalog <Provider>/<ResourceType>' -ForEach $providerData {
                                $Convention.NativeApiVersionExpected++
                                if ($Providers.Count -eq 0) {
                                    It 'lists the resource provider' -Tag 'avm.bicep.api-provider-unknown', 'severity:warning' {
                                        @($Providers) | Should -Not -BeNullOrEmpty -Because "the API catalog should list provider '$Provider' for '$Type'"
                                    }
                                }
                                else {
                                    It 'has one unambiguous provider object' -Tag 'avm.bicep.api-specs-invalid' {
                                        @($Providers) | Should -HaveCount 1
                                        $ProviderSpecs | Should -BeOfType ([System.Collections.IDictionary])
                                    }
                                    if ($Providers.Count -eq 1 -and $ProviderSpecs -is [System.Collections.IDictionary]) {
                                        $types = @($ProviderSpecs.psbase.Keys | Where-Object { $_ -eq $ResourceType })
                                        $typeData = @(@{
                                                Types     = $types
                                                Available = if ($types.Count -eq 1) { , $ProviderSpecs[$types[0]] } else { $null }
                                            })
                                        Context 'Resource type entry' -ForEach $typeData {
                                            $Convention.NativeApiVersionExpected++
                                            if ($Types.Count -eq 0) {
                                                It 'lists the resource type' -Tag 'avm.bicep.api-type-unknown', 'severity:warning' {
                                                    @($Types) | Should -Not -BeNullOrEmpty -Because "the API catalog should list '$Provider/$ResourceType'"
                                                }
                                            }
                                            else {
                                                It 'has one unambiguous nonempty API array' -Tag 'avm.bicep.api-specs-invalid' {
                                                    @($Types) | Should -HaveCount 1
                                                    $Available -is [array] | Should -BeTrue
                                                    $Available.Count | Should -BeGreaterThan 0
                                                }
                                                if ($Types.Count -eq 1 -and $Available -is [array] -and $Available.Count -gt 0) {
                                                    $versionCases = @(for ($index = 0; $index -lt $Available.Count; $index++) {
                                                            $candidate = $Available[$index]
                                                            $releaseDate = [datetime]::MinValue
                                                            $parsedDate = $null
                                                            if ($candidate -is [string] -and
                                                                $candidate -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:-[A-Za-z0-9-]+)?\z' -and
                                                                [datetime]::TryParseExact($candidate.Substring(0, 10), 'yyyy-MM-dd',
                                                                    [Globalization.CultureInfo]::InvariantCulture,
                                                                    [Globalization.DateTimeStyles]::None, [ref]$releaseDate)) {
                                                                $parsedDate = $releaseDate
                                                            }
                                                            @{
                                                                Candidate  = $candidate
                                                                ParsedDate = $parsedDate
                                                                Earlier    = @(for ($previous = 0; $previous -lt $index; $previous++) { $Available[$previous] })
                                                            }
                                                        })
                                                    $Convention.NativeApiVersionExpected += $versionCases.Count
                                                    It 'contains a valid unique API date <Candidate>' -ForEach $versionCases -Tag 'avm.bicep.api-specs-invalid' {
                                                        $Candidate | Should -BeOfType ([string])
                                                        $ParsedDate | Should -Not -BeNullOrEmpty
                                                        @($Earlier | Where-Object { $_ -ceq $Candidate }) | Should -HaveCount 0
                                                    }
                                                    $invalid = @($versionCases | Where-Object {
                                                            $null -eq $_.ParsedDate -or $_.Candidate -cin $_.Earlier
                                                        })
                                                    if ($invalid.Count -eq 0) {
                                                        $ordered = @($Available | Sort-Object -Culture 'en-US')
                                                        $recent = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                                                        foreach ($item in @($ordered | Select-Object -Last 5) +
                                                            @($ordered | Where-Object { $_ -notlike '*-preview' } | Select-Object -Last 5)) {
                                                            $null = $recent.Add($item)
                                                        }
                                                        $approved = @($recent | Sort-Object -Culture 'en-US' -Descending)
                                                        $Convention.NativeApiVersionExpected++
                                                        It 'uses a recently approved version' -ForEach @(@{ Approved = $approved }) `
                                                            -Tag 'avm.bicep.api-version-outdated', 'severity:warning' {
                                                            @($Approved | Where-Object { $_ -ceq $Api }) | Should -HaveCount 1 `
                                                                -Because "resource '$Type' should use a recent version of '$Provider/$ResourceType': $($Approved -join ', ')"
                                                        }
                                                        if ($recent.Contains($Api) -and $approved.Count -gt 1) {
                                                            $Convention.NativeApiVersionExpected++
                                                            It 'is newer than the oldest approved API' -ForEach @(@{ Oldest = $approved[-1] }) `
                                                                -Tag 'avm.bicep.api-version-near-expiry', 'severity:warning' {
                                                                $Api | Should -Not -BeExactly $Oldest -Because "resource '$Type' should move beyond the oldest approved API"
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
