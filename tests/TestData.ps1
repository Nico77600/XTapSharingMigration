<#
    X-TAP Sharing Migration - test data: a fictitious tenant (Contoso) and its partners.
    Used by XTapSharingMigration.Tests.ps1. No real tenant, domain or person.

    Organization relationships            Expected
      1 O365 to On-premises - ...         Hybrid (HCW name, own domain)
      2 Fabrikam                          in scope: Free/Busy LimitedDetails (scope group), MailTips Limited
      3 Tailspin                          OnPremises (endpoint not Exchange Online)
      4 Old partner                       Disabled
      5 Northwind                         2 domains of one tenant in scope + 1 domain without tenant
      6 MoveOnly                          nothing to migrate (mailbox moves only)
    Availability address spaces
      1 adatum.com  OrgWideFBToken        in scope
      2 contoso.com InternalProxy         Hybrid
    Sharing policies (mailboxes)
      1 Default Sharing Policy (3)        Anonymous Reviewer, * Simple, fabrikam.com Detail + ContactsSharing, outlook.com (consumer)
      2 VIP (2)                           * Reviewer
      3 Unused (0)                        litware.com Simple -> Unused
      4 Disabled policy (0, disabled)     northwind.com Simple -> Disabled
#>

$TestTenant = @{
    Id           = 'aaaaaaaa-0000-4000-8000-000000000001'
    Fabrikam     = 'bbbbbbbb-0000-4000-8000-000000000002'
    Northwind    = 'cccccccc-0000-4000-8000-000000000003'
    Adatum       = 'dddddddd-0000-4000-8000-000000000004'
    Litware      = 'eeeeeeee-0000-4000-8000-000000000005'
    Tailspin     = 'ffffffff-0000-4000-8000-000000000006'
    FbScopeGroup = '11111111-0000-4000-8000-0000000000aa'
    Mailboxes    = @{
        'Default Sharing Policy' = @('22222222-0000-4000-8000-000000000001', '22222222-0000-4000-8000-000000000002', '22222222-0000-4000-8000-000000000003')
        'VIP'                    = @('33333333-0000-4000-8000-000000000001', '33333333-0000-4000-8000-000000000002')
    }
}

function New-TestConfiguration {
    <# The delivered configuration file with fictitious tenant values, a test output folder and one group. #>
    param([Parameter(Mandatory)][string]$Directory)
    $root = Split-Path $PSScriptRoot -Parent
    $text = [IO.File]::ReadAllText((Join-Path $root 'config\XTapSharingMigration.config.psd1'))
    $values = [ordered]@{ TenantId = $TestTenant.Id; Organization = 'contoso.onmicrosoft.com' }
    foreach ($key in $values.Keys) {
        $pattern = "(?m)^(\s*$key\s*=\s*)'[^']*'"
        if ([regex]::Matches($text, $pattern).Count -ne 1) { throw "The key $key must appear once in the delivered configuration." }
        $text = [regex]::Replace($text, $pattern, "`${1}'$($values[$key])'")
    }
    $text = [regex]::Replace($text, "(?m)^(\s*Path\s*=\s*)'\.\\output'", "`${1}'$Directory\output'")
    $text = [regex]::Replace($text, "(?m)^(\s*Path\s*=\s*)'\.\\logs'", "`${1}'$Directory\logs'")
    $groups = "    Groups = @{`r`n        'FreeBusy-Fabrikam' = @{ DisplayName = 'SG-XTAP-FreeBusy-Fabrikam'; Create = `$true; MembershipRule = '(user.mail -endsWith ""@contoso.com"")' }"
    if ([regex]::Matches($text, '(?m)^\s*Groups = @\{').Count -ne 1) { throw 'The Groups section must appear once in the delivered configuration.' }
    $text = [regex]::Replace($text, '(?m)^\s*Groups = @\{', $groups)
    # Northwind confirmed its tenant ID; Fabrikam is confirmed by its existing partner policy, Adatum by its availability address space.
    $partners = "    Partners = @(`r`n        @{ Name = 'Northwind Traders'; Match = 'northwind.com'; TenantId = '$($TestTenant.Northwind)' }"
    if ([regex]::Matches($text, '(?m)^\s*Partners = @\(').Count -ne 1) { throw 'The Partners section must appear once in the delivered configuration.' }
    $text = [regex]::Replace($text, '(?m)^\s*Partners = @\(', $partners)
    $path = Join-Path $Directory 'test.config.psd1'
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($true))
    return $path
}

