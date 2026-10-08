#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    X-TAP Sharing Migration - automated tests (Pester 5 or later).
    Author  : Nicolas Fabert
    Version : 1.0.3

    Run:  Invoke-Pester -Path .\tests -Output Detailed

    No connection to Microsoft 365 is made. The tenant is fictitious (Contoso), the partner tenants are
    resolved by a fake resolver, and Microsoft Graph is replaced by an in-memory tenant
    (tests\FakeGraph.ps1) that answers the v1.0 calls used by the tool.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Root = Join-Path $script:RepoRoot 'package'
    Import-Module (Join-Path $script:Root 'XTapSharingMigration.psd1') -Force
    . (Join-Path $PSScriptRoot 'FakeGraph.ps1')
    . (Join-Path $PSScriptRoot 'TestData.ps1')

    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('XsmTests-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($script:Work)
    $script:ConfigPath = New-TestConfiguration -Directory $script:Work
    $script:Settings = Import-XsmConfiguration -Path $script:ConfigPath -Root $script:Root

    function Get-TestSnapshot([object]$Settings = $script:Settings) {
        # Classified, saved and read back from JSON: Plan and Apply always work on a snapshot read from disk.
        $snap = New-TestSnapshot
        $class = Get-XsmMigrationItems -Snapshot $snap -Settings $Settings
        $snap.Items = $class.Items; $snap.Sources = $class.Sources
        $dir = Join-Path $script:Work ('snap-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($dir)
        Save-XsmJson $snap (Join-Path $dir 'snapshot.json')
        New-TestMailboxFile -Directory $dir
        return Import-XsmSnapshot -Path $dir -Settings $Settings
    }
    function Get-Item([object]$Snapshot, [string]$Id) { @($Snapshot.Items | Where-Object ItemId -eq $Id)[0] }
    function Set-TestSettings([scriptblock]$Change) {
        $s = Import-XsmConfiguration -Path $script:ConfigPath -Root $script:Root
        & $Change $s
        return $s
    }
}

AfterAll {
    InModuleScope XTapSharingMigration { $script:GraphInvoker = $null; $script:TenantResolver = $null }
    if ($script:Work -and (Test-Path $script:Work)) { Remove-Item $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Configuration' {
    It 'loads the delivered configuration file with fictitious tenant values' {
        $script:Settings.Tenant.TenantId | Should -Be $TestTenant.Id
        $script:Settings.Features.FreeBusy.Level | Should -Be 'AsDiscovered'
        $script:Settings.Output.Zone | Should -Not -BeNullOrEmpty
    }
    It 'reports every invalid value at once' {
        $text = [IO.File]::ReadAllText($script:ConfigPath)
        $text = $text -replace "Level = 'AsDiscovered'; Scope = 'AsDiscovered' \}", "Level = 'Wrong'; Scope = 'Nope:x' }" -replace "Mode\s+= 'Interactive'", "Mode = 'Magic'"
        $bad = Join-Path $script:Work 'bad.config.psd1'
        [IO.File]::WriteAllText($bad, $text)
        $message = { Import-XsmConfiguration -Path $bad -Root $script:Root } | Should -Throw -PassThru
        $message.Exception.Message | Should -Match 'Authentication.Mode'
        $message.Exception.Message | Should -Match 'Features.FreeBusy.Level'
        $message.Exception.Message | Should -Match 'Features.MailTips.Scope'
    }
    It 'canonicalizes a forced level' {
        $s = Set-TestSettings { }
        InModuleScope XTapSharingMigration { Resolve-XsmLevelName 'FreeBusy' 'limiteddetails' } | Should -Be 'LimitedDetails'
    }
    It 'expects the account of the administrator of each phase' {
        $s = Set-TestSettings { param($s) $s.Authentication.ExchangeAdmin = 'exo-admin@contoso.com'; $s.Authentication.EntraAdmin = 'entra-admin@contoso.com' }
        Get-XsmExpectedAccount -Settings $s -Mode Collect | Should -Be 'exo-admin@contoso.com'
        Get-XsmExpectedAccount -Settings $s -Mode Plan | Should -Be 'exo-admin@contoso.com'
        Get-XsmExpectedAccount -Settings $s -Mode Plan -Phase Exchange | Should -Be 'exo-admin@contoso.com'
        Get-XsmExpectedAccount -Settings $s -Mode Plan -Phase Entra | Should -Be 'entra-admin@contoso.com'
        Get-XsmExpectedAccount -Settings $s -Mode Apply -Phase Entra | Should -Be 'entra-admin@contoso.com'
        Get-XsmExpectedAccount -Settings $s -Mode Apply -Phase All | Should -Be 'entra-admin@contoso.com'
        Get-XsmExpectedAccount -Settings $s -Mode Apply -Phase Exchange | Should -Be 'exo-admin@contoso.com'
        Get-XsmExpectedAccount -Settings $s -Mode Apply -Phase Exchange -UserPrincipalName 'other@contoso.com' | Should -Be 'other@contoso.com'
        $s.Authentication.EntraAdmin = ''
        Get-XsmExpectedAccount -Settings $s -Mode Apply -Phase Entra | Should -Be 'exo-admin@contoso.com'
        $s.Authentication.ExchangeAdmin = ''
        Get-XsmExpectedAccount -Settings $s -Mode Apply -Phase Entra | Should -BeNullOrEmpty
    }
}

Describe 'Catalogue and parsing' {
    It 'maps features and levels to Graph v1.0 capability names' {
        Get-XsmCapabilityName FreeBusy Basic | Should -BeExactly 'crossTenantCalendarAvailabilityBasic'
        Get-XsmCapabilityName MailTips All | Should -BeExactly 'crossTenantMailTipsAll'
        Get-XsmCapabilityName CalendarSharing Reviewer | Should -BeExactly 'crossTenantCalendarSharingFreeBusyReviewer'
        Get-XsmCapabilityName AnonymousCalendarSharing Simple | Should -BeExactly 'anonymousCalendarSharingFreeBusySimple'
    }
    It 'parses sharing policy entries' {
        InModuleScope XTapSharingMigration {
            $e = ConvertFrom-XsmSharingEntry 'fabrikam.com:CalendarSharingFreeBusyDetail, ContactsSharing'
            $e.Kind | Should -Be 'Domain'; $e.Domain | Should -Be 'fabrikam.com'; $e.Level | Should -Be 'Detail'; $e.Other | Should -Be @('ContactsSharing')
            (ConvertFrom-XsmSharingEntry 'Anonymous:CalendarSharingFreeBusyReviewer').Kind | Should -Be 'Anonymous'
            (ConvertFrom-XsmSharingEntry '*:CalendarSharingFreeBusySimple').Kind | Should -Be 'Wildcard'
            $s = ConvertFrom-XsmSharingEntry '*.litware.com:CalendarSharingFreeBusySimple'
            $s.Domain | Should -Be 'litware.com'; $s.Subdomains | Should -BeTrue
        }
    }
    It 'recognizes Exchange Online endpoints' {
        InModuleScope XTapSharingMigration {
            $m = @('outlook.com', 'office365.com')
            Get-XsmEndpointKind @('https://outlook.office365.com/EWS/Exchange.asmx') $m | Should -Be 'Microsoft365'
            Get-XsmEndpointKind @('outlook.com') $m | Should -Be 'Microsoft365'
            Get-XsmEndpointKind @('https://mail.tailspin.com/ews/exchange.asmx', '') $m | Should -Be 'OnPremises'
            Get-XsmEndpointKind @('', '') $m | Should -Be 'Undetermined'
        }
    }
    It 'parses scope values' {
        $specs = ConvertTo-XsmScopeSpec 'Group:FreeBusy-Fabrikam | 11111111-2222-3333-4444-555555555555' $script:Settings
        $specs.Count | Should -Be 2
        $specs[0].Kind | Should -Be 'Config'
        $specs[1].Kind | Should -Be 'Id'
        (ConvertTo-XsmScopeSpec 'All | Group:X' $script:Settings).Count | Should -Be 1
        (ConvertTo-XsmScopeSpec 'Whatever' $script:Settings)[0].Kind | Should -Be 'Invalid'
        (ConvertTo-XsmScopeSpec 'SharingPolicy:VIP' $script:Settings)[0].DisplayName | Should -Be 'SG-XTAP-SharingPolicy-VIP'
    }
}

Describe 'Classification' {
    BeforeAll { $script:Snap = Get-TestSnapshot }
    It 'excludes the hybrid organization relationship' {
        $i = Get-Item $script:Snap 'OR01-FB'
        $i.Status | Should -Be 'OutOfScope'; $i.Reason | Should -Be 'Hybrid'
    }
    It 'keeps a Microsoft 365 partner with its level and scope group' {
        $fb = Get-Item $script:Snap 'OR02-FB'
        $fb.Status | Should -Be 'InScope'; $fb.PartnerTenantId | Should -Be $TestTenant.Fabrikam
        $fb.DiscoveredLevel | Should -Be 'LimitedDetails'; $fb.DiscoveredScope | Should -Be $TestTenant.FbScopeGroup
        (Get-Item $script:Snap 'OR02-MT').DiscoveredLevel | Should -Be 'Limited'
    }
    It 'flags an on-premises partner, a disabled relationship and a domain without tenant' {
        (Get-Item $script:Snap 'OR03-FB').Reason | Should -Be 'OnPremises'
        (Get-Item $script:Snap 'OR03-FB').Overridable | Should -BeFalse
        (Get-Item $script:Snap 'OR03-FB').Notes -join ' ' | Should -Match 'mail\.tailspintoys\.com.*cannot be forced'
        (Get-Item $script:Snap 'OR04-FB').Reason | Should -Be 'Disabled'
        $northwind = @($script:Snap.Items | Where-Object { $_.SourceName -eq 'Northwind' })
        $northwind.Count | Should -Be 2
        @($northwind | Where-Object Status -eq 'InScope')[0].PartnerDomains | Should -Be @('northwind.com', 'northwindtraders.com')
        @($northwind | Where-Object Status -ne 'InScope')[0].Reason | Should -Be 'TenantNotFound'
    }
    It 'never puts hybrid or on-premises in scope, even disabled, unused or without tenant' {
        InModuleScope XTapSharingMigration {
            $b = @{ TenantId = ''; Status = 'NotFound' }
            Get-XsmAssessment -Hybrid $false -Enabled $false -Bucket $b -EndpointKind 'OnPremises' -OwnTenantId 'x' -Unused $true -NotMigratable $true | Should -Be 'OnPremises'
            Get-XsmAssessment -Hybrid $true -Enabled $false -EndpointKind 'OnPremises' -OwnTenantId 'x' | Should -Be 'Hybrid'
            foreach ($r in 'Hybrid', 'OnPremises') { $script:Reasons[$r].Overridable | Should -BeFalse }
        }
    }
    It 'creates no item for a relationship used only for mailbox moves' {
        @($script:Snap.Items | Where-Object SourceName -eq 'MoveOnly').Count | Should -Be 0
        @($script:Snap.Sources | Where-Object Name -eq 'MoveOnly')[0].Status | Should -Be 'NoSharing'
    }
    It 'classifies availability address spaces' {
        $as = Get-Item $script:Snap 'AS01-FB'
        $as.Status | Should -Be 'OutOfScope'; $as.Reason | Should -Be 'PartnerSide'; $as.Overridable | Should -BeTrue
        $as.PartnerTenantId | Should -Be $TestTenant.Adatum
        $as.XtapStatus | Should -Be 'NotApplicable'
        (Get-Item $script:Snap 'AS02-FB').Reason | Should -Be 'Hybrid'
    }
    It 'classifies sharing policy entries' {
        $anon = Get-Item $script:Snap 'SP01-01'
        $anon.Feature | Should -Be 'AnonymousCalendarSharing'; $anon.Target | Should -Be 'Default'; $anon.DiscoveredLevel | Should -Be 'Reviewer'
        (Get-Item $script:Snap 'SP01-02').Target | Should -Be 'Default'
        $fab = Get-Item $script:Snap 'SP01-03'
        $fab.Target | Should -Be 'Partner'; $fab.DiscoveredLevel | Should -Be 'Detail'; $fab.Notes -join ' ' | Should -Match 'ContactsSharing'
        (Get-Item $script:Snap 'SP01-04').Reason | Should -Be 'Consumer'
        (Get-Item $script:Snap 'SP03-01').Reason | Should -Be 'Unused'
        (Get-Item $script:Snap 'SP04-01').Reason | Should -Be 'Disabled'
    }
    It 'scopes each sharing policy to its mailboxes when several are in use' {
        (Get-Item $script:Snap 'SP01-02').DiscoveredScope | Should -Be 'SharingPolicy:Default Sharing Policy'
        (Get-Item $script:Snap 'SP02-01').DiscoveredScope | Should -Be 'SharingPolicy:VIP'
    }
    It 'compares with the X-TAP state read at collection' {
        (Get-Item $script:Snap 'OR02-MT').XtapStatus | Should -Be 'Present'
        (Get-Item $script:Snap 'SP01-01').XtapStatus | Should -Be 'PresentOtherScope'
        (Get-Item $script:Snap 'OR02-FB').XtapStatus | Should -Be 'OtherLevel'
        (Get-Item $script:Snap 'OR05-FB-1').XtapStatus | Should -Be 'Missing'
    }
}

Describe 'Decisions and Selection.csv' {
    BeforeAll { $script:Snap = Get-TestSnapshot }
    It 'proposes the items in scope only' {
        (Get-XsmItemDecision -Item (Get-Item $script:Snap 'OR02-FB') -Settings $script:Settings).Include | Should -BeTrue
        (Get-XsmItemDecision -Item (Get-Item $script:Snap 'OR03-FB') -Settings $script:Settings).Include | Should -BeFalse
    }
    It 'applies a forced level and scope (Features), then a partner rule (Partners)' {
        $s = Set-TestSettings { param($s) $s.Features.FreeBusy.Level = 'Basic'; $s.Features.FreeBusy.Scope = 'All' }
        $d = Get-XsmItemDecision -Item (Get-Item $script:Snap 'OR02-FB') -Settings $s
        $d.Level | Should -Be 'Basic'; $d.Scope | Should -Be 'All'; $d.LevelOrigin | Should -Match 'Features'
        $s.Partners.Add(@{ Match = 'fabrikam.com'; Include = $null; Features = @{ FreeBusy = @{ Level = 'LimitedDetails'; Scope = 'Group:FreeBusy-Fabrikam' } } })
        $d = Get-XsmItemDecision -Item (Get-Item $script:Snap 'OR02-FB') -Settings $s
        $d.Level | Should -Be 'LimitedDetails'; $d.Scope | Should -Be 'Group:FreeBusy-Fabrikam'; $d.ScopeOrigin | Should -Match 'Partners'
        $s.Partners.Insert(0, @{ Match = $TestTenant.Northwind; Include = $false; Features = @{} })
        (Get-XsmItemDecision -Item (Get-Item $script:Snap 'OR05-FB-1') -Settings $s).Include | Should -BeFalse
    }
    It 'excludes a feature with Migrate = $false' {
        $s = Set-TestSettings { param($s) $s.Features.MailTips.Migrate = $false }
        (Get-XsmItemDecision -Item (Get-Item $script:Snap 'OR02-MT') -Settings $s).Include | Should -BeFalse
    }
    It 'limits a run to some features with -Feature, even over Selection.csv' {
        $s = Set-TestSettings { param($s) $s.RunFeatures = @('FreeBusy', 'MailTips') }
        $target = New-XsmTargetState -Snapshot $script:Snap -Settings $s
        @($target.Capabilities | ForEach-Object Feature | Select-Object -Unique) | Sort-Object | Should -Be @('FreeBusy', 'MailTips')
        $cal = @($target.Decisions | Where-Object { $_.Item.ItemId -eq 'SP01-02' })[0].Decision
        $cal.Include | Should -BeFalse
        $cal.IncludeOrigin | Should -Match '-Feature: not in this run'
        $csv = Join-Path $script:Work 'Selection-feature.csv'
        Export-XsmSelection -Items @($script:Snap.Items) -Settings $script:Settings -Path $csv -CollectId $script:Snap.CollectId
        $sel = Import-XsmSelection -Path $csv -Snapshot $script:Snap
        @((New-XsmTargetState -Snapshot $script:Snap -Settings $s -Selection $sel).Capabilities | Where-Object Feature -eq 'CalendarSharing').Count | Should -Be 0
        # The cutover keeps the sharing policies (nothing migrated) and warns on a relationship partly migrated.
        $s2 = Set-TestSettings { param($s) $s.RunFeatures = @('FreeBusy') }
        $cut = Get-XsmCutover -Snapshot $script:Snap -Target (New-XsmTargetState -Snapshot $script:Snap -Settings $s2)
        @($cut.Steps | Where-Object Source -eq 'Sharing policy').Count | Should -Be 0
        @($cut.Steps | Where-Object Name -eq 'Fabrikam')[0].Warnings -join ' ' | Should -Match 'MailTips.*Migrate these features too'
    }
    It 'writes Selection.csv and reads it back, the file winning over the configuration' {
        $csv = Join-Path $script:Work 'Selection.csv'
        Export-XsmSelection -Items @($script:Snap.Items) -Settings $script:Settings -Path $csv -CollectId $script:Snap.CollectId
        $rows = Import-Csv $csv -Delimiter ';'
        $rows.Count | Should -Be @($script:Snap.Items).Count
        ($rows | Where-Object ItemId -eq 'OR02-FB').Include | Should -Be 'Yes'
        ($rows | Where-Object ItemId -eq 'OR03-FB').Include | Should -Be 'No'
        foreach ($r in $rows) { if ($r.ItemId -eq 'OR02-FB') { $r.Level = 'Basic'; $r.Scope = 'All' }; if ($r.ItemId -eq 'OR02-MT') { $r.Include = 'No' }; if ($r.ItemId -eq 'OR04-FB') { $r.Include = 'Yes' } }
        $rows | Where-Object ItemId -ne 'SP02-01' | Export-Csv $csv -Delimiter ',' -NoTypeInformation   # saved again by Excel with a comma, one row deleted
        $sel = Import-XsmSelection -Path $csv -Snapshot $script:Snap
        $sel.Errors.Count | Should -Be 0
        $sel.Delimiter | Should -Be ','
        $target = New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -Selection $sel
        $byId = @{}; foreach ($d in $target.Decisions) { $byId[$d.Item.ItemId] = $d.Decision }
        $byId['OR02-FB'].Level | Should -Be 'Basic'; $byId['OR02-FB'].LevelOrigin | Should -Be 'Selection.csv'
        $byId['OR02-MT'].Include | Should -BeFalse
        $byId['SP02-01'].Include | Should -BeFalse
        $byId['OR04-FB'].Include | Should -BeTrue
        $byId['OR04-FB'].Warnings -join ' ' | Should -Match 'forced'
    }
    It 'refuses hybrid and on-premises items forced in Selection.csv, and a row of another collection' {
        $csv = Join-Path $script:Work 'Selection2.csv'
        Export-XsmSelection -Items @($script:Snap.Items) -Settings $script:Settings -Path $csv -CollectId $script:Snap.CollectId
        $rows = Import-Csv $csv -Delimiter ';'
        foreach ($r in $rows) { if ($r.ItemId -in 'OR01-FB', 'OR03-FB', 'AS02-FB') { $r.Include = 'Yes' } }
        $rows | Export-Csv $csv -Delimiter ';' -NoTypeInformation
        $sel = Import-XsmSelection -Path $csv -Snapshot $script:Snap
        $target = New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -Selection $sel
        foreach ($id in 'OR01-FB', 'OR03-FB', 'AS02-FB') { @($target.Decisions | Where-Object { $_.Item.ItemId -eq $id })[0].Decision.Problems -join ' ' | Should -Match 'Cannot be migrated' }
        @($target.Capabilities | Where-Object { @($_.ItemIds) -contains 'OR03-FB' -or @($_.ItemIds) -contains 'OR01-FB' }).Count | Should -Be 0
        foreach ($r in $rows) { $r.CollectId = 'another-run' }
        $rows | Export-Csv $csv -Delimiter ';' -NoTypeInformation
        (Import-XsmSelection -Path $csv -Snapshot $script:Snap).Errors.Count | Should -BeGreaterThan 0
    }
    It 'explains why items are not migrated and which ones Selection.csv can force' {
        $sum = Get-XsmNotMigratedSummary -Decisions (New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings).Decisions
        $sum.Count | Should -Be 10
        $sum.Text | Should -Be 'out of scope: Hybrid 3, Disabled 2, Consumer 1, OnPremises 1, PartnerSide 1, TenantNotFound 1, Unused 1'
        $sum.Forceable | Should -Be 4
        $sum.ForceableText | Should -Be 'Disabled 2, PartnerSide 1, Unused 1'
        # A configuration rule and -Feature are reasons too; an item left out by -Feature is not offered for forcing.
        $s = Set-TestSettings { param($s) $s.Features.MailTips.Migrate = $false; $s.RunFeatures = @('FreeBusy', 'MailTips') }
        $sum = Get-XsmNotMigratedSummary -Decisions (New-XsmTargetState -Snapshot $script:Snap -Settings $s).Decisions
        $sum.Count | Should -Be 15
        $sum.Text | Should -Match 'Features\.MailTips\.Migrate = \$false 1; not in this run \(-Feature\) 7$'
        $sum.ForceableText | Should -Be 'Disabled 1, PartnerSide 1'
        # With Selection.csv, the file decides.
        $csv = Join-Path $script:Work 'Selection-why.csv'
        Export-XsmSelection -Items @($script:Snap.Items) -Settings $script:Settings -Path $csv -CollectId $script:Snap.CollectId
        $rows = Import-Csv $csv -Delimiter ';'
        foreach ($r in $rows) { if ($r.ItemId -eq 'OR02-FB') { $r.Include = 'No' }; if ($r.ItemId -eq 'OR04-FB') { $r.Include = 'Yes' } }
        $rows | Export-Csv $csv -Delimiter ';' -NoTypeInformation
        $sel = Import-XsmSelection -Path $csv -Snapshot $script:Snap
        $sum = Get-XsmNotMigratedSummary -Decisions (New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -Selection $sel).Decisions
        $sum.Text | Should -Be 'Include = No in Selection.csv 10'
        $sum.ForceableText | Should -Be 'Disabled 1, PartnerSide 1, Unused 1'
        (Get-XsmNotMigratedSummary -Decisions @()).Count | Should -Be 0
    }
}

Describe 'Target configuration' {
    BeforeAll {
        $script:Snap = Get-TestSnapshot
        $script:Target = New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -MailboxesByPolicy (Import-XsmSharingPolicyMailboxes $script:Snap)
    }
    It 'creates one capability per policy and level' {
        $names = @($script:Target.Capabilities | ForEach-Object { "$($_.Target)|$($_.PartnerTenantId)|$($_.Capability)" })
        $names | Should -Contain "Partner|$($TestTenant.Fabrikam)|crossTenantCalendarAvailabilityLimitedDetails"
        $names | Should -Contain "Partner|$($TestTenant.Fabrikam)|crossTenantMailTipsLimited"
        $names | Should -Contain "Partner|$($TestTenant.Fabrikam)|crossTenantCalendarSharingFreeBusyDetail"
        $names | Should -Contain "Partner|$($TestTenant.Northwind)|crossTenantCalendarAvailabilityBasic"
        $names | Should -Not -Contain "Partner|$($TestTenant.Adatum)|crossTenantCalendarAvailabilityBasic"   # availability address space: the partner configures it
        $names | Should -Contain 'Default||anonymousCalendarSharingFreeBusyReviewer'
        $names | Should -Contain 'Default||crossTenantCalendarSharingFreeBusySimple'
        $names | Should -Contain 'Default||crossTenantCalendarSharingFreeBusyReviewer'
    }
    It 'lists one trust per partner and the groups with their members' {
        @($script:Target.Trusts).Count | Should -Be 2
        $vip = @($script:Target.Groups | Where-Object Kind -eq 'SharingPolicy' | Where-Object Policy -eq 'VIP')[0]
        $vip.DisplayName | Should -Be 'SG-XTAP-SharingPolicy-VIP'
        $vip.MemberIds.Count | Should -Be 2
        $vip.Create | Should -BeTrue
    }
    It 'keeps All when items of the same capability have different scopes' {
        $s = Set-TestSettings { param($s) $s.Features.FreeBusy.Level = 'Basic' }
        $snap = Get-TestSnapshot $s
        $t = New-XsmTargetState -Snapshot $snap -Settings $s
        $cap = @($t.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'FreeBusy' })[0]
        $cap.Specs[0].Kind | Should -Be 'Id'
    }
    It 'merges several organization relationships and domains of one tenant into one partner configuration' {
        $snap = New-TestSnapshot
        foreach ($d in 'fabrikam.eu', 'fabrikam.de', 'fabrikam-group.com') {
            $snap.Domains[$d] = [ordered]@{ Domain = $d; Status = 'Resolved'; TenantId = $TestTenant.Fabrikam; DisplayName = 'Fabrikam'; DefaultDomain = ''; Cloud = 'microsoftonline.com'; Region = 'EU'; Source = 'Test'; Error = '' }
        }
        $snap.Exchange.OrganizationRelationships = @($snap.Exchange.OrganizationRelationships) + @(
            (New-TestOrgRel 'Fabrikam Europe' @('fabrikam.eu', 'fabrikam.de') -FB $true -FBLevel 'LimitedDetails' -MT $true -MTLevel 'Limited' -AppUri 'outlook.com')
            (New-TestOrgRel 'Fabrikam Group' @('fabrikam-group.com') -FB $true -FBLevel 'LimitedDetails' -AppUri 'outlook.com'))
        $class = Get-XsmMigrationItems -Snapshot $snap -Settings $script:Settings
        $snap.Items = $class.Items
        $fab = @($snap.Items | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Source -eq 'OrganizationRelationship' })
        $fab.Count | Should -Be 5                                   # 3 relationships: Free/Busy x3, MailTips x2
        @($fab | Where-Object SourceName -eq 'Fabrikam Europe' | Where-Object Feature -eq 'FreeBusy').Count | Should -Be 1   # 2 domains, one tenant: one item
        $target = New-XsmTargetState -Snapshot $snap -Settings $script:Settings
        @($target.Trusts | Where-Object TenantId -eq $TestTenant.Fabrikam).Count | Should -Be 1
        $fb = @($target.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Capability -eq 'crossTenantCalendarAvailabilityLimitedDetails' })
        $fb.Count | Should -Be 1
        $fb[0].ItemIds.Count | Should -Be 3
        $fb[0].PartnerDomains | Should -Contain 'fabrikam.de'
        $fb[0].PartnerDomains | Should -Contain 'fabrikam-group.com'
        $fb[0].Specs[0].Kind | Should -Be 'All'                     # scope group on one relationship, none on the others: All
        $target.Warnings -join ' ' | Should -Match 'All users is kept'
        @($target.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'MailTips' }).Count | Should -Be 1
        $partners = @(Get-XsmPartnerSummary -Snapshot $snap -Settings $script:Settings | Where-Object TenantId -eq $TestTenant.Fabrikam)
        $partners.Count | Should -Be 1
        $partners[0].Domains.Count | Should -Be 4
    }
}

