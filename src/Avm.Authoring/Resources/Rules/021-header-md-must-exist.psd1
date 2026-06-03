@{
    Id          = 'avm.tf.header-md-must-exist'
    Kind        = 'FileMustExist'
    Description = 'AVM requires _header.md so terraform-docs can inject the module description into README.md.'
    Severity    = 'error'
    AppliesTo   = 'all'
    Parameters  = @{
        Path = '_header.md'
    }
}
