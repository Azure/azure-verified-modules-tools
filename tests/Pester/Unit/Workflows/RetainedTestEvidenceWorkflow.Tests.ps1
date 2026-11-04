#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:runnerPath = Join-Path $script:repoRoot 'scripts' 'bicep-workflows' 'Read-AvmRetainedTestEvidence.ps1'
    $script:runnerText = Get-Content -LiteralPath $script:runnerPath -Raw
    . $script:runnerPath
    $script:productionPolicy = Get-AvmRetainedEvidencePolicy
    $script:workflowText = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github' 'workflows' 'bicep-retained-test-evidence.yml') -Raw
    $module = Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -PassThru
    $null = & $module { Import-AvmPowerShellModule -Name powershell-yaml -Global }
    $script:workflow = ConvertFrom-Yaml -Yaml $script:workflowText

    function Get-AzContext {
        [CmdletBinding()]
        param()
        throw 'Tests must mock every Azure context read.'
    }

    function Invoke-AzRestMethod {
        [CmdletBinding()]
        param([string] $Method, [string] $Uri)
        throw 'Tests must mock every ARM request.'
    }

    function New-EvidenceFixture {
        $tenant = '11111111-1111-1111-1111-111111111111'
        $subscription = '22222222-2222-2222-2222-222222222222'
        $clients = @{}
        $gates = @(
            foreach ($index in 1..6) {
                $client = "33333333-3333-3333-3333-$($index.ToString('D12'))"
                $path = "avm/res/example/module-$index"
                $clients[$path] = $client
                @{ modulePath = $path; clientIdSha256 = Get-AvmEvidenceHash -Bytes ([Text.Encoding]::UTF8.GetBytes($client)) }
            }
        )
        $cases = @(
            foreach ($index in 1..11) {
                $root = "/subscriptions/$subscription/providers/Microsoft.Resources/deployments/test-$index"
                @{
                    jobId          = $index
                    artifactId     = 100 + $index
                    modulePath     = "avm/res/example/module-$([math]::Min($index, 5))"
                    tenantId       = $tenant
                    subscriptionId = $subscription
                    rootId         = $root
                    operationsId   = "$root/operations"
                }
            }
        )
        $scope = @{
            schemaVersion        = 1
            cases                = $cases
            mg                   = @{
                jobId          = 12
                artifactId     = 112
                modulePath     = 'avm/res/example/module-6'
                tenantId       = $tenant
                subscriptionId = $subscription
                parentId       = '/providers/Microsoft.Management/managementGroups/test-parent'
                childId        = '/providers/Microsoft.Management/managementGroups/test-child'
                deploymentId   = '/providers/Microsoft.Management/managementGroups/test-parent/providers/Microsoft.Resources/deployments/test-mg'
            }
            baseReadTargets      = 25
            additional73Admitted = $false
            originalRun          = 123
            attempt              = 1
            originalHead         = 'a' * 40
        }
        $scopeBytes = [Text.Encoding]::UTF8.GetBytes(($scope | ConvertTo-Json -Depth 16 -Compress))
        $identityBytes = [Text.Encoding]::UTF8.GetBytes((@{ identities = $gates } | ConvertTo-Json -Depth 8 -Compress))
        $bundle = @{
            schemaVersion              = 1
            profileId                  = $script:productionPolicy.ProfileId
            actualHistoricalSubject    = $script:productionPolicy.Subject
            baseReadTargets            = 25
            additional73ScopesAdmitted = $false
            scope                      = @{
                encoding = 'base64'
                length   = $scopeBytes.Length
                sha256   = Get-AvmEvidenceHash -Bytes $scopeBytes
                data     = [Convert]::ToBase64String($scopeBytes)
            }
            identityGates              = @{
                encoding = 'base64'
                length   = $identityBytes.Length
                sha256   = Get-AvmEvidenceHash -Bytes $identityBytes
                data     = [Convert]::ToBase64String($identityBytes)
            }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($bundle | ConvertTo-Json -Depth 8 -Compress))
        $policy = $script:productionPolicy.Clone()
        $policy.BundleSha256 = Get-AvmEvidenceHash -Bytes $bytes
        $policy.BundleLength = $bytes.Length
        $policy.ScopeSha256 = $bundle.scope.sha256
        $policy.IdentitySha256 = $bundle.identityGates.sha256
        return @{
            Policy       = $policy
            Scope        = $scope
            Identities   = @{ identities = $gates }
            Base64       = [Convert]::ToBase64String($bytes)
            Hash         = $policy.BundleSha256
            Clients      = $clients | ConvertTo-Json -Compress
            Tenant       = $tenant
            Subscription = $subscription
        }
    }
}