Describe 'Plan and apply against an in-memory tenant' {
    BeforeEach {
        $script:Fake = New-FakeTenant
        Set-FakeGraph $script:Fake
        $script:Snap = Get-TestSnapshot
        $script:Target = New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -MailboxesByPolicy (Import-XsmSharingPolicyMailboxes $script:Snap)
    }
    It 'plans the Entra and Exchange actions' {
        $live = Get-XsmLiveState -Target $script:Target -Members
        $actions = New-XsmActions -Target $script:Target -Live $live -Settings $script:Settings -Phase All
        $trustFab = @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.PartnerTenantId -eq $TestTenant.Fabrikam })[0]
        $trustFab.Operation | Should -Be 'NoChange'
        @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.PartnerTenantId -eq $TestTenant.Northwind })[0].Operation | Should -Be 'Create'
        $anon = @($actions | Where-Object { $_.Capability -eq 'anonymousCalendarSharingFreeBusyReviewer' })[0]
        $anon.Operation | Should -Be 'Conflict'    # All today, the target is the Default Sharing Policy mailboxes: kept (ExistingCapability = Keep)
        $anon.Before | Should -Be 'All users'
        $anon.Detail | Should -Match 'Keep'
        $fb = @($actions | Where-Object { $_.Capability -eq 'crossTenantCalendarAvailabilityLimitedDetails' })[0]
        $fb.Operation | Should -Be 'Create'
        $fb.Notes -join ' ' | Should -Match 'crossTenantCalendarAvailabilityBasic is also allowed'
        @($actions | Where-Object { $_.Kind -eq 'Group' }).Operation | Should -Contain 'Create'
        # An Apply of phase Entra does not count the Exchange conflict as its own problem.
        $c = Get-XsmActionCounts (New-XsmActions -Target $script:Target -Live $live -Settings $script:Settings -Phase Entra)
        $c.Blocked | Should -BeGreaterThan 0
        $c.BlockedInPhase | Should -Be 0
    }
    It 'blocks the Exchange phase until the Entra phase is done' {
        $live = Get-XsmLiveState -Target $script:Target
        $actions = New-XsmActions -Target $script:Target -Live $live -Settings $script:Settings -Phase Exchange
        $nw = @($actions | Where-Object { $_.Kind -eq 'Capability' -and $_.PartnerTenantId -eq $TestTenant.Northwind })[0]
        $nw.Operation | Should -Be 'Blocked'; $nw.Detail | Should -Match 'Phase Entra'
        $vip = @($actions | Where-Object { $_.Capability -eq 'crossTenantCalendarSharingFreeBusyReviewer' })[0]
        $vip.Operation | Should -Be 'Blocked'
        @($actions | Where-Object Phase -eq 'Entra' | Where-Object Status -eq 'ToDo').Count | Should -Be 0
        @($actions | Where-Object Phase -eq 'Entra' | Where-Object Status -eq 'OtherPhase').Count | Should -BeGreaterThan 0
    }
    It 'applies Entra then Exchange, and everything is in place afterwards' {
        $s = Set-TestSettings { param($s) $s.Apply.ExistingCapability = 'Replace' }
        foreach ($phase in 'Entra', 'Exchange') {
            $live = Get-XsmLiveState -Target $script:Target -Members:($phase -eq 'Entra')
            $actions = New-XsmActions -Target $script:Target -Live $live -Settings $s -Phase $phase
            $ids = Invoke-XsmActions -Actions $actions -Live $live 6>$null
            @($actions | Where-Object Status -eq 'Failed').Count | Should -Be 0
            $after = New-XsmActions -Target $script:Target -Live (Get-XsmLiveState -Target $script:Target -Members:($phase -eq 'Entra') -KnownGroupIds $ids) -Settings $s -Phase $phase
            Set-XsmVerification -Actions $actions -After $after
            @($actions | Where-Object { $_.Status -eq 'Done' -and $_.Verified -notlike 'Verified*' }).Count | Should -Be 0
        }
        $final = New-XsmActions -Target $script:Target -Live (Get-XsmLiveState -Target $script:Target -Members) -Settings $s -Phase All
        @($final | Where-Object Operation -ne 'NoChange').Operation | Should -BeNullOrEmpty
        $fakeNw = $script:Fake.Partners[$TestTenant.Northwind]
        $fakeNw.m365CollaborationInbound.users.targets[0].target | Should -Be 'AllUsers'
        $vipGroup = @($script:Fake.Groups.Values | Where-Object displayName -eq 'SG-XTAP-SharingPolicy-VIP')[0]
        $vipGroup.members.Count | Should -Be 2
        $cap = $script:Fake.Default.Caps['crossTenantCalendarSharingFreeBusyReviewer']
        $cap.inboundAccess.resourceScopes.included[0].resourceId | Should -Be $vipGroup.id
        $script:Fake.Calls | Where-Object { $_ -match 'beta' } | Should -BeNullOrEmpty
        # The summary of an Apply counts what is already in place in its own phase only.
        $entra = New-XsmActions -Target $script:Target -Live (Get-XsmLiveState -Target $script:Target -Members) -Settings $s -Phase Entra
        $counts = Get-XsmActionCounts $entra
        $counts.NoChange | Should -Be $entra.Count
        $counts.NoChangeInPhase | Should -Be @($entra | Where-Object Phase -eq 'Entra').Count
        $counts.NoChangeInPhase | Should -BeLessThan $counts.NoChange
        # Everything in place: each phase says so, by name.
        $x = Get-XsmPhaseExplanation -Target $script:Target -Actions $entra -Phase Entra
        $x.Reason | Should -Be 'InPlace'
        $x.Short | Should -Match 'trust of Northwind Traders'
        (Get-XsmPhaseExplanation -Target $script:Target -Actions $entra -Phase Exchange).Reason | Should -Be 'InPlace'
    }
    It 'explains why a phase has nothing to change' {
        # Only the Anonymous and * entries of the default sharing policy, for All users: no trust, no group.
        $csv = Join-Path $script:Work 'Selection-default.csv'
        Export-XsmSelection -Items @($script:Snap.Items) -Settings $script:Settings -Path $csv -CollectId $script:Snap.CollectId
        $rows = Import-Csv $csv -Delimiter ';'
        foreach ($r in $rows) { $r.Include = $(if ($r.ItemId -in 'SP01-01', 'SP01-02') { 'Yes' } else { 'No' }); if ($r.ItemId -in 'SP01-01', 'SP01-02') { $r.Scope = 'All' } }
        $rows | Export-Csv $csv -Delimiter ';' -NoTypeInformation
        $target = New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -Selection (Import-XsmSelection -Path $csv -Snapshot $script:Snap)
        @($target.Trusts).Count | Should -Be 0
        @($target.Groups).Count | Should -Be 0
        $actions = New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target -Members) -Settings $script:Settings -Phase Entra
        @($actions | Where-Object Phase -eq 'Entra').Count | Should -Be 0
        $x = Get-XsmPhaseExplanation -Target $target -Actions $actions -Phase Entra
        $x.Reason | Should -Be 'NotNeeded'
        $x.Lines -join ' ' | Should -Match 'DEFAULT cross-tenant access policy'
        $x.Lines -join ' ' | Should -Match 'anonymous calendar publishing'
        $x.Lines -join ' ' | Should -Match 'every external organization'
        $x.Next | Should -Match '-Phase Exchange'
        Get-XsmPhaseExplanation -Target $target -Actions $actions -Phase Exchange | Should -BeNullOrEmpty
        # No item at all.
        foreach ($r in $rows) { $r.Include = 'No' }
        $rows | Export-Csv $csv -Delimiter ';' -NoTypeInformation
        $none = New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -Selection (Import-XsmSelection -Path $csv -Snapshot $script:Snap)
        (Get-XsmPhaseExplanation -Target $none -Actions @() -Phase Entra).Reason | Should -Be 'NoItem'
        # Phase Exchange run first: the capabilities that wait for the Entra phase are blocked, and the next step says so.
        $live = Get-XsmLiveState -Target $script:Target
        $exo = New-XsmActions -Target $script:Target -Live $live -Settings $script:Settings -Phase Exchange
        foreach ($a in $exo) { if ($a.Phase -eq 'Exchange' -and $a.Operation -ne 'Blocked') { $a.Operation = 'NoChange' } }
        $x = Get-XsmPhaseExplanation -Target $script:Target -Actions $exo -Phase Exchange
        $x.Reason | Should -Be 'Blocked'
        $x.Next | Should -Match '-Phase Entra first'
        Get-XsmPhaseExplanation -Target $script:Target -Actions $exo -Phase Entra | Should -BeNullOrEmpty
    }
    It 'adds the missing members of a sharing policy group without removing any' {
        $live = Get-XsmLiveState -Target $script:Target -Members
        $a = New-XsmActions -Target $script:Target -Live $live -Settings $script:Settings -Phase Entra
        $null = Invoke-XsmActions -Actions $a -Live $live 6>$null
        $g = @($script:Fake.Groups.Values | Where-Object displayName -eq 'SG-XTAP-SharingPolicy-VIP')[0]
        $g.members.RemoveAt(0); $g.members.Add('99999999-0000-0000-0000-000000000099')
        $actions = New-XsmActions -Target $script:Target -Live (Get-XsmLiveState -Target $script:Target -Members) -Settings $script:Settings -Phase Entra
        $add = @($actions | Where-Object { $_.Kind -eq 'Group' -and $_.Target -eq 'SG-XTAP-SharingPolicy-VIP' })[0]
        $add.Operation | Should -Be 'AddMembers'
        $add.Notes -join ' ' | Should -Match 'never removes'
    }
    It 'keeps, merges or replaces a capability that exists with another scope' {
        # Fabrikam MailTips exists today for the group FB-Scope; the target is the configuration group FreeBusy-Fabrikam.
        $script:Fake.Partners[$TestTenant.Fabrikam].Caps['crossTenantMailTipsLimited'] = New-FakeCapability 'crossTenantMailTipsLimited' $true @(@{ resourceId = $TestTenant.FbScopeGroup; resourceType = 'group' })
        $keep = Set-TestSettings { param($s) $s.Features.MailTips.Scope = 'Group:FreeBusy-Fabrikam' }
        $snap = Get-TestSnapshot $keep
        $target = New-XsmTargetState -Snapshot $snap -Settings $keep
        $mt = { param($list) @($list | Where-Object Capability -eq 'crossTenantMailTipsLimited')[0] }
        (& $mt (New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target) -Settings $keep -Phase All)).Operation | Should -Be 'Conflict'
        $merge = Set-TestSettings { param($s) $s.Features.MailTips.Scope = 'Group:FreeBusy-Fabrikam'; $s.Apply.ExistingCapability = 'Merge' }
        foreach ($phase in 'Entra', 'Exchange') {
            $live = Get-XsmLiveState -Target $target
            $actions = New-XsmActions -Target $target -Live $live -Settings $merge -Phase $phase
            if ($phase -eq 'Exchange') { (& $mt $actions).Operation | Should -Be 'Update'; (& $mt $actions).After | Should -Match 'FB-Scope.*merged' }
            $null = Invoke-XsmActions -Actions $actions -Live $live 6>$null
        }
        $included = @($script:Fake.Partners[$TestTenant.Fabrikam].Caps['crossTenantMailTipsLimited'].inboundAccess.resourceScopes.included | ForEach-Object { $_.resourceId })
        $included.Count | Should -Be 2
        $included | Should -Contain $TestTenant.FbScopeGroup
        (& $mt (New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target) -Settings $merge -Phase All)).Operation | Should -Be 'NoChange'
        $replace = Set-TestSettings { param($s) $s.Features.MailTips.Scope = 'Group:FreeBusy-Fabrikam'; $s.Apply.ExistingCapability = 'Replace' }
        (& $mt (New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target) -Settings $replace -Phase All)).Operation | Should -Be 'Update'
    }
    It 'respects DisableOtherLevels and a blocked trust' {
        $s = Set-TestSettings { param($s) $s.Apply.DisableOtherLevels = $true }
        $live = Get-XsmLiveState -Target $script:Target
        $actions = New-XsmActions -Target $script:Target -Live $live -Settings $s -Phase All
        $disable = @($actions | Where-Object Operation -eq 'Disable')
        $disable.Capability | Should -Contain 'crossTenantCalendarAvailabilityBasic'
        $script:Fake.Partners[$TestTenant.Fabrikam].m365CollaborationInbound = @{ users = @{ accessType = 'blocked'; targets = @(@{ target = 'AllUsers'; targetType = 'user' }) } }
        $actions = New-XsmActions -Target $script:Target -Live (Get-XsmLiveState -Target $script:Target) -Settings $script:Settings -Phase All
        @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.PartnerTenantId -eq $TestTenant.Fabrikam })[0].Operation | Should -Be 'Conflict'
        @($actions | Where-Object { $_.Kind -eq 'Capability' -and $_.PartnerTenantId -eq $TestTenant.Fabrikam })[0].Operation | Should -Be 'Blocked'
    }
    It 'reports a failure and skips what depends on it' {
        $script:Fake.FailOn = 'POST /policies/crossTenantAccessPolicy/partners$'
        $live = Get-XsmLiveState -Target $script:Target -Members
        $actions = New-XsmActions -Target $script:Target -Live $live -Settings $script:Settings -Phase All
        $null = Invoke-XsmActions -Actions $actions -Live $live 6>$null
        @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.Operation -eq 'Create' })[0].Status | Should -Be 'Failed'
        @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.Operation -eq 'Create' })[0].Error | Should -Match 'Security Administrator'
        @($actions | Where-Object { $_.Kind -eq 'Capability' -and $_.PartnerTenantId -eq $TestTenant.Northwind })[0].Status | Should -Be 'Skipped'
    }
}

