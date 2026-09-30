metadata name = 'Widget WAF'
metadata description = 'Deploys the WAF-aligned mock widget.'

param serviceShort string = 'wgtwaf'
param namePrefix string = '#_namePrefix_#'

module testDeployment '../../../main.bicep' = {
  name: '${namePrefix}-test-${serviceShort}'
  params: {
    name: '${namePrefix}${serviceShort}'
  }
}
