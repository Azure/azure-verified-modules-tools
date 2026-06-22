@{
    Id          = 'avm.tf.terraform-tf-must-exist'
    Kind        = 'FileMustExist'
    Description = 'AVM requires terraform.tf as the canonical home of the terraform { required_version + required_providers } block.'
    Severity    = 'error'
    AppliesTo   = 'all'
    Parameters  = @{
        Path = 'terraform.tf'
    }
}