AfterAll {
    Remove-Module -Name Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Retained TEST diagnostic workflow' {
    It 'pins the independent scope authority and source bytes, outside the released package' {
        $script:productionPolicy.BundleSha256 | Should -BeExactly '25460d6003abebfe56288dadebf89e040f4f57f3698452909f3368b625a7e6c7'
        $script:productionPolicy.BundleLength | Should -Be 15052
        $script:productionPolicy.ScopeSha256 | Should -BeExactly 'b1c676e69fb26a59b033d0d89346f46dd6f530c56d8183f7e4aadb2ac374373d'
        $script:productionPolicy.IdentitySha256 | Should -BeExactly '8ccd551acfe8d6c87d2514716cf2ab85254138c4f3cd5ab5dd4dc0786cc1b987'
        $script:workflow.env.RUNNER_SHA256 | Should -BeExactly (Get-FileHash -LiteralPath $script:runnerPath).Hash.ToLowerInvariant()
        $script:runnerPath | Should -Not -Match '[\\/]src[\\/]Avm.Authoring[\\/]'
    }

    It 'has only admission and serialized read jobs with the original TEST environment' {
        @($script:workflow['on'].Keys) | Should -Be @('workflow_call')
        @($script:workflow.jobs.Keys | Sort-Object) | Should -Be @('admit', 'observe')
        $script:workflow.permissions.Count | Should -Be 0
        $script:workflow.jobs.admit.permissions.Count | Should -Be 1
        $script:workflow.jobs.admit.permissions.contents | Should -BeExactly 'read'
        $script:workflow.jobs.observe.permissions['id-token'] | Should -BeExactly 'write'
        $script:workflow.jobs.observe.strategy['max-parallel'] | Should -Be 1
        $script:workflow.jobs.observe.strategy['fail-fast'] | Should -BeFalse
        $script:workflow.jobs.observe.needs | Should -BeExactly 'admit'
        $script:workflow.concurrency['cancel-in-progress'] | Should -BeFalse
        foreach ($job in $script:workflow.jobs.Values) {
            $job.environment | Should -BeExactly 'avm-validation'
            $job['timeout-minutes'] | Should -BeLessOrEqual 10
        }
        @($script:workflow['on'].workflow_call.secrets.Keys) | Should -Be @('VALIDATE_TENANT_ID')
    }

    It 'checks out only the fixed tools source and never executes caller code' {
        foreach ($job in $script:workflow.jobs.Values) {
            $checkout = @($job.steps | Where-Object { $_.Contains('uses') -and $_.uses -like 'actions/checkout@*' })
            $checkout.Count | Should -Be 1
            $checkout[0].with.repository | Should -BeExactly 'Azure/azure-verified-modules-tools'
            $checkout[0].with.ref | Should -BeExactly '${{ inputs.tools-ref }}'
            $checkout[0].with['persist-credentials'] | Should -BeFalse
            $checkout[0].with['sparse-checkout'] | Should -BeExactly 'scripts/bicep-workflows/Read-AvmRetainedTestEvidence.ps1'
        }
        foreach ($step in @($script:workflow.jobs.admit.steps) + @($script:workflow.jobs.observe.steps)) {
            if ($step.Contains('uses')) {
                $step.uses | Should -Match '@[0-9a-f]{40}$'
            }
        }
        $script:workflowText | Should -Not -Match 'secrets: inherit|toJSON\(secrets\)|VALIDATE_CLIENT_ID|Install-Module|Install-PSResource|Avm\.Authoring|Common\.ps1|runE2E: true'
    }

    It 'revalidates both source bindings and the bundle before login and preserves failure evidence' {
        $steps = $script:workflow.jobs.observe.steps
        $steps[1].id | Should -BeExactly 'identity'
        $steps[1].run | Should -Match 'Get-FileHash'
        $steps[1].run | Should -Match 'ReadAllText'
        $steps[1].run | Should -Match 'Get-AvmRetainedEvidenceAdmission'
        $steps[2].id | Should -BeExactly 'login'
        $steps[2].with['enable-AzPSSession'] | Should -BeTrue
        $steps[2].with['client-id'] | Should -BeExactly '${{ steps.identity.outputs.clientId }}'
        $steps[3]['if'] | Should -Match '!cancelled\(\)'
        $steps[3].run | Should -Match 'AuthenticationSucceeded'
        $steps[4].with['if-no-files-found'] | Should -BeExactly 'error'
        $steps[4].with.path | Should -Not -Match 'logs|\.avm-tools|\*\*'
    }

    It 'uses an explicit complete cloud command allowlist and one constant GET boundary' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:runnerPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $commands = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst]
                }, $true))
        $cloudCommands = @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-Az' } | Sort-Object -Unique)
        $cloudCommands | Should -Be @('Get-AzContext', 'Invoke-AzRestMethod')
        $localFunctions = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst]
                }, $true).Name)
        $allowedCommands = $localFunctions + @('ConvertFrom-Json', 'ConvertTo-Json', 'Where-Object',
            'Select-Object', 'Write-Output', 'Split-Path', 'New-Item', 'Get-AzContext', 'Invoke-AzRestMethod')
        foreach ($command in $commands) {
            $command.GetCommandName() | Should -BeIn $allowedCommands
        }
        $requests = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-AzRestMethod' })
        $requests.Count | Should -Be 1
        $requests[0].Extent.Text | Should -BeExactly 'Invoke-AzRestMethod -Method GET -Uri $uri -ErrorAction Stop'
        $script:runnerText | Should -Not -Match '\b(Invoke-Expression|Invoke-WebRequest|Invoke-RestMethod|Get-AzAccessToken|Start-Process|Connect-Az|Set-AzContext|Register-Az|Remove-Az|New-Az|Complete-)'
    }
}

