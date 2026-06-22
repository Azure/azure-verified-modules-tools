@{
    Id          = 'avm.tf.tests-dir-must-exist'
    Kind        = 'DirectoryMustExist'
    Description = 'AVM requires a tests/ directory at the module root for terraform test fixtures.'
    Severity    = 'error'
    AppliesTo   = 'root'
    Parameters  = @{
        Path = 'tests'
    }
}
