@{
    Id          = 'avm.tf.terraform-scopes-must-be-direct-children'
    Kind        = 'TerraformScopesMustBeDirectChildren'
    Description = 'AVM permits Terraform module and example roots only one level below modules/ and examples/.'
    Severity    = 'error'
    AppliesTo   = 'root'
    Parameters  = @{
        ScopeDirectories = @('modules', 'examples')
    }
}
