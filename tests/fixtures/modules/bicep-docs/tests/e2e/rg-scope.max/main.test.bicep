targetScope = 'resourceGroup'

metadata name = 'Full example'
metadata description = 'Deploys the module with location and interpolated inputs.'

param serviceShort string = 'docs'
param namePrefix string = '#_namePrefix_#'

module testDeployment '../../../main.bicep' = {
  name: 'full'
  params: {
    location: resourceGroup().location
    name: 'avm-${namePrefix}-${serviceShort}-rg'
  }
}
