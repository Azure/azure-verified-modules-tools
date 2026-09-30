metadata name = 'Minimal example'
metadata description = 'Deploys the minimal module configuration.'

module testDeployment '../../../main.bicep' = {
  name: 'minimal'
  params: {
    name: 'avmdocs12345'
  }
}
