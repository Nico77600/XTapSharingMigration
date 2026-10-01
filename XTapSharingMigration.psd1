#
#  X-TAP Sharing Migration - module manifest
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : see ModuleVersion
#
#  Loaded by Invoke-XTapSharingMigration.ps1 (Import-Module by path).
#
@{
    RootModule        = 'XTapSharingMigration.psm1'
    ModuleVersion     = '1.0.2'
    GUID              = '4f0c7b0e-3a5d-4b8e-9d6f-2c1a7e5b9a31'
    Author            = 'Nicolas Fabert'
    Description       = 'X-TAP Sharing Migration: inventories Exchange Online organization relationships, sharing policies and availability address spaces, and configures the equivalent Microsoft 365 cross-tenant access policy (Free/Busy, MailTips, calendar sharing) in two phases, Entra and Exchange.'
    PowerShellVersion = '7.4'

    # Functions called by Invoke-XTapSharingMigration.ps1 and by the tests. The other functions stay internal
    # to the module (the tests reach them with InModuleScope).
    FunctionsToExport = @(
        'Import-XsmConfiguration', 'ConvertTo-XsmScopeSpec', 'Format-XsmScope', 'Get-XsmCapabilityName'
        'Start-XsmLog', 'Stop-XsmLog', 'Write-XsmLog', 'Write-XsmBanner', 'Write-XsmStep', 'Write-XsmSection', 'Write-XsmItem', 'Write-XsmTable', 'Write-XsmSummary', 'Format-XsmDuration'
        'Import-XsmModules', 'Connect-XsmExchange', 'Disconnect-XsmExchange', 'Connect-XsmGraph', 'Disconnect-XsmGraph', 'Get-XsmGraphScopes', 'Get-XsmExpectedAccount'
        'New-XsmRunDirectory', 'Get-XsmExchangeInventory', 'Get-XsmExternalDomains', 'Resolve-XsmDomainTenant', 'Resolve-XsmDomainTenants', 'Test-XsmTenantInfoAvailable', 'Get-XsmXtapState'
        'Get-XsmMigrationItems', 'Get-XsmItemDecision', 'Get-XsmPartnerConfirmation', 'Export-XsmSelection', 'Import-XsmSelection', 'Save-XsmJson'
        'Find-XsmLatestSnapshot', 'Import-XsmSnapshot', 'Import-XsmSharingPolicyMailboxes'
        'New-XsmTargetState', 'Get-XsmLevelConflicts', 'Import-XsmLevelChoices', 'Save-XsmLevelChoices', 'Request-XsmLevelChoices', 'Get-XsmLiveState', 'New-XsmActions', 'Show-XsmActions', 'Get-XsmActionCounts', 'Invoke-XsmActions', 'Set-XsmVerification'
        'Get-XsmCutover', 'Export-XsmCutoverText', 'Export-XsmActionsCsv', 'New-XsmReportData', 'New-XsmHtmlReport', 'Get-XsmPartnerSummary', 'Export-XsmPartnerSnippet'
        'ConvertTo-XsmReportAction', 'ConvertTo-XsmReportTarget', 'ConvertTo-XsmReportItems', 'ConvertTo-XsmReportXtap'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
