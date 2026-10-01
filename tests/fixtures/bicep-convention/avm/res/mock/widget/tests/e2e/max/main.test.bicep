metadata name = 'Widget max'
metadata description = 'Deploys the maximum mock widget.'

param serviceShort string = 'wgtmax'
param namePrefix string = '#_namePrefix_#'

module testDeployment '../../../main.bicep' = {
  name: '${namePrefix}-test-${serviceShort}'
  params: {
    name: '${namePrefix}${serviceShort}'
  }
}
