BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:inspector = Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'Test-RepositoryStateTransfer.ps1'
    . (Join-Path $script:root 'tests' 'fixtures' 'RepositoryState.ps1')
}

Describe 'Repository state transfer local inspection' -Tag Component {
    BeforeEach {
        $script:pair = New-AvmTestRepositoryStatePair
        $script:beforeSource = $script:pair.Source
        $script:beforeDestination = $script:pair.Destination
        $script:afterSource = $script:beforeSource | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $script:afterDestination = $script:beforeDestination | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $script:afterSource.resources = @()
        $script:afterSource.serial++
        $script:afterDestination.serial++
        $script:afterSource.check_results = @(@{
            object_kind = 'var'; config_addr = 'var.repository'; status = 'unknown'; objects = @()
        })
        foreach ($resource in ($script:beforeSource | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable).resources) {
            $resource.module = 'module.bami[0]'
            $script:afterDestination.resources += $resource
        }
        foreach ($resource in $script:afterDestination.resources) {
            foreach ($instance in $resource.instances) {
                $null = $instance.Remove('dependencies')
                $instance.identity_schema_version = 0
            }
        }
        $script:paths = @{
            SourceBefore = Join-Path $TestDrive 'source-before.tfstate'
            DestinationBefore = Join-Path $TestDrive 'destination-before.tfstate'
            SourceAfter = Join-Path $TestDrive 'source-after.tfstate'
            DestinationAfter = Join-Path $TestDrive 'destination-after.tfstate'
        }
        function Invoke-StateInspectionFixture {
            $script:beforeSource | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:paths.SourceBefore -Encoding utf8NoBOM
            $script:beforeDestination | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:paths.DestinationBefore -Encoding utf8NoBOM
            $script:afterSource | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:paths.SourceAfter -Encoding utf8NoBOM
            $script:afterDestination | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $script:paths.DestinationAfter -Encoding utf8NoBOM
            $hashes = @{}
            foreach ($path in $script:paths.Values) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
            try {
                & $script:inspector @script:paths -Repository $script:pair.Repository -Identity $script:pair.Identity `
                    -SourceSha256 $hashes[$script:paths.SourceBefore] -DestinationSha256 $hashes[$script:paths.DestinationBefore]
            }
            finally {
                foreach ($path in $script:paths.Values) { (Get-FileHash -LiteralPath $path).Hash | Should -Be $hashes[$path] }
            }
        }
    }

    It 'verifies preserved GitHub, old-tenant, BAMI, legacy permission, private, and output state without writing' {
        $result = Invoke-StateInspectionFixture
        @($result) | Should -HaveCount 1
        $result.ResourceBlocks | Should -Be 6
        $result.SourceSerial | Should -Be 6
        $result.DestinationSerial | Should -Be 10
        $result.Status | Should -Match 'cutover.*not approved'
    }

    It 'ignores recomputable snapshot bookkeeping: <Case>' -ForEach @(
        @{ Case = 'omitted checks' }, @{ Case = 'added checks' }, @{ Case = 'cleared checks' }
        @{ Case = 'reordered checks' }, @{ Case = 'changed results' }
        @{ Case = 'writer version' }, @{ Case = 'omitted writer version' }
    ) {
        $checks = @(
            @{ object_kind = 'var'; config_addr = 'var.repository'; status = 'pass'; objects = @(@{ object_addr = 'var.repository'; status = 'pass' }) }
            @{ object_kind = 'check'; config_addr = 'check.repository'; status = 'pass'; objects = @(@{ object_addr = 'check.repository'; status = 'pass' }) }
        )
        $script:beforeSource.check_results = $checks
        $script:afterSource.check_results = ConvertFrom-Json (ConvertTo-Json -InputObject $checks -Depth 10) -AsHashtable
        switch ($Case) {
            'omitted checks' { $null = $script:afterSource.Remove('check_results') }
            'added checks' { $null = $script:beforeSource.Remove('check_results') }
            'cleared checks' { $script:afterSource.check_results = $null }
            'reordered checks' { [array]::Reverse($script:afterSource.check_results) }
            'changed results' { $script:afterSource.check_results[0].status = 'unknown' }
            'writer version' { $script:afterSource.terraform_version = '1.15.8' }
            'omitted writer version' { $null = $script:beforeSource.Remove('terraform_version') }
        }
        (Invoke-StateInspectionFixture).ResourceBlocks | Should -Be 6
    }

    It 'rejects wrong frozen identity values: <Field>' -ForEach @(
        @{ Field = 'tenant_id' }, @{ Field = 'client_id' }, @{ Field = 'principal_id' }
    ) {
        $script:pair.Identity[$Field] = '90000000-0000-4000-8000-000000000001'
        { Invoke-StateInspectionFixture } | Should -Throw '*Source identity IDs or tenant*'
    }

    It 'rejects a different selected repository or GitHub ID: <Field>' -ForEach @(
        @{ Field = 'repository_id' }, @{ Field = 'repository_owner_id' }, @{ Field = 'repository' }
    ) {
        if ($Field -ceq 'repository') { $script:pair.Repository = $script:pair.Repository.Replace('example-repo', 'another-repo') }
        else { $script:pair.Identity[$Field] = '9876' }
        { Invoke-StateInspectionFixture } | Should -Throw
    }

    It 'rejects every unexpected change in a staged image: <Case>' -ForEach @(
        @{ Case = 'private data' }, @{ Case = 'sensitive paths' }, @{ Case = 'live attributes' }
        @{ Case = 'provider' }, @{ Case = 'lineage' }, @{ Case = 'serial' }, @{ Case = 'missing permission' }
        @{ Case = 'source still owned' }, @{ Case = 'source output lost' }, @{ Case = 'destination output lost' }
        @{ Case = 'extra state address' }, @{ Case = 'duplicate state address' }, @{ Case = 'schema version' }
        @{ Case = 'unknown snapshot field lost' }
    ) {
        switch ($Case) {
            'private data' { $script:afterDestination.resources[2].instances[0].private = 'bG9zdA==' }
            'sensitive paths' { $script:afterDestination.resources[2].instances[0].sensitive_attributes = @() }
            'live attributes' { $script:afterDestination.resources[2].instances[0].attributes.id += '-changed' }
            'provider' { $script:afterDestination.resources[2].provider += '.wrong' }
            'lineage' { $script:afterSource.lineage = '90000000-0000-4000-8000-000000000001' }
            'serial' { $script:afterDestination.serial++ }
            'missing permission' { $script:afterDestination.resources = @($script:afterDestination.resources | Where-Object { $_.name -cne 'example' }) }
            'source still owned' { $script:afterSource.resources = @($script:beforeSource.resources[0]) }
            'source output lost' { $null = $script:afterSource.outputs.Remove('preserved_private_output') }
            'destination output lost' { $script:afterDestination.outputs = @{} }
            'extra state address' { $script:afterDestination.resources[2].module = 'module.extra' }
            'duplicate state address' { $script:afterDestination.resources[3] = $script:afterDestination.resources[2] }
            'schema version' { $script:afterSource.version = 3 }
            'unknown snapshot field lost' { $script:beforeSource['preserved_extension'] = @{ value = 'must-not-disappear' } }
        }
        { Invoke-StateInspectionFixture } | Should -Throw
    }

    It 'rejects ambiguous or interrupted original ownership: <Case>' -ForEach @(
        @{ Case = 'already drained' }, @{ Case = 'partial destination' }, @{ Case = 'duplicate live identity' }
        @{ Case = 'alias provider' }, @{ Case = 'deposed' }, @{ Case = 'tainted' }, @{ Case = 'same lineage' }
        @{ Case = 'partial source outputs' }, @{ Case = 'foreign membership' }
    ) {
        switch ($Case) {
            'already drained' { $script:beforeSource.resources = @() }
            'partial destination' { $script:beforeDestination.resources += $script:afterDestination.resources[2] }
            'duplicate live identity' { $script:beforeDestination.resources[1].instances[0].attributes.id = $script:pair.Identity.identity_resource_id }
            'alias provider' { $script:beforeSource.resources[0].provider += '.legacy' }
            'deposed' { $script:beforeSource.resources[0].instances[0].deposed = 'deadbeef' }
            'tainted' { $script:beforeSource.resources[0].instances[0].status = 'tainted' }
            'same lineage' { $script:beforeDestination.lineage = $script:beforeSource.lineage }
            'partial source outputs' { $script:beforeSource.outputs = @{} }
            'foreign membership' { $script:beforeSource.resources[2].instances[0].attributes.member_object_id = '90000000-0000-4000-8000-000000000001' }
        }
        { Invoke-StateInspectionFixture } | Should -Throw
    }

    It 'rejects originals that no longer match their externally recorded hash' {
        $null = Invoke-StateInspectionFixture
        { & $script:inspector @script:paths -Repository $script:pair.Repository -Identity $script:pair.Identity `
                -SourceSha256 ('a' * 64) -DestinationSha256 (Get-FileHash -LiteralPath $script:paths.DestinationBefore).Hash } |
            Should -Throw '*frozen inventory hash*'
    }

    It 'rejects legacy and desired addresses owning the same membership in <Location>' -ForEach @(
        @{ Location = 'source' }, @{ Location = 'destination' }
    ) {
        $duplicate = $script:beforeSource.resources[2] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        if ($Location -ceq 'source') {
            $duplicate.name = 'test_permissions'
            $duplicate.instances[0].index_key = 'avm-test-entra-readers'
            $script:beforeSource.resources += $duplicate
        } else {
            $duplicate.module = 'module.azure[0]'
            $script:beforeDestination.resources += $duplicate
        }
        { Invoke-StateInspectionFixture } | Should -Throw '*same managed object*'
    }
}
