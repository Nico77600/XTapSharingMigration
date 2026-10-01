#Requires -Version 7.4

<#
.SYNOPSIS
    X-TAP Sharing Migration - PowerShell module.

.DESCRIPTION
    Helper functions used by Invoke-XTapSharingMigration.ps1. The code is split into files in src\,
    loaded here in the order of an execution:

        Console.ps1         Write-Xsm* functions: what the administrator sees, and the log file
        Configuration.ps1   Import-XsmConfiguration: reads and checks the .psd1 file; feature catalogue
        Connection.ps1      Exchange Online and Microsoft Graph connections, Graph calls (v1.0 only)
        Collect.ps1         Reads Exchange Online, the Microsoft 365 cross-tenant access policy, partner tenants
        Classification.ps1  Turns the inventory into migration items (in scope / out of scope and why)
        Selection.ps1       Selection.csv: written by Collect, completed by the administrator, read by Plan/Apply
        Plan.ps1            Target configuration (groups, trusts, capabilities) and comparison with the tenant
        Apply.ps1           Executes the actions of a phase (Entra or Exchange), then verifies
        Report.ps1          HTML report (inventory, plan, result), CSV files, manual cutover commands

    The tool never changes an Exchange Online object: the cutover (disabling organization relationships,
    sharing policies, availability address spaces) stays a manual, coordinated action. The report gives
    the commands.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
    History : see CHANGELOG.md
#>
# Strict mode 1.0: uninitialized variables are errors. Not 'Latest': the tool reads JSON and Graph objects whose
# optional properties may be absent, and PowerShell 7 strict mode 3.0 throws on a missing hashtable key.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:ToolName = 'X-TAP Sharing Migration'
$script:ToolVersion = '1.0.0'
$script:ToolAuthor = 'Nicolas Fabert'
$script:ToolRoot = $PSScriptRoot
$script:GraphRoot = 'https://graph.microsoft.com/v1.0'
# Prefix given to the Exchange Online cmdlets imported by Connect-ExchangeOnline: avoids any clash with
# another Exchange session opened in the same console (Get-XsmExoOrganizationRelationship ...).
$script:ExoPrefix = 'XsmExo'

foreach ($file in 'Console', 'Configuration', 'Connection', 'Collect', 'Classification', 'Selection', 'Plan', 'Apply', 'Report') {
    . (Join-Path $PSScriptRoot "src\$file.ps1")
}
