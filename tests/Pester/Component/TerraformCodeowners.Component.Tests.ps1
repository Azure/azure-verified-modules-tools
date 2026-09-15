BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $syncRoot = Join-Path $repoRoot 'repository-management' 'repository-sync'
    . (Join-Path $syncRoot 'scripts' 'lib' 'TerraformCodeowners.ps1')
    $template = Get-Content -LiteralPath (Join-Path $syncRoot 'CODEOWNERS.template') -Raw
    $script:content = ConvertTo-TerraformCodeowners -Organization Azure -DefaultTeams @('module-reviewers') `
        -FileProtectionTeams @('engineering-reviewers') -Template $template
}

Describe 'Terraform CODEOWNERS filesystem contract' -Tag Component {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $script:root
    }

    It 'does not create a directory or file under WhatIf' {
        Set-TerraformCodeowners -RepositoryRoot $script:root -Content $script:content -WhatIf
        Test-Path -LiteralPath (Join-Path $script:root '.github') | Should -BeFalse
    }

    It 'produces byte-identical content on repeated writes without changing other files' {
        $other = Join-Path $script:root 'main.tf'
        [System.IO.File]::WriteAllText($other, 'unchanged')
        $destination = Join-Path $script:root '.github' 'CODEOWNERS'
        Set-TerraformCodeowners -RepositoryRoot $script:root -Content $script:content
        $first = [System.IO.File]::ReadAllBytes($destination)
        Set-TerraformCodeowners -RepositoryRoot $script:root -Content $script:content
        $second = [System.IO.File]::ReadAllBytes($destination)
        [Convert]::ToBase64String($second) | Should -BeExactly ([Convert]::ToBase64String($first))
        [System.Text.Encoding]::UTF8.GetString($second) | Should -BeExactly $script:content
        [System.Text.Encoding]::UTF8.GetString($second).TrimEnd("`n").Split("`n")[-1] |
            Should -BeExactly 'metadata.json @Azure/azure-verified-modules-engineering-owners'
        Get-Content -LiteralPath $other -Raw | Should -BeExactly 'unchanged'
    }

    It 'refuses a .github file instead of replacing it with a directory' {
        $path = Join-Path $script:root '.github'
        [System.IO.File]::WriteAllText($path, 'keep')
        { Set-TerraformCodeowners -RepositoryRoot $script:root -Content $script:content } | Should -Throw '*incompatible path*'
        Get-Content -LiteralPath $path -Raw | Should -BeExactly 'keep'
    }

    It 'refuses a CODEOWNERS directory without deleting its contents' {
        $path = Join-Path $script:root '.github' 'CODEOWNERS'
        $null = New-Item -ItemType Directory -Path $path -Force
        $marker = Join-Path $path 'keep'
        [System.IO.File]::WriteAllText($marker, 'keep')
        { Set-TerraformCodeowners -RepositoryRoot $script:root -Content $script:content } | Should -Throw '*incompatible path*'
        Get-Content -LiteralPath $marker -Raw | Should -BeExactly 'keep'
    }

    It 'refuses reparse-point targets before writing' {
        Set-TerraformCodeowners -RepositoryRoot $script:root -Content 'keep'
        $script:target = Join-Path $script:root '.github' 'CODEOWNERS'
        $script:githubPath = Split-Path -Parent $script:target
        $script:githubDirectory = Get-Item -LiteralPath $script:githubPath -Force
        Mock Get-Item { $script:githubDirectory } -ParameterFilter { $LiteralPath -ceq $script:githubPath }
        Mock Get-Item { [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::ReparsePoint; PSIsContainer = $false } } `
            -ParameterFilter { $LiteralPath -ceq $script:target }
        { Set-TerraformCodeowners -RepositoryRoot $script:root -Content $script:content } | Should -Throw '*through a link*'
        Should -Invoke Get-Item -Exactly 1 -ParameterFilter { $LiteralPath -ceq $script:githubPath }
        Should -Invoke Get-Item -Exactly 1 -ParameterFilter { $LiteralPath -ceq $script:target }
        Get-Content -LiteralPath $script:target -Raw | Should -BeExactly 'keep'
    }
}
