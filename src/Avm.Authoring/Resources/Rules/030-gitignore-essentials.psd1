@{
    Id          = 'avm.tf.gitignore-essentials'
    Kind        = 'GitignoreMustContain'
    Description = 'AVM .gitignore must list the 24 canonical globs (state, plans, lockfiles, .terraform/, tfvars, .DS_Store, crash.log, .avm, ...) so common heavy or sensitive files are never accidentally committed.'
    Severity    = 'error'
    AppliesTo   = 'root'
    Parameters  = @{
        RequiredGlobs = @(
            '.DS_Store',
            '.terraform.lock.hcl',
            '.terraformrc',
            '*.md.tmp',
            '*.mptfbackup',
            '*.tfstate.*',
            '*.tfstate',
            '*.tfvars.json',
            '*.tfvars',
            '**/.terraform/*',
            '*tfplan*',
            'avm.tflint_example.hcl',
            'avm.tflint_example.merged.hcl',
            'avm.tflint_module.hcl',
            'avm.tflint_module.merged.hcl',
            'avm.tflint.hcl',
            'avm.tflint.merged.hcl',
            'avmmakefile',
            'crash.*.log',
            'crash.log',
            'examples/*/policy',
            'README-generated.md',
            'terraform.rc',
            '.avm'
        )
    }
}
