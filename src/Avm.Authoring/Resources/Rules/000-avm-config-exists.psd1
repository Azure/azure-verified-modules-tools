@{
    Id          = 'avm.smoke.avm-config-exists'
    Kind        = 'FileMustExist'
    Description = 'Repo must declare a .avm/config.json (pinned-asset and rule overrides live there).'
    Severity    = 'warning'
    AppliesTo   = 'root'
    Parameters  = @{
        Path = '.avm/config.json'
    }
}
