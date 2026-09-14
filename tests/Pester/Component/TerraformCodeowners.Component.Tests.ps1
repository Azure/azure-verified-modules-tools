BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    . (Join-Path $repoRoot 'repository-management' 'repository-sync' 'scripts' 'lib' 'TerraformCodeowners.ps1')
    $script:content = "# Managed CODEOWNERS`n.github/CODEOWNERS @Azure/engineering-reviewers`n"
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
        Mock Get-Item { [pscustomobject]@{ Attributes = [System.IO.FileAttributes]::ReparsePoint; PSIsContainer = $false } } `
            -ParameterFilter { $LiteralPath -ceq $script:target }
        { Set-TerraformCodeowners -RepositoryRoot $script:root -Content $script:content } | Should -Throw '*through a link*'
        Get-Content -LiteralPath $script:target -Raw | Should -BeExactly 'keep'
    }
}
