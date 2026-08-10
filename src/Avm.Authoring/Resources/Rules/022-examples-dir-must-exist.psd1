@{
    Id          = 'avm.tf.examples-dir-must-exist'
    Kind        = 'DirectoryMustExist'
    Description = 'AVM requires examples/ to contain at least one example directory.'
    Severity    = 'error'
    AppliesTo   = 'root'
    Parameters  = @{
        Path                    = 'examples'
        MinimumChildDirectories = 1
    }
}