function New-TestOrgRel {
    param([string]$Name, [string[]]$Domains, [bool]$Enabled = $true, [bool]$FB = $false, [string]$FBLevel = 'None', [bool]$MT = $false, [string]$MTLevel = 'None', [string]$AppUri = '', [string]$Sharing = '', [string]$Owa = '', $FBGroup = $null, [string]$FBScope = '', [bool]$Move = $false)
    [ordered]@{
        Name = $Name; Enabled = $Enabled; DomainNames = $Domains
        FreeBusyAccessEnabled = $FB; FreeBusyAccessLevel = $FBLevel; FreeBusyAccessScope = $FBScope
        MailTipsAccessEnabled = $MT; MailTipsAccessLevel = $MTLevel; MailTipsAccessScope = ''
        TargetApplicationUri = $AppUri; TargetSharingEpr = $Sharing; TargetAutodiscoverEpr = ''; TargetOwaURL = $Owa
        MailboxMoveEnabled = $Move; ArchiveAccessEnabled = $false; DeliveryReportEnabled = $false; PhotosEnabled = $false; OAuthApplicationId = ''; WhenChanged = '2026-03-01T10:00:00Z'
        FreeBusyScopeGroup = $FBGroup; MailTipsScopeGroup = $null
    }
}

function New-TestSnapshot {
    <# Snapshot as -Mode Collect builds it, before classification. #>
    $ews = 'https://outlook.office365.com/EWS/Exchange.asmx'
    $domains = [ordered]@{}
    $add = { param($d, $status, $tid, $name) $domains[$d] = [ordered]@{ Domain = $d; Status = $status; TenantId = $tid; DisplayName = $name; DefaultDomain = ''; Cloud = 'microsoftonline.com'; Region = 'EU'; Source = 'Test'; Error = '' } }
    & $add 'contoso.com' 'Resolved' $TestTenant.Id 'Contoso'
    & $add 'fabrikam.com' 'Resolved' $TestTenant.Fabrikam 'Fabrikam'
    & $add 'tailspintoys.com' 'Resolved' $TestTenant.Tailspin 'Tailspin Toys'
    & $add 'litware.com' 'Resolved' $TestTenant.Litware 'Litware'
    & $add 'northwind.com' 'Resolved' $TestTenant.Northwind 'Northwind Traders'
    & $add 'northwindtraders.com' 'Resolved' $TestTenant.Northwind 'Northwind Traders'
    & $add 'unknown.example' 'NotFound' '' ''
    & $add 'adatum.com' 'Resolved' $TestTenant.Adatum 'Adatum'
    & $add 'outlook.com' 'Consumer' '9188040d-6c67-4c5b-b112-36a304b66dad' ''
    $scopeGroup = [ordered]@{ Identity = 'FB-Scope'; Resolved = $true; DisplayName = 'FB-Scope'; PrimarySmtpAddress = 'fb-scope@contoso.com'; ExternalDirectoryObjectId = $TestTenant.FbScopeGroup; RecipientTypeDetails = 'MailUniversalSecurityGroup'; SecurityEnabled = $true; Error = '' }
    [ordered]@{
        Tool        = [ordered]@{ Name = 'X-TAP Sharing Migration'; Version = '1.0.0' }
        CollectId   = '2026-10-01_101500'
        CollectedAt = [DateTime]::UtcNow.ToString('o')
        Tenant      = [ordered]@{ TenantId = $TestTenant.Id; Organization = 'contoso.onmicrosoft.com'; DisplayName = 'Contoso'; Cloud = 'microsoftonline.com'; Region = 'EU' }
        Accounts    = [ordered]@{ 'Exchange Online' = 'admin@contoso.onmicrosoft.com'; 'Microsoft Graph' = 'admin@contoso.onmicrosoft.com' }
        Exchange    = [ordered]@{
            Errors                      = @()
            AcceptedDomains             = @('contoso.com', 'contoso.onmicrosoft.com', 'contoso.mail.onmicrosoft.com')
            Organization                = [ordered]@{ Name = 'contoso.onmicrosoft.com'; DisplayName = 'Contoso'; Guid = '' }
            OrganizationRelationships   = @(
                (New-TestOrgRel 'O365 to On-premises - 3cca7e84-0000-4000-8000-000000000000' @('contoso.com') -FB $true -FBLevel 'AvailabilityOnly' -MT $true -MTLevel 'All' -Owa 'https://mail.contoso.com/owa')
                (New-TestOrgRel 'Fabrikam' @('fabrikam.com') -FB $true -FBLevel 'LimitedDetails' -FBScope 'FB-Scope' -FBGroup $scopeGroup -MT $true -MTLevel 'Limited' -AppUri 'outlook.com' -Sharing $ews)
                (New-TestOrgRel 'Tailspin' @('tailspintoys.com') -FB $true -FBLevel 'AvailabilityOnly' -Sharing 'https://mail.tailspintoys.com/ews/exchange.asmx')
                (New-TestOrgRel 'Old partner' @('litware.com') -Enabled $false -FB $true -FBLevel 'AvailabilityOnly' -AppUri 'outlook.com')
                (New-TestOrgRel 'Northwind' @('northwind.com', 'northwindtraders.com', 'unknown.example') -FB $true -FBLevel 'AvailabilityOnly' -AppUri 'outlook.com')
                (New-TestOrgRel 'MoveOnly' @('adatum.com') -Move $true -AppUri 'outlook.com')
            )
            AvailabilityAddressSpaces   = @(
                [ordered]@{ Name = 'adatum.com'; ForestName = 'adatum.com'; AccessMethod = 'OrgWideFBToken'; TargetAutodiscoverEpr = ''; TargetServiceEpr = $ews; TargetTenantId = $TestTenant.Adatum; ProxyUrl = ''; UseServiceAccount = $false }
                [ordered]@{ Name = 'contoso.com'; ForestName = 'contoso.com'; AccessMethod = 'InternalProxy'; TargetAutodiscoverEpr = ''; TargetServiceEpr = ''; TargetTenantId = ''; ProxyUrl = 'https://mail.contoso.com/ews/exchange.asmx'; UseServiceAccount = $true }
            )
            SharingPolicies             = @(
                [ordered]@{ Name = 'Default Sharing Policy'; Enabled = $true; Default = $true; Mailboxes = 3; Domains = @('Anonymous:CalendarSharingFreeBusyReviewer', '*:CalendarSharingFreeBusySimple', 'fabrikam.com:CalendarSharingFreeBusyDetail, ContactsSharing', 'outlook.com:CalendarSharingFreeBusySimple') }
                [ordered]@{ Name = 'VIP'; Enabled = $true; Default = $false; Mailboxes = 2; Domains = @('*:CalendarSharingFreeBusyReviewer') }
                [ordered]@{ Name = 'Unused'; Enabled = $true; Default = $false; Mailboxes = 0; Domains = @('litware.com:CalendarSharingFreeBusySimple') }
                [ordered]@{ Name = 'Disabled policy'; Enabled = $false; Default = $false; Mailboxes = 0; Domains = @('northwind.com:CalendarSharingFreeBusySimple') }
            )
            MailboxAssignmentsCollected = $true
            MailboxCount                = 5
            OnPremisesOrganizations     = @([ordered]@{ Name = 'Hybrid'; OrganizationRelationship = 'O365 to On-premises - 3cca7e84-0000-4000-8000-000000000000'; HybridDomains = @('contoso.com'); OrganizationName = 'Contoso'; OrganizationGuid = '' })
            IntraOrganizationConnectors = @()
        }
        Domains     = $domains
        Xtap        = [ordered]@{
            Readable = $true; Error = ''; ReadAt = [DateTime]::UtcNow.ToString('o')
            Default  = [ordered]@{
                Trust        = [ordered]@{ State = 'NotConfigured'; AccessType = ''; Targets = @() }
                Capabilities = @([ordered]@{ Name = 'anonymousCalendarSharingFreeBusyReviewer'; IsAllowed = $true; Included = @([ordered]@{ ResourceId = 'All'; ResourceType = 'user' }); Excluded = @(); LastModified = ''; Feature = 'AnonymousCalendarSharing'; Level = 'Reviewer' })
            }
            Partners = @(
                [ordered]@{
                    TenantId = $TestTenant.Fabrikam; Name = 'Fabrikam'; CapabilitiesRead = $true
                    Trust = [ordered]@{ State = 'AllowedAllUsers'; AccessType = 'allowed'; Targets = @([ordered]@{ Target = 'AllUsers'; TargetType = 'user' }) }
                    Capabilities = @(
                        [ordered]@{ Name = 'crossTenantCalendarAvailabilityBasic'; IsAllowed = $true; Included = @([ordered]@{ ResourceId = 'All'; ResourceType = 'user' }); Excluded = @(); LastModified = ''; Feature = 'FreeBusy'; Level = 'Basic' }
                        [ordered]@{ Name = 'crossTenantMailTipsLimited'; IsAllowed = $true; Included = @([ordered]@{ ResourceId = 'All'; ResourceType = 'user' }); Excluded = @(); LastModified = ''; Feature = 'MailTips'; Level = 'Limited' }
                    )
                }
            )
        }
        Items       = @()
        Sources     = @()
    }
}

function New-TestMailboxFile {
    <# SharingPolicyMailboxes.csv of the snapshot. #>
    param([Parameter(Mandatory)][string]$Directory)
    $rows = foreach ($policy in $TestTenant.Mailboxes.Keys) {
        $i = 0
        foreach ($id in $TestTenant.Mailboxes[$policy]) { $i++; [pscustomobject]@{ SharingPolicy = $policy; ExternalDirectoryObjectId = $id; PrimarySmtpAddress = "user$i.$($policy.Replace(' ', ''))@contoso.com"; RecipientTypeDetails = 'UserMailbox' } }
    }
    $rows | Export-Csv (Join-Path $Directory 'SharingPolicyMailboxes.csv') -Delimiter ';' -NoTypeInformation -Encoding utf8BOM
}
