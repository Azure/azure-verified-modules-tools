@{
    Id          = 'avm.tf.tests-dir-must-exist'
    Kind        = 'DirectoryMustContainFile'
    Description = 'AVM requires at least one Terraform unit test fixture.'
    Severity    = 'error'
    AppliesTo   = 'root'
    Parameters  = @{
        Path    = 'tests/unit'
        Pattern = '*.tftest.hcl'
    }
}