Describe 'Partner tenant ID confirmation' {
    BeforeEach {
        $script:Fake = New-FakeTenant
        Set-FakeGraph $script:Fake
    }
    It 'finds the source of each confirmation' {
        $snap = Get-TestSnapshot
        $partners = @(Get-XsmPartnerSummary -Snapshot $snap -Settings $script:Settings)
        $by = @{}; foreach ($p in $partners) { $by[$p.TenantId] = $p }
        $by[$TestTenant.Northwind].Confirmation | Should -Be 'Confirmed'
        $by[$TestTenant.Northwind].ConfirmationSource | Should -Match 'Partners rule'
        $by[$TestTenant.Fabrikam].ConfirmationSource | Should -Match 'existing partner policy'
        $by[$TestTenant.Adatum].ConfirmationSource | Should -Match 'availability address space'
        $by[$TestTenant.Adatum].PartnerSideOnly | Should -BeTrue
        $by[$TestTenant.Adatum].PartnerConfigures[0] | Should -Match 'crossTenantCalendarAvailabilityBasic for your tenant ID'
        $file = Join-Path $script:Work 'PartnersToConfirm.txt'
        Export-XsmPartnerSnippet -Partners $partners -Path $file -Settings $script:Settings
        $text = Get-Content $file -Raw
        $text | Should -Match "Match = 'northwind.com'; TenantId = '$($TestTenant.Northwind)'"
        $text | Should -Match 'Your tenant ID'
    }
    It 'blocks an unconfirmed partner in the Entra and Exchange phases' {
        $s = Set-TestSettings { param($s) $s.Partners.Clear() }
        $snap = Get-TestSnapshot $s
        $target = New-XsmTargetState -Snapshot $snap -Settings $s
        $actions = New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target) -Settings $s -Phase All
        $trust = @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.PartnerTenantId -eq $TestTenant.Northwind })[0]
        $trust.Operation | Should -Be 'Blocked'
        $trust.Detail | Should -Match "TenantId = '$($TestTenant.Northwind)'"
        @($actions | Where-Object { $_.Kind -eq 'Capability' -and $_.PartnerTenantId -eq $TestTenant.Northwind })[0].Operation | Should -Be 'Blocked'
        @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.PartnerTenantId -eq $TestTenant.Fabrikam })[0].Operation | Should -Be 'NoChange'
        $s.Entra.RequireConfirmedPartners = $false
        $actions = New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target) -Settings $s -Phase All
        @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.PartnerTenantId -eq $TestTenant.Northwind })[0].Operation | Should -Be 'Create'
    }
    It 'stops when the tenant ID given by the partner differs from the one of its domain' {
        $s = Set-TestSettings { param($s) $s.Partners.Clear(); $s.Partners.Add(@{ Match = 'northwind.com'; TenantId = '99999999-0000-4000-8000-000000000999'; Name = ''; Include = $null; Features = @{} }) }
        $snap = Get-TestSnapshot $s
        $target = New-XsmTargetState -Snapshot $snap -Settings $s
        $actions = New-XsmActions -Target $target -Live (Get-XsmLiveState -Target $target) -Settings $s -Phase All
        $trust = @($actions | Where-Object { $_.Kind -eq 'Trust' -and $_.PartnerTenantId -eq $TestTenant.Northwind })[0]
        $trust.Operation | Should -Be 'Blocked'
        $trust.Detail | Should -Match 'confirmed tenant ID 99999999'
    }
}

