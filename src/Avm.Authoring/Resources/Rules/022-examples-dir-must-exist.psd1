@{
    Id          = 'avm.tf.examples-dir-must-exist'
    Kind        = 'DirectoryMustExist'
    Description = 'AVM requires an examples/ directory at the module root for per-example pre-commit and terraform-docs.'
    Severity    = 'error'
    AppliesTo   = 'root'
    Parameters  = @{
        Path = 'examples'
    }
}
