BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
    . (Join-Path $script:root 'repository-management' 'repository-sync' 'scripts' 'lib' 'RepositoryCandidate.ps1')
}

Describe 'Repository candidate original identity' -Tag Component {
    BeforeAll {
        function Assert-TestCandidateIdentity {
            param([string]$Path)

            $type = & (Get-Module Avm.Authoring) {
                param($Root)
                Get-AvmMetadataModuleType -Context ([pscustomobject]@{ Root = $Root; Ecosystem = 'terraform' }) `
                    -Path $Root -Metadata @{ canonicalType = 'module'; telemetryIdPrefix = '46d3xtrf.0123456.v1' }
            } $Path
            $type | Should -BeExactly $script:expectedModuleType
            (Invoke-RepositoryGit -WorkingDirectory $Path -Arguments @('config', '--get', 'remote.origin.url')) |
                Should -BeExactly $script:expectedRemote
            $script:validatedPaths.Add($Path)
        }
    }

    It 'preserves <ModuleType> identity in both temporary checkouts' -TestCases @(
        @{ Provider = 'azurerm'; Kind = 'res'; ModuleType = 'resource' }
        @{ Provider = 'azure'; Kind = 'ptn'; ModuleType = 'pattern' }
        @{ Provider = 'azapi'; Kind = 'utl'; ModuleType = 'utility' }
    ) {
        param($Provider, $Kind, $ModuleType)

        $repository = "Azure/terraform-$Provider-avm-$Kind-example"
        $script:expectedRemote = "https://github.com/$repository.git"
        $script:expectedModuleType = $ModuleType
        $script:validatedPaths = [System.Collections.Generic.List[string]]::new()
        $caseRoot = Join-Path $TestDrive $Kind
        $original = Join-Path $caseRoot 'original'
        $candidate = Join-Path $caseRoot 'candidate'
        $receipt = Join-Path $caseRoot 'receipt'
        $null = New-Item -ItemType Directory -Path $original, $candidate
        $null = Invoke-RepositoryGit -WorkingDirectory $TestDrive -Arguments @('init', '--quiet', '-b', 'main', $original)
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('config', '--local', 'core.autocrlf', 'false')
        [System.IO.File]::WriteAllText((Join-Path $original 'main.tf'), "variable `"name`" {}`n")
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('add', '--all')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            '-c', 'user.name=AVM test', '-c', 'user.email=avm-test@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Base')
        $baseSha = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('rev-parse', 'HEAD')
        [System.IO.File]::WriteAllText((Join-Path $original 'main.tf'), "variable `"name`" { type = string }`n")
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('add', '--all')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            '-c', 'user.name=AVM test', '-c', 'user.email=avm-test@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Candidate')
        $headSha = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('rev-parse', 'HEAD')
        $treeSha = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('rev-parse', 'HEAD^{tree}')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            'archive', '--format=tar', "--output=$(Join-Path $candidate 'candidate.tar')", 'HEAD')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            'diff', '--binary', '--full-index', '--no-renames',
            "--output=$(Join-Path $candidate 'candidate.patch')", $baseSha, 'HEAD')
        $manifest = @{
            schemaVersion = 1
            repository = $repository
            phase = 'prepared'
            defaultBranch = 'main'
            baseSha = $baseSha
            hasChanges = $true
            planOnly = $true
            headSha = $headSha
            treeSha = $treeSha
            changedPaths = @('main.tf')
            authoringSource = 'checkout'
            authoringVersion = '0.0.0'
        }
        [System.IO.File]::WriteAllText((Join-Path $candidate 'candidate.json'), ($manifest | ConvertTo-Json -Depth 6))
        $settings = @{
            tenantId = '11111111-1111-4111-8111-111111111111'
            clientId = '22222222-2222-4222-8222-222222222222'
            subscriptions = @(@{ name = 'test'; id = '33333333-3333-4333-8333-333333333333' })
        }
        [System.IO.File]::WriteAllText((Join-Path $candidate 'test-settings.json'), ($settings | ConvertTo-Json -Depth 6))
        Mock Invoke-AvmPrCheck {
            Assert-TestCandidateIdentity -Path $Path
            [pscustomobject]@{ Status = 'pass'; Steps = @() }
        }
        Mock Invoke-AvmTestUnit {
            Assert-TestCandidateIdentity -Path $Path
            [pscustomobject]@{ Status = 'pass' }
        }

        $result = Invoke-RepositorySyncCandidateValidation -Repository $repository `
            -CandidateDirectory $candidate -ReceiptDirectory $receipt `
            -CheckoutModulePath (Join-Path $script:root 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')

        $result | Should -BeExactly 'Passed'
        $script:validatedPaths | Should -HaveCount 2
        Assert-RepositorySyncValidationReceipt -Candidate $manifest -Directory $receipt
    }
}

Describe 'Repository candidate archive and patch' -Tag Component {
    It 'rehydrates and reapplies exact committed <LineEnding> bytes without a remote repository' -TestCases @(
        @{ LineEnding = 'LF' }
        @{ LineEnding = 'CRLF' }
    ) {
        param($LineEnding)

        $caseRoot = Join-Path $TestDrive $LineEnding
        $original = Join-Path $caseRoot 'original'
        $candidate = Join-Path $caseRoot 'candidate'
        $validation = Join-Path $caseRoot 'validation'
        $publication = Join-Path $caseRoot 'publication'
        $unit = Join-Path $caseRoot 'unit'
        $null = New-Item -ItemType Directory -Path $original, $candidate, $validation
        $null = Invoke-RepositoryGit -WorkingDirectory $TestDrive -Arguments @('init', '--quiet', '-b', 'main', $original)
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('config', '--local', 'core.autocrlf', 'false')
        [System.IO.File]::WriteAllText((Join-Path $original '.gitattributes'), "* text=auto eol=lf`n")
        [System.IO.File]::WriteAllText((Join-Path $original 'main.tf'), "variable `"name`" {}`n")
        $ignored = if ($LineEnding -eq 'CRLF') { "ignored.txt`r`n" } else { "ignored.txt`n" }
        [System.IO.File]::WriteAllText((Join-Path $original '.gitignore'), $ignored)
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('add', '--all')
        $rawBlob = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('hash-object', '-w', '--no-filters', '--', '.gitignore')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('update-index', '--add', '--cacheinfo', '100644', $rawBlob, '.gitignore')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            '-c', 'user.name=AVM test', '-c', 'user.email=avm-test@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Base')
        $baseSha = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('rev-parse', 'HEAD')

        [System.IO.File]::WriteAllText((Join-Path $original 'main.tf'), "variable `"name`" { type = string }`n")
        [System.IO.File]::WriteAllText((Join-Path $original 'variables.tf'), "variable `"location`" { type = string }`n")
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('add', '--all')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            '-c', 'user.name=AVM test', '-c', 'user.email=avm-test@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Candidate')
        $tree = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('rev-parse', 'HEAD^{tree}')
        $archivePath = Join-Path $candidate 'candidate.tar'
        $patchPath = Join-Path $candidate 'candidate.patch'
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @('archive', '--format=tar', "--output=$archivePath", 'HEAD')
        $null = Invoke-RepositoryGit -WorkingDirectory $original -Arguments @(
            'diff', '--binary', '--full-index', '--no-renames', "--output=$patchPath", $baseSha, 'HEAD')

        $extract = Invoke-RepositorySyncProcess -Command tar -Arguments @('-xf', $archivePath, '-C', $validation)
        $extract.ExitCode | Should -Be 0
        $null = Invoke-RepositoryGit -WorkingDirectory $TestDrive -Arguments @('init', '--quiet', '-b', 'main', $validation)
        $null = Invoke-RepositoryGit -WorkingDirectory $validation -Arguments @('config', '--local', 'core.autocrlf', 'false')
        (Initialize-RepositorySyncCandidateIndex -Root $validation) | Should -BeExactly $tree
        Test-Path -LiteralPath (Join-Path $validation '.git' 'info' 'attributes') | Should -BeFalse
        [System.IO.File]::ReadAllText((Join-Path $validation '.gitignore')) | Should -BeExactly $ignored
        $null = Invoke-RepositoryGit -WorkingDirectory $validation -Arguments @(
            '-c', 'user.name=AVM test', '-c', 'user.email=avm-test@users.noreply.github.com',
            'commit', '--quiet', '-m', 'Validate')
        (Invoke-RepositoryGit -WorkingDirectory $validation -Arguments @('status', '--porcelain')) | Should -BeNullOrEmpty
        $null = Invoke-RepositoryGit -WorkingDirectory $caseRoot -Arguments @('clone', '--quiet', $validation, $unit)
        (Invoke-RepositoryGit -WorkingDirectory $unit -Arguments @('rev-parse', 'HEAD^{tree}')) | Should -BeExactly $tree
        (Invoke-RepositoryGit -WorkingDirectory $unit -Arguments @('status', '--porcelain')) | Should -BeNullOrEmpty

        $null = Invoke-RepositoryGit -WorkingDirectory $TestDrive -Arguments @('clone', '--quiet', $original, $publication)
        $null = Invoke-RepositoryGit -WorkingDirectory $publication -Arguments @('checkout', '--quiet', $baseSha)
        $null = Invoke-RepositoryGit -WorkingDirectory $publication -Arguments @('apply', '--index', '--binary', '--', $patchPath)
        (Invoke-RepositoryGit -WorkingDirectory $publication -Arguments @('write-tree')) | Should -BeExactly $tree
    }

    It 'restores existing attributes after indexing succeeds' {
        $root = Join-Path $TestDrive 'existing-attributes'
        $null = New-Item -ItemType Directory -Path (Join-Path $root '.git' 'info') -Force
        $attributesPath = Join-Path $root '.git' 'info' 'attributes'
        $original = [System.Text.Encoding]::UTF8.GetBytes("* text=auto`r`n")
        [System.IO.File]::WriteAllBytes($attributesPath, $original)
        Mock Invoke-RepositoryGit {
            [System.IO.File]::ReadAllText((Join-Path $WorkingDirectory '.git' 'info' 'attributes')) |
                Should -BeExactly "* -text -filter -ident -working-tree-encoding`n"
            if ($Arguments[0] -eq 'write-tree') { return 'a' * 40 }
        }

        (Initialize-RepositorySyncCandidateIndex -Root $root) | Should -BeExactly ('a' * 40)
        [System.IO.File]::ReadAllBytes($attributesPath) | Should -Be $original
    }

    It 'restores the attribute state after indexing fails with existing attributes <Existing>' -TestCases @(
        @{ Existing = $true }
        @{ Existing = $false }
    ) {
        param($Existing)

        $root = Join-Path $TestDrive "failed-index-$Existing"
        $null = New-Item -ItemType Directory -Path (Join-Path $root '.git' 'info') -Force
        $attributesPath = Join-Path $root '.git' 'info' 'attributes'
        if ($Existing) {
            [System.IO.File]::WriteAllText($attributesPath, "* text=auto`r`n")
        }
        Mock Invoke-RepositoryGit { throw [System.InvalidOperationException]::new('Indexing failed.') }

        { Initialize-RepositorySyncCandidateIndex -Root $root } | Should -Throw '*Indexing failed*'
        (Test-Path -LiteralPath $attributesPath -PathType Leaf) | Should -Be $Existing
        if ($Existing) {
            [System.IO.File]::ReadAllText($attributesPath) | Should -BeExactly "* text=auto`r`n"
        }
        Should -Invoke Invoke-RepositoryGit -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'write-tree' }
    }
}
