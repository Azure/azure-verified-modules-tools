@{
    Id          = 'avm.tf.variables-tf-not-variable-tf'
    Kind        = 'FileMustNotExist'
    Description = 'AVM mandates the plural filename variables.tf; singular variable.tf is a contributor mistake.'
    Severity    = 'error'
    AppliesTo   = 'all'
    Parameters  = @{
        Path        = 'variable.tf'
        FixRenameTo = 'variables.tf'
    }
}
