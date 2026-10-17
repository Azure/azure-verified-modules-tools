#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Native telemetry qualification clock seam' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'Helpers' 'TerraformTelemetryClock.ps1')
        $script:body = @'
{
  properties = {
    mode = "Incremental"
    template = {
      outputs = {
        apply_id = {
          type = "String"
          value = plantimestamp()
        }
      }
    }
  }
}
'@
    }

    It 'overrides only the native clock expression and preserves every other body byte' {
        $document = New-TerraformTelemetryClockOverride -Body $script:body | ConvertFrom-Json -AsHashtable
        @($document.Keys) | Should -Be @('resource')
        @($document.resource.Keys) | Should -Be @('azapi_resource')
        @($document.resource.azapi_resource.Keys) | Should -Be @('telemetry')
        @($document.resource.azapi_resource.telemetry.Keys) | Should -Be @('body')
        $expression = $document.resource.azapi_resource.telemetry.body
        $expression | Should -BeExactly ('${' + $script:body.Replace('plantimestamp()', 'var.qualification_plan_time') + '}')
        $expression.Substring(2, $expression.Length - 3).
            Replace('var.qualification_plan_time', 'plantimestamp()') | Should -BeExactly $script:body
    }

    It 'rejects an unexpected generated clock: <Shape>' -ForEach @(
        @{ Shape = 'a different function'; Clock = 'timestamp()' }
        @{ Shape = 'a constant'; Clock = '"fixed"' }
        @{ Shape = 'a quoted function'; Clock = '"plantimestamp()"' }
        @{ Shape = 'an extra expression'; Clock = 'upper(plantimestamp())' }
        @{ Shape = 'an existing test dependency'; Clock = 'var.qualification_plan_time' }
        @{ Shape = 'another clock call'; Clock = 'plantimestamp()'; Extra = "`nother = plantimestamp()" }
        @{ Shape = 'another apply id'; Clock = 'plantimestamp()'; Extra = "`napply_id = { type = `"String`"`nvalue = plantimestamp() }" }
    ) {
        param($Clock, [string] $Extra = '')
        $body = $script:body.Replace('plantimestamp()', $Clock)
        if ($Extra) { $body += $Extra }
        { New-TerraformTelemetryClockOverride -Body $body } |
            Should -Throw '*exactly one plantimestamp() clock expression*'
    }
}
