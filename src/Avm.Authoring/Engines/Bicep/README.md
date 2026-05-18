# Bicep engine (Phase 1)

This folder is the entry point for the Bicep facade that consolidates the
existing `Set-AVMModule`, `New-AVMResourceModule`, `New-AVMPatternModule`,
`Test-AVMModule`, `Publish-AVMModule`, and related contributor workflows
behind the `avm` dispatcher.

Phase 1 will introduce these verbs (per `docs/avm-consolidation-plan.md`
section 6):

| Verb                                | Public cmdlet              | Status   |
| ----------------------------------- | -------------------------- | -------- |
| `avm bicep test`                    | `Invoke-AvmBicepTest`      | Pending  |
| `avm bicep publish`                 | `Publish-AvmBicepModule`   | Pending  |
| `avm bicep scaffold res`            | `New-AvmBicepResource`     | Pending  |
| `avm bicep scaffold ptn`            | `New-AvmBicepPattern`      | Pending  |
| `avm bicep scaffold utl`            | `New-AvmBicepUtility`      | Pending  |
| `avm bicep upgrade`                 | `Update-AvmBicepModule`    | Pending  |

Until Phase 1 lands, this folder is intentionally empty apart from this
README. The Phase 0 dispatcher will list these verbs as `(pending)` once the
verb registry gains a 'state' column.
