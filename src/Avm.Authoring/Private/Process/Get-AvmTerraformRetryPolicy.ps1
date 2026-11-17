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
            foreach ($pattern in @($policy['sharedMessagePatterns']) + @($policy['locationIneligiblePatterns']) + @($policy['e2eAllMessagePatterns'])) {
                $null = [regex]::new($pattern)
            }
        }
        catch [System.ArgumentException] {
            throw [AvmConfigurationException]::new('The Terraform retry policy contains invalid JSON or a regular expression.', $_.Exception)
        }
        $script:AvmTerraformRetryPolicy = $policy
    }
    return $script:AvmTerraformRetryPolicy
}