Describe 'Level choices' {
    BeforeAll {
        function New-ConflictSnapshot {
            # Fabrikam: LimitedDetails for the group FB-Scope (relationship Fabrikam), AvailabilityOnly for everybody (Fabrikam Legacy).
            $snap = New-TestSnapshot
            $snap.Domains['fabrikam.eu'] = [ordered]@{ Domain = 'fabrikam.eu'; Status = 'Resolved'; TenantId = $TestTenant.Fabrikam; DisplayName = 'Fabrikam'; DefaultDomain = ''; Cloud = 'microsoftonline.com'; Region = 'EU'; Source = 'Test'; Error = '' }
            $snap.Exchange.OrganizationRelationships = @($snap.Exchange.OrganizationRelationships) + @((New-TestOrgRel 'Fabrikam Legacy' @('fabrikam.eu') -FB $true -FBLevel 'AvailabilityOnly' -AppUri 'outlook.com'))
            $class = Get-XsmMigrationItems -Snapshot $snap -Settings $script:Settings
            $snap.Items = $class.Items; $snap.Sources = $class.Sources
            $dir = Join-Path $script:Work ('conflict-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($dir)
            Save-XsmJson $snap (Join-Path $dir 'snapshot.json')
            return Import-XsmSnapshot -Path $dir -Settings $script:Settings
        }
    }
    It 'detects several levels for the same partner and feature, and blocks only these items' {
        $snap = New-ConflictSnapshot
        $target = New-XsmTargetState -Snapshot $snap -Settings $script:Settings
        $c = @($target.Conflicts | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'FreeBusy' })
        $c.Count | Should -Be 1
        @($c[0].Options | ForEach-Object Level) | Should -Be @('Basic', 'LimitedDetails')
        $c[0].Options[0].Sources | Should -Be @('Fabrikam Legacy')
        $blocked = @($target.Decisions | Where-Object { $_.Item.ItemId -in $c[0].ItemIds })
        $blocked.Count | Should -Be 2
        foreach ($b in $blocked) { $b.Decision.Problems -join ' ' | Should -Match 'Several levels of FreeBusy' }
        @($target.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'FreeBusy' }).Count | Should -Be 0
        @($target.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'MailTips' }).Count | Should -Be 1   # the rest goes on
    }
    It 'applies the recorded choice to every item of the conflict, and keeps it for the next runs' {
        $snap = New-ConflictSnapshot
        $key = (New-XsmTargetState -Snapshot $snap -Settings $script:Settings).Conflicts[0].Key
        $choices = @{ $key = [ordered]@{ Key = $key; Level = 'LimitedDetails'; By = 'admin@contoso.onmicrosoft.com' } }
        Save-XsmLevelChoices -Snapshot $snap -Choices $choices
        $loaded = Import-XsmLevelChoices -Snapshot $snap
        $target = New-XsmTargetState -Snapshot $snap -Settings $script:Settings -LevelChoices $loaded
        $target.Conflicts[0].Chosen | Should -Be 'LimitedDetails'
        $fb = @($target.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'FreeBusy' })
        $fb.Count | Should -Be 1
        $fb[0].Capability | Should -Be 'crossTenantCalendarAvailabilityLimitedDetails'
        $fb[0].ItemIds.Count | Should -Be 2
        $fb[0].Specs[0].Kind | Should -Be 'All'
        @($target.Decisions | Where-Object { $_.Item.ItemId -in $target.Conflicts[0].ItemIds })[0].Decision.LevelOrigin | Should -Match 'Administrator choice \(admin@contoso'
    }
    It 'asks the administrator and records the answer; Enter leaves the items blocked' {
        $snap = New-ConflictSnapshot
        $target = New-XsmTargetState -Snapshot $snap -Settings $script:Settings
        $choices = @{}
        Mock Read-Host { '' } -ModuleName XTapSharingMigration
        Request-XsmLevelChoices -Conflicts @($target.Conflicts) -Choices $choices -Account 'admin@contoso.onmicrosoft.com' 6>$null | Should -Be 0
        $choices.Count | Should -Be 0
        Mock Read-Host { '2' } -ModuleName XTapSharingMigration
        Request-XsmLevelChoices -Conflicts @($target.Conflicts) -Choices $choices -Account 'admin@contoso.onmicrosoft.com' 6>$null | Should -Be 1
        $choices[$target.Conflicts[0].Key].Level | Should -Be 'LimitedDetails'
        $choices[$target.Conflicts[0].Key].By | Should -Be 'admin@contoso.onmicrosoft.com'
    }
    It 'needs no choice when the level is set in a Partners rule, nor for sharing policies scoped to their own groups' {
        $snap = New-ConflictSnapshot
        $s = Set-TestSettings { param($s) $s.Partners.Add(@{ Match = 'fabrikam.com'; TenantId = ''; Name = ''; Include = $null; Features = @{ FreeBusy = @{ Level = 'Basic' } } }) }
        $target = New-XsmTargetState -Snapshot $snap -Settings $s
        @($target.Conflicts).Count | Should -Be 0
        @($target.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'FreeBusy' })[0].Capability | Should -Be 'crossTenantCalendarAvailabilityBasic'
        # Default policy: Simple for the Default Sharing Policy mailboxes, Reviewer for VIP - different groups, two capabilities.
        $default = @($target.Capabilities | Where-Object { $_.Target -eq 'Default' -and $_.Feature -eq 'CalendarSharing' })
        $default.Count | Should -Be 2
    }
    It 'flags the rows of Selection.csv that need a level' {
        $snap = New-ConflictSnapshot
        $csv = Join-Path $script:Work 'Selection-conflict.csv'
        Export-XsmSelection -Items @($snap.Items) -Settings $script:Settings -Path $csv -CollectId $snap.CollectId
        $rows = @(Import-Csv $csv -Delimiter ';' | Where-Object { $_.Notes -like 'LEVEL TO CHOOSE*' })
        $rows.Count | Should -Be 2
        foreach ($r in $rows) { $r.Level = 'Basic' }
        $all = @(Import-Csv $csv -Delimiter ';' | Where-Object { $_.Notes -notlike 'LEVEL TO CHOOSE*' }) + $rows
        $all | Export-Csv $csv -Delimiter ';' -NoTypeInformation
        $target = New-XsmTargetState -Snapshot $snap -Settings $script:Settings -Selection (Import-XsmSelection -Path $csv -Snapshot $snap)
        @($target.Conflicts).Count | Should -Be 0
        @($target.Capabilities | Where-Object { $_.PartnerTenantId -eq $TestTenant.Fabrikam -and $_.Feature -eq 'FreeBusy' })[0].Capability | Should -Be 'crossTenantCalendarAvailabilityBasic'
    }
}
Describe 'Reports' {
    BeforeAll {
        $script:Fake = New-FakeTenant
        Set-FakeGraph $script:Fake
        $script:Snap = Get-TestSnapshot
        $script:Target = New-XsmTargetState -Snapshot $script:Snap -Settings $script:Settings -MailboxesByPolicy (Import-XsmSharingPolicyMailboxes $script:Snap)
    }
    It 'writes the manual cutover commands with the rollback, keeping the entries not migrated' {
        $cut = Get-XsmCutover -Snapshot $script:Snap -Target $script:Target
        $default = @($cut.Steps | Where-Object Name -eq 'Default Sharing Policy')[0]
        $default.Commands[0] | Should -Match "Set-SharingPolicy -Identity 'Default Sharing Policy' -Domains 'fabrikam.com:ContactsSharing', 'outlook.com:CalendarSharingFreeBusySimple'"
        $default.Rollback[0] | Should -Match "Anonymous:CalendarSharingFreeBusyReviewer"
        $fab = @($cut.Steps | Where-Object Name -eq 'Fabrikam')[0]
        $fab.Commands[0] | Should -Be "Set-OrganizationRelationship -Identity 'Fabrikam' -Enabled `$false"
        $nw = @($cut.Steps | Where-Object Name -eq 'Northwind')[0]
        $nw.Warnings -join ' ' | Should -Match 'not migrated'
        @($cut.Steps | Where-Object Name -eq 'Tailspin').Count | Should -Be 0
        $file = Join-Path $script:Work 'ManualCutover.txt'
        Export-XsmCutoverText -Cutover $cut -Path $file -Settings $script:Settings
        (Get-Content $file -Raw) | Should -Match 'Your tenant ID'
        $aas = @($cut.Steps | Where-Object Name -eq 'adatum.com')[0]
        $aas.Commands[1] | Should -Match 'Remove-AvailabilityAddressSpace'
        $aas.Warnings[0] | Should -Match 'only after the partner has allowed'
        @($cut.Partners | Where-Object TenantId -eq $TestTenant.Adatum)[0].PartnerConfigures.Count | Should -Be 1
        @($cut.Steps | Where-Object Name -eq 'contoso.com').Count | Should -Be 0   # hybrid address space
    }
    It 'embeds the data in the HTML template safely' {
        $data = New-XsmReportData -Kind Plan -Settings $script:Settings -Snapshot $script:Snap -Phase All
        $data.Items = ConvertTo-XsmReportItems -Items @($script:Snap.Items) -Settings $script:Settings -Decisions $script:Target.Decisions
        $data.Warnings = @('</script><script>alert(1)</script>')
        $file = Join-Path $script:Work 'Plan.html'
        New-XsmHtmlReport -Data $data -Path $file
        $html = Get-Content $file -Raw
        $html | Should -Not -Match '/\*XSM_DATA\*/'
        $json = [regex]::Match($html, '(?s)<script type="application/json" id="xsm-data">(.*?)</script>').Groups[1].Value
        ($json | ConvertFrom-Json).Warnings[0] | Should -Be '</script><script>alert(1)</script>'
        $html | Should -Not -Match 'https?://(?!graph\.microsoft\.com|learn\.microsoft\.com)[a-z]'   # no external resource
    }
}

