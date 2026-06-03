@{
    Id          = 'avm.tf.outputs-tf-not-output-tf'
    Kind        = 'FileMustNotExist'
    Description = 'AVM mandates the plural filename outputs.tf; singular output.tf is a contributor mistake.'
    Severity    = 'error'
    AppliesTo   = 'all'
    Parameters  = @{
        Path        = 'output.tf'
        FixRenameTo = 'outputs.tf'
    }
}
