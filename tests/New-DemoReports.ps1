#Requires -Version 7.4

<#
.SYNOPSIS
    Builds the three HTML reports (Inventory, Plan, Result) from the fictitious tenant of the tests, with
    no connection to Microsoft 365. Used for the documentation screenshots and to try the reports.

.DESCRIPTION
    The tenant (Contoso), its partners (Fabrikam, Northwind, Adatum ...) and Microsoft Graph are simulated
    by tests\TestData.ps1 and tests\FakeGraph.ps1. Nothing is real: no tenant ID, domain or person.

.PARAMETER OutputPath
    Folder of the reports. Default: a new folder in the temporary directory.

.EXAMPLE
    .\tests\New-DemoReports.ps1
#>
[CmdletBinding()]
param([string]$OutputPath = (Join-Path ([IO.Path]::GetTempPath()) ('XTapSharingMigration-demo-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))))

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'XTapSharingMigration.psd1') -Force
. (Join-Path $PSScriptRoot 'TestData.ps1')
. (Join-Path $PSScriptRoot 'FakeGraph.ps1')
[void][IO.Directory]::CreateDirectory($OutputPath)

$settings = Import-XsmConfiguration -Path (New-TestConfiguration -Directory $OutputPath) -Root $root
$settings.Apply.ExistingCapability = 'Merge'
$fake = New-FakeTenant
Set-FakeGraph $fake

# ---- Inventory --------------------------------------------------------------------------------------------
$snap = New-TestSnapshot
# A second relationship of Fabrikam with another level: the administrator chooses (Collect lists it, Plan asks).
$snap.Domains['fabrikam.eu'] = [ordered]@{ Domain = 'fabrikam.eu'; Status = 'Resolved'; TenantId = $TestTenant.Fabrikam; DisplayName = 'Fabrikam'; DefaultDomain = ''; Cloud = 'microsoftonline.com'; Region = 'EU'; Source = 'Demo'; Error = '' }
$snap.Exchange.OrganizationRelationships = @($snap.Exchange.OrganizationRelationships) + @((New-TestOrgRel 'Fabrikam Europe' @('fabrikam.eu') -FB $true -FBLevel 'AvailabilityOnly' -AppUri 'outlook.com'))
$class = Get-XsmMigrationItems -Snapshot $snap -Settings $settings
$snap.Items = $class.Items; $snap.Sources = $class.Sources
$collect = Join-Path $OutputPath 'Collect'
[void][IO.Directory]::CreateDirectory($collect)
Save-XsmJson $snap (Join-Path $collect 'snapshot.json')
New-TestMailboxFile -Directory $collect
$snapshot = Import-XsmSnapshot -Path $collect -Settings $settings
$partners = @(Get-XsmPartnerSummary -Snapshot $snapshot -Settings $settings)
$items = @($snapshot.Items)
$inScope = @($items | Where-Object Status -eq 'InScope')
$data = New-XsmReportData -Kind Collect -Settings $settings -Snapshot $snapshot
$data.Accounts = $snapshot.Accounts
$data.Items = ConvertTo-XsmReportItems -Items $items -Settings $settings
$data.Sources = $snapshot.Sources; $data.Exchange = $snapshot.Exchange; $data.Xtap = $snapshot.Xtap; $data.Partners = $partners
$data.Conflicts = @(Get-XsmLevelConflicts -Entries @($items | ForEach-Object { [ordered]@{ Item = $_; Decision = (Get-XsmItemDecision -Item $_ -Settings $settings) } }) -Settings $settings)
$reasons = @($items | Where-Object Status -ne 'InScope' | Group-Object { $_.Reason } | ForEach-Object { "$($_.Name) $($_.Count)" })
$data.Metrics = @(
    @{ Label = 'Items proposed'; Value = @($data.Items | Where-Object Include).Count; Hint = "of $($items.Count) item(s) found in Exchange Online" }
    @{ Label = 'Partner tenants'; Value = @($inScope | Where-Object { $_.Target -eq 'Partner' -and $_.PartnerTenantId } | ForEach-Object { $_.PartnerTenantId } | Select-Object -Unique).Count; Hint = 'external Microsoft 365 organizations in scope' }
    @{ Label = 'Out of scope'; Value = ($items.Count - $inScope.Count); Hint = ($reasons -join ' · ') }
    @{ Label = 'Already in X-TAP'; Value = @($inScope | Where-Object XtapStatus -eq 'Present').Count; Hint = 'items already configured with the same level and scope' }
)
$data.Warnings = @()
New-XsmHtmlReport -Data $data -Path (Join-Path $OutputPath 'Inventory.html')
Export-XsmSelection -Items $items -Settings $settings -Path (Join-Path $OutputPath 'Selection.csv') -CollectId $snapshot.CollectId
Export-XsmPartnerSnippet -Partners $partners -Path (Join-Path $OutputPath 'PartnersToConfirm.txt') -Settings $settings

# ---- Plan, then Apply Entra and Exchange -----------------------------------------------------------------------
$first = New-XsmTargetState -Snapshot $snapshot -Settings $settings
$choices = @{}
foreach ($c in $first.Conflicts) { $choices[$c.Key] = [ordered]@{ Key = $c.Key; Level = $c.Options[-1].Level; By = 'admin@contoso.onmicrosoft.com' } }
$target = New-XsmTargetState -Snapshot $snapshot -Settings $settings -MailboxesByPolicy (Import-XsmSharingPolicyMailboxes $snapshot) -LevelChoices $choices
$cutover = Get-XsmCutover -Snapshot $snapshot -Target $target
function New-DemoReport([string]$Kind, [string]$Phase, [object[]]$Actions, $Live, [string]$File) {
    $d = New-XsmReportData -Kind $Kind -Settings $settings -Snapshot $snapshot -Phase $Phase
    $d.Accounts = [ordered]@{ 'Microsoft Graph' = 'admin@contoso.onmicrosoft.com' }
    $d.SelectionPath = ''
    $d.Items = ConvertTo-XsmReportItems -Items $items -Settings $settings -Decisions $target.Decisions
    $d.Actions = @($Actions | ForEach-Object { ConvertTo-XsmReportAction $_ })
    $d.Target = ConvertTo-XsmReportTarget $target
    $d.Cutover = $cutover
    $d.Exchange = $snapshot.Exchange; $d.Sources = $snapshot.Sources
    $d.Xtap = ConvertTo-XsmReportXtap -Live $Live -Target $target
    $d.Warnings = @($target.Warnings) + @($Actions | Where-Object { $_.Operation -in 'Blocked', 'Conflict' } | ForEach-Object { "$($_.Id) $($_.Target): $($_.Detail)" })
    $d.Errors = @()
    $c = Get-XsmActionCounts $Actions
    $d.Metrics = if ($Kind -eq 'Plan') {
        @(@{ Label = 'Entra changes'; Value = $c.EntraToDo; Hint = 'security groups and Microsoft 365 collaboration trusts' }
            @{ Label = 'Exchange changes'; Value = $c.ExchangeToDo; Hint = 'Free/Busy, MailTips and calendar sharing capabilities' }
            @{ Label = 'Already in place'; Value = $c.NoChange; Hint = 'nothing to change' }
            @{ Label = 'Blocked'; Value = $c.Blocked; Hint = 'actions blocked or items that cannot be migrated' })
    } else {
        @(@{ Label = 'Changes done'; Value = $c.Done; Hint = "phase $Phase, verified: $(@($Actions | Where-Object { $_.Verified -like 'Verified*' }).Count)" }
            @{ Label = 'Already in place'; Value = $c.NoChangeInPhase; Hint = "phase $Phase, nothing to change" }
            @{ Label = 'Other phase'; Value = @($Actions | Where-Object Status -eq 'OtherPhase').Count; Hint = 'to be done by the other administrator' }
            @{ Label = 'Failed / blocked'; Value = ($c.Failed + $c.Skipped + $c.BlockedInPhase); Hint = "phase $Phase, see the Actions tab" })
    }
    New-XsmHtmlReport -Data $d -Path (Join-Path $OutputPath $File)
}
$live = Get-XsmLiveState -Target $target -Members
New-DemoReport Plan All (New-XsmActions -Target $target -Live $live -Settings $settings -Phase All) $live 'Plan.html'
Export-XsmCutoverText -Cutover $cutover -Path (Join-Path $OutputPath 'ManualCutover.txt') -Settings $settings
foreach ($phase in 'Entra', 'Exchange') {
    $live = Get-XsmLiveState -Target $target -Members
    $actions = New-XsmActions -Target $target -Live $live -Settings $settings -Phase $phase
    $ids = Invoke-XsmActions -Actions $actions -Live $live 6>$null
    $after = New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target -Members -KnownGroupIds $ids) -Settings $settings -Phase $phase
    Set-XsmVerification -Actions $actions -After $after
    New-DemoReport Apply $phase $actions $live "Result-$phase.html"
}
Write-Host "Demo reports: $OutputPath"
Get-ChildItem $OutputPath -File | ForEach-Object { '  ' + $_.Name }