Describe 'Digest-admitted retained TEST observations' {
    BeforeEach {
        $script:fixture = New-EvidenceFixture
        Mock Get-AvmRetainedEvidencePolicy { $script:fixture.Policy }
        $script:capturedResult = $null
        Mock Write-AvmRetainedEvidenceResult { param($Result) $script:capturedResult = $Result }
        $script:admissionParameters = @{
            BundleBase64      = $script:fixture.Base64
            BundleSha256      = $script:fixture.Hash
            ExpectedCommit    = 'a' * 40
            CallerCommit      = 'a' * 40
            CallerRepository  = 'Azure/bicep-registry-modules'
            CallerEvent       = 'workflow_dispatch'
            ToolsRef          = 'b' * 40
            ToolsCommit       = 'b' * 40
            DiagnosticEnabled = $true
            RunE2E            = $false
            ModuleClientIds   = $script:fixture.Clients
            TenantId          = $script:fixture.Tenant
        }
        $script:readParameters = @{
            BundleBase64            = $script:fixture.Base64
            BundleSha256            = $script:fixture.Hash
            CaseKey                 = 'case-1'
            ModuleClientIds         = $script:fixture.Clients
            TenantId                = $script:fixture.Tenant
            OutputPath              = 'unused'
            AuthenticationSucceeded = $true
        }
        $script:activeClient = '33333333-3333-3333-3333-000000000001'
        Mock Get-AzContext {
            @{
                Tenant       = @{ Id = $script:fixture.Tenant }
                Subscription = @{ Id = $script:fixture.Subscription }
                Account      = @{ Id = $script:activeClient; Type = 'ServicePrincipal' }
                Environment  = @{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
            }
        }
        Mock Invoke-AzRestMethod {
            param($Method, $Uri)
            if ($Method -cne 'GET') { throw 'Non-GET test request.' }
            $id = ([uri]$Uri).AbsolutePath
            if ($id.EndsWith('/operations')) {
                $body = @{
                    value = @(@{
                            operationId = '01234567'
                            properties  = @{
                                provisioningState = 'Succeeded'
                                targetResource    = @{ id = "/subscriptions/$($script:fixture.Subscription)/resourceGroups/test-group" }
                                statusMessage     = 'PRIVATE-UNTRUSTED'
                            }
                        })
                }
            }
            elseif ($id -notmatch '/deployments/') {
                $body = @{
                    id         = $id
                    properties = @{
                        tenantId = $script:fixture.Tenant
                        details  = @{ parent = @{ id = $script:fixture.Scope.mg.parentId } }
                        children = @(@{ id = $script:fixture.Scope.mg.childId; displayName = 'PRIVATE-UNTRUSTED' })
                    }
                }
            }
            else {
                $body = @{ id = $id; properties = @{ provisioningState = 'Succeeded'; outputs = @{ secret = 'PRIVATE-UNTRUSTED' } } }
            }
            @{ StatusCode = 200; Content = $body | ConvertTo-Json -Depth 16 -Compress }
        }
    }

    It 'admits exactly twelve legs and observes all twenty-five base targets using GET only' {
        $admission = Get-AvmRetainedEvidenceAdmission @script:admissionParameters
        $admission.Matrix.include.Count | Should -Be 12
        foreach ($leg in $admission.Matrix.include) {
            $selection = Get-AvmRetainedEvidenceSelection -Bundle $admission.Bundle -CaseKey $leg.caseKey `
                -ModuleClientIds $script:fixture.Clients -TenantId $script:fixture.Tenant
            $script:activeClient = $selection.ClientId
            $script:readParameters.CaseKey = $leg.caseKey
            $result = Invoke-AvmRetainedEvidenceRead @script:readParameters
            $result.status | Should -BeExactly 'Observed'
            $result.requests.Count | Should -Be $selection.Targets.Count
            ($result | ConvertTo-Json -Depth 16) | Should -Not -Match 'PRIVATE-UNTRUSTED|statusMessage|displayName|outputs|nextLink|token'
        }
        Should -Invoke Invoke-AzRestMethod -Times 25 -Exactly -ParameterFilter { $Method -ceq 'GET' }
        Should -Invoke Get-AzContext -Times 25 -Exactly
    }

    It 'rejects changed admission field <Field>' -ForEach @(
        @{ Field = 'CallerRepository'; Value = 'other/repository' }
        @{ Field = 'CallerEvent'; Value = 'pull_request' }
        @{ Field = 'ExpectedCommit'; Value = 'c' * 40 }
        @{ Field = 'CallerCommit'; Value = 'c' * 40 }
        @{ Field = 'ToolsRef'; Value = 'main' }
        @{ Field = 'ToolsCommit'; Value = 'c' * 40 }
        @{ Field = 'DiagnosticEnabled'; Value = $false }
        @{ Field = 'RunE2E'; Value = $true }
        @{ Field = 'TenantId'; Value = '44444444-4444-4444-4444-444444444444' }
    ) {
        $script:admissionParameters[$Field] = $Value
        { Get-AvmRetainedEvidenceAdmission @script:admissionParameters } | Should -Throw
        Should -Invoke Invoke-AzRestMethod -Times 0
    }

    It 'rejects caller replacement of both payload and claimed hash' {
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"changed":true}')
        { Get-AvmRetainedEvidenceBundle -BundleBase64 ([Convert]::ToBase64String($bytes)) `
                -BundleSha256 (Get-AvmEvidenceHash -Bytes $bytes) } | Should -Throw '*tools-owned*'
    }

    It 'rejects tampered bytes, invalid encoding, duplicate fields and oversized JSON' {
        { ConvertFrom-AvmEvidencePayload -Base64 'e30=' -ExpectedSha256 ('0' * 64) } | Should -Throw
        { ConvertFrom-AvmEvidencePayload -Base64 'not-base64' -ExpectedSha256 ('0' * 64) } | Should -Throw
        { ConvertFrom-AvmEvidencePayload -Base64 "e30= `n" -ExpectedSha256 (Get-AvmEvidenceHash -Bytes ([Text.Encoding]::UTF8.GetBytes('{}'))) } | Should -Throw
        { ConvertFrom-AvmEvidenceJson -Text '{"a":1,"A":2}' } | Should -Throw
        { ConvertFrom-AvmEvidenceJson -Text '{"nested":{"a":1,"a":2}}' } | Should -Throw
        { ConvertFrom-AvmEvidenceJson -Text (' ' * 65537) } | Should -Throw
    }

    It 'rejects inner tampering even when a test authority re-signs only the outer envelope' {
        $outer = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:fixture.Base64)) | ConvertFrom-Json -AsHashtable
        $outer.scope.data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
        $bytes = [Text.Encoding]::UTF8.GetBytes(($outer | ConvertTo-Json -Depth 16 -Compress))
        $script:fixture.Policy.BundleSha256 = Get-AvmEvidenceHash -Bytes $bytes
        $script:fixture.Policy.BundleLength = $bytes.Length
        { Get-AvmRetainedEvidenceBundle -BundleBase64 ([Convert]::ToBase64String($bytes)) -BundleSha256 $script:fixture.Policy.BundleSha256 } | Should -Throw
    }

    It 'rejects unadmitted legs and missing, generic or changed identity mappings' {
        $bundle = Get-AvmRetainedEvidenceBundle -BundleBase64 $script:fixture.Base64 -BundleSha256 $script:fixture.Hash
        { Get-AvmRetainedEvidenceSelection -Bundle $bundle -CaseKey 'case-73' -ModuleClientIds $script:fixture.Clients -TenantId $script:fixture.Tenant } | Should -Throw
        foreach ($map in @('{}', '{"VALIDATE_CLIENT_ID":"33333333-3333-3333-3333-000000000001"}',
                '{"avm/res/example/module-1":"44444444-4444-4444-4444-444444444444"}')) {
            { Get-AvmRetainedEvidenceSelection -Bundle $bundle -CaseKey 'case-1' -ModuleClientIds $map -TenantId $script:fixture.Tenant } | Should -Throw
        }
    }

    It 'blocks missing or changed Azure context before any request' -ForEach @(
        @{ Context = 'missing' }
        @{ Context = 'tenant' }
        @{ Context = 'subscription' }
        @{ Context = 'principal' }
        @{ Context = 'cloud' }
    ) {
        $script:wrongContext = $Context
        Mock Get-AzContext {
            if ($script:wrongContext -eq 'missing') { return $null }
            @{
                Tenant       = @{ Id = if ($script:wrongContext -eq 'tenant') { '44444444-4444-4444-4444-444444444444' } else { $script:fixture.Tenant } }
                Subscription = @{ Id = if ($script:wrongContext -eq 'subscription') { '44444444-4444-4444-4444-444444444444' } else { $script:fixture.Subscription } }
                Account      = @{ Id = if ($script:wrongContext -eq 'principal') { '44444444-4444-4444-4444-444444444444' } else { $script:activeClient }; Type = 'ServicePrincipal' }
                Environment  = @{ Name = if ($script:wrongContext -eq 'cloud') { 'OtherCloud' } else { 'AzureCloud' }; ResourceManagerUrl = 'https://management.azure.com/' }
            }
        }
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw '*incomplete*'
        $script:capturedResult.status | Should -BeExactly 'Blocked'
        Should -Invoke Invoke-AzRestMethod -Times 0
        Should -Invoke Write-AvmRetainedEvidenceResult -Times 1 -Exactly
    }

    It 'retains a failed OIDC admission without accessing or repairing Azure context' {
        $script:readParameters.AuthenticationSucceeded = $false
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw
        $script:capturedResult.status | Should -BeExactly 'Blocked'
        Should -Invoke Get-AzContext -Times 0
        Should -Invoke Invoke-AzRestMethod -Times 0
    }

    It 'stops after HTTP <Status> without retry or context fallback' -ForEach @(
        @{ Status = 401 }
        @{ Status = 403 }
        @{ Status = 429 }
        @{ Status = 500 }
    ) {
        $script:httpStatus = $Status
        Mock Invoke-AzRestMethod { @{ StatusCode = $script:httpStatus; Content = 'PRIVATE-UNTRUSTED' } }
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw
        $script:capturedResult.status | Should -BeExactly 'Partial'
        $script:capturedResult.requests[0].httpStatus | Should -Be $Status
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly
        Should -Invoke Get-AzContext -Times 1 -Exactly
        ($script:capturedResult | ConvertTo-Json -Depth 16) | Should -Not -Match 'PRIVATE-UNTRUSTED'
    }

    It 'reports requested record 404s independently without claiming resource or cleanup absence' {
        Mock Invoke-AzRestMethod { @{ StatusCode = 404; Content = 'PRIVATE-UNTRUSTED' } }
        $result = Invoke-AvmRetainedEvidenceRead @script:readParameters
        $result.status | Should -BeExactly 'Observed'
        @($result.requests.outcome) | Should -Be @('RecordAbsent', 'RecordAbsent')
        $result.limitations | Should -Match 'no resource absence'
        Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly
    }

    It 'rejects a pagination escape <Next>' -ForEach @(
        @{ Next = 'http://management.azure.com/PLACEHOLDER?api-version=2025-04-01' }
        @{ Next = 'https://evil.example/PLACEHOLDER?api-version=2025-04-01' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER/../other?api-version=2025-04-01' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER%2fother?api-version=2025-04-01' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER?api-version=2025-04-01&token=secret' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER?api-version=2025-04-01&api-version=2025-04-01' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER?api-version=2024-01-01' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER?$skiptoken=abc' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER?api-version=2025-04-01#fragment' }
        @{ Next = 'https://management.azure.com/PLACEHOLDER?api-version=2025-04-01&$recurse=true' }
    ) {
        $target = @{ Id = $script:fixture.Scope.cases[0].operationsId; Kind = 'Operations'; ApiVersion = '2025-04-01' }
        $link = $Next.Replace('/PLACEHOLDER', $target.Id)
        { Get-AvmRetainedEvidenceUri -Target $target -NextLink $link } | Should -Throw
    }

    It 'accepts same-root bounded continuation and fails explicitly at its page limit' {
        $script:pageNumber = 0
        Mock Invoke-AzRestMethod {
            param($Uri)
            $id = ([uri]$Uri).AbsolutePath
            if ($id.EndsWith('/operations')) {
                $script:pageNumber++
                $content = @{ value = @(); nextLink = "https://management.azure.com${id}?api-version=2025-04-01&`$skiptoken=$script:pageNumber" }
            }
            else {
                $content = @{ id = $id; properties = @{ provisioningState = 'Succeeded' } }
            }
            @{ StatusCode = 200; Content = $content | ConvertTo-Json -Depth 8 -Compress }
        }
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw
        $script:capturedResult.requests.Count | Should -Be 6
        $script:capturedResult.requests[-1].outcome | Should -BeExactly 'Truncated'
        $script:capturedResult.status | Should -BeExactly 'Partial'
        Should -Invoke Invoke-AzRestMethod -Times 6 -Exactly
    }

    It 'fails closed on a malformed successful response while retaining earlier requests' {
        Mock Invoke-AzRestMethod { @{ StatusCode = 200; Content = '{"id":"foreign","properties":{"provisioningState":"Succeeded"}}' } }
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw
        $script:capturedResult.requests.Count | Should -Be 1
        $script:capturedResult.requests[0].outcome | Should -BeExactly 'Error'
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly
    }

    It 'revalidates the actual context between root and operations without switching it' {
        $script:contextReads = 0
        Mock Get-AzContext {
            $script:contextReads++
            @{
                Tenant       = @{ Id = $script:fixture.Tenant }
                Subscription = @{ Id = if ($script:contextReads -gt 1) { '44444444-4444-4444-4444-444444444444' } else { $script:fixture.Subscription } }
                Account      = @{ Id = $script:activeClient; Type = 'ServicePrincipal' }
                Environment  = @{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/' }
            }
        }
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly
        $script:capturedResult.failure.stage | Should -BeExactly 'context-admission'
        $script:capturedResult.context.subscriptionId | Should -BeExactly '44444444-4444-4444-4444-444444444444'
    }

    It 'does not follow a foreign continuation returned by ARM' {
        Mock Invoke-AzRestMethod {
            param($Uri)
            $id = ([uri]$Uri).AbsolutePath
            $body = if ($id.EndsWith('/operations')) {
                @{ value = @(); nextLink = 'https://evil.example/?token=PRIVATE-UNTRUSTED' }
            }
            else {
                @{ id = $id; properties = @{ provisioningState = 'Succeeded' } }
            }
            @{ StatusCode = 200; Content = $body | ConvertTo-Json -Depth 8 -Compress }
        }
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw
        Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly
        $script:capturedResult.failure.stage | Should -BeExactly 'endpoint-admission'
        ($script:capturedResult | ConvertTo-Json -Depth 16) | Should -Not -Match 'evil.example|PRIVATE-UNTRUSTED'
    }

    It 'retains a successful second operations page without leaking its continuation token' {
        $script:pageNumber = 0
        Mock Invoke-AzRestMethod {
            param($Uri)
            $id = ([uri]$Uri).AbsolutePath
            if ($id.EndsWith('/operations')) {
                $script:pageNumber++
                $body = @{ value = @() }
                if ($script:pageNumber -eq 1) {
                    $body.nextLink = "https://management.azure.com${id}?api-version=2025-04-01&`$skiptoken=PRIVATE-UNTRUSTED"
                }
            }
            else {
                $body = @{ id = $id; properties = @{ provisioningState = 'Succeeded' } }
            }
            @{ StatusCode = 200; Content = $body | ConvertTo-Json -Depth 8 -Compress }
        }
        $result = Invoke-AvmRetainedEvidenceRead @script:readParameters
        $result.requests.Count | Should -Be 3
        $result.status | Should -BeExactly 'Observed'
        ($result | ConvertTo-Json -Depth 16) | Should -Not -Match 'PRIVATE-UNTRUSTED'
        Should -Invoke Invoke-AzRestMethod -Times 3 -Exactly
    }

    It 'rejects repeated pages without another ARM request' {
        Mock Invoke-AzRestMethod {
            param($Uri)
            $id = ([uri]$Uri).AbsolutePath
            $body = if ($id.EndsWith('/operations')) {
                @{ value = @(); nextLink = $Uri }
            }
            else {
                @{ id = $id; properties = @{ provisioningState = 'Succeeded' } }
            }
            @{ StatusCode = 200; Content = $body | ConvertTo-Json -Depth 8 -Compress }
        }
        { Invoke-AvmRetainedEvidenceRead @script:readParameters } | Should -Throw
        Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly
    }

    It 'preserves bounded management-group hierarchy observations without recursion' {
        $script:readParameters.CaseKey = 'mg-12'
        $script:activeClient = '33333333-3333-3333-3333-000000000006'
        $result = Invoke-AvmRetainedEvidenceRead @script:readParameters
        $result.requests.Count | Should -Be 3
        $result.requests[0].observations[0].expectedChildListed | Should -BeTrue
        $result.requests[1].observations[0].parentId | Should -BeExactly $script:fixture.Scope.mg.parentId
        Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly -ParameterFilter { $Uri -like '*&$expand=children' }
        Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Uri -match 'recurse' }
    }

    It 'keeps output writing local and emits only exact JSON and digest sidecar paths' {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:runnerPath, [ref]$tokens, [ref]$errors)
        $writer = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq 'Write-AvmRetainedEvidenceResult'
            }, $true)
        $writer.Extent.Text | Should -Match '\[IO.File\]::WriteAllText\(\$OutputPath,'
        $writer.Extent.Text | Should -Match '\[IO.File\]::WriteAllText\("\$OutputPath.sha256",'
        $writer.Extent.Text | Should -Not -Match '-Az|Invoke-|https://'
    }
}
