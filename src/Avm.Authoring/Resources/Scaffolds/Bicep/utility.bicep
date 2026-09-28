metadata name = '<Add module name>'
metadata description = '<Add description>'

@description('Required. Name of the resource to create.')
param name string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

// Add your parameters and resources here.

// @description('The resource ID of the resource.')
// output resourceId string = <Resource>.id

// @description('The name of the resource.')
// output name string = <Resource>.name
