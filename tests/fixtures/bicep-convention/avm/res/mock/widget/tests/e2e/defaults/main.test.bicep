metadata name = 'Widget defaults'
metadata description = 'Deploys the default mock widget.'

param serviceShort string = 'wgtmin'
param namePrefix string = '#_namePrefix_#'

module testDeployment '../../../main.bicep' = {
  name: '${namePrefix}-test-${serviceShort}'
  params: {
    name: '${namePrefix}${serviceShort}'
  }
}
