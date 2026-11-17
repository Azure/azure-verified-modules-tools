function Get-AvmTerraformRetryPolicy {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    if (-not (Get-Variable -Name AvmTerraformRetryPolicy -Scope Script -ErrorAction Ignore)) {
        $root = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath @('..', 'Resources', 'terraform')
        $json = [System.IO.File]::ReadAllText((Join-Path $root 'retry-policy.json'))
        $schema = [System.IO.File]::ReadAllText((Join-Path $root 'retry-policy.schema.json'))
        if (-not (Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue)) {
            throw [AvmConfigurationException]::new('The Terraform retry policy is invalid.')
        }
        try {
            $policy = ConvertFrom-AvmStrictJson -Json $json -RejectCaseInsensitiveDuplicates
            $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($rule in @($policy['fresh']) + @($policy['inPlace'])) {
                if (-not $ids.Add($rule['id'])) {
                    throw [System.ArgumentException]::new("Duplicate Terraform retry rule '$($rule['id'])'.")
                }
                foreach ($pattern in @($rule['anyOf']) + @($rule['allOf'])) {
                    if ($null -ne $pattern) { $null = [regex]::new($pattern) }
                }
            }
            $locationRules = @($policy['fresh'] | Where-Object { $_['id'] -ceq 'location-ineligible' -and $_['integration'] -and $_.Contains('allOf') })
            if ($locationRules.Count -ne 1) {
                throw [System.ArgumentException]::new('The location-ineligible rule must be a shared fresh all-match rule.')
            }
        }
        catch [System.ArgumentException] {
            throw [AvmConfigurationException]::new('The Terraform retry policy contains invalid JSON or a regular expression.', $_.Exception)
        }
        $script:AvmTerraformRetryPolicy = $policy
    }
    return $script:AvmTerraformRetryPolicy
}