Describe 'Safety' {
    It 'never calls the beta endpoint of Microsoft Graph' {
        { InModuleScope XTapSharingMigration { Invoke-XsmGraph GET 'https://graph.microsoft.com/beta/policies' } } | Should -Throw '*beta*'
        $files = Get-ChildItem (Join-Path $script:Root 'src'), $script:Root, (Join-Path $script:RepoRoot 'tools') -Filter '*.ps*1' -File
        foreach ($f in $files) {
            $text = [IO.File]::ReadAllText($f.FullName)
            $text | Should -Not -Match 'Microsoft\.Graph\.Beta|Invoke-MgBeta|Get-MgBeta|New-MgBeta|Update-MgBeta'
            ($text -replace "\^https://graph\\\.microsoft\\\.com/beta", '') | Should -Not -Match 'graph\.microsoft\.com/beta'
        }
    }
    It 'never changes Exchange Online objects' {
        $files = Get-ChildItem (Join-Path $script:Root 'src') -Filter '*.ps1' -File
        foreach ($f in $files) {
            foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
                # Commands written in the reports are text: string literals and comments are not checked.
                $code = ($line -replace '"[^"]*"', '""' -replace "'[^']*'", "''" -replace '#.*$', '')
                $code | Should -Not -Match '\b(Set|New|Remove|Add|Enable|Disable)-(XsmExo)?(OrganizationRelationship|SharingPolicy|AvailabilityAddressSpace)\b'
            }
        }
    }
    It 'uses only console-font characters outside the emoji style' {
        InModuleScope XTapSharingMigration {
            [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
            $cp437 = [Text.Encoding]::GetEncoding(437)
            # Glyphs of code page 437 in the control positions (0x01-0x1F, 0x7F): .NET maps these bytes to control characters.
            $controlGlyphs = [string]::new([char[]](0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022, 0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C, 0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21A8, 0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC, 0x2302))
            foreach ($style in 'Symbols', 'Ascii') {
                $set = Get-XsmIconSet $style
                $frame = Get-XsmFrameSet $style
                foreach ($value in @($set.Values) + @($frame.Values | ForEach-Object { [string]$_ })) {
                    foreach ($ch in $value.ToCharArray()) {
                        $inLatin1 = [int]$ch -le 0xFF
                        $inCp437 = $cp437.GetString($cp437.GetBytes([string]$ch)) -eq [string]$ch -or $controlGlyphs.Contains($ch)
                        ($inLatin1 -or $inCp437) | Should -BeTrue -Because "'$ch' (U+$(([int]$ch).ToString('X4'))) in style $style must exist in the console fonts"
                    }
                }
            }
        }
    }
    It 'applies only after YES, in any case; any other answer cancels' {
        foreach ($answer in 'YES', 'yes', 'Yes', '  yes ') { Test-XsmConfirmation $answer | Should -BeTrue -Because "'$answer' confirms" }
        foreach ($answer in '', $null, 'y', 'no', 'oui', 'YES!', 'yes please') { Test-XsmConfirmation $answer | Should -BeFalse -Because "'$answer' cancels" }
    }
}
