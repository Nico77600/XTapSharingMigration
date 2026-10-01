<#
    X-TAP Sharing Migration - collection (read-only).

    Reads what the tenant has today, without changing anything:
      - Exchange Online: organization relationships, availability address spaces, sharing policies and
        the number of mailboxes per sharing policy, accepted domains, hybrid objects;
      - Microsoft 365 cross-tenant access policy (Microsoft Graph v1.0): default policy and partner
        policies, Microsoft 365 collaboration trust and capabilities;
      - the Microsoft Entra tenant behind each external domain (OpenID configuration, anonymous; the
        organization name comes from Graph when the permission is granted).
    The result is the snapshot: snapshot.json + Inventory.html + Selection.csv in the run folder.
#>

$script:TenantResolver = $null   # tests: scriptblock param($Domain) returning the same hashtable as Resolve-XsmDomainTenant
$script:GraphTenantInfoDenied = $false

function Test-XsmTenantInfoAvailable {
    <# False when Microsoft Graph refused findTenantInformationByDomainName (permission not granted): no partner names. #>
    return -not $script:GraphTenantInfoDenied
}

function ConvertTo-XsmStringArray {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return , @() }
    return , @(@($Value) | ForEach-Object { if ($null -ne $_) { ([string]$_).Trim() } } | Where-Object { $_ })
}

function Get-XsmPropertyValue {
    <# Property of an Exchange object as text ('' when absent or null). #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return '' }
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { return '' }
    return ([string]$p.Value).Trim()
}

function Get-XsmPropertyBool {
    param($Object, [Parameter(Mandatory)][string]$Name)
    $v = Get-XsmPropertyValue $Object $Name
    return $v -eq 'True'
}

# ---------------------------------------------------------------------------------------------------
# Exchange Online
# ---------------------------------------------------------------------------------------------------
function Resolve-XsmExchangeGroup {
    <#
    .SYNOPSIS
        Microsoft Entra object ID and type of a group used as scope by an organization relationship
        (FreeBusyAccessScope, MailTipsAccessScope).
    #>
    param([Parameter(Mandatory)][string]$Identity, [hashtable]$Cache = @{})
    if ($Cache.ContainsKey($Identity)) { return $Cache[$Identity] }
    $result = [ordered]@{ Identity = $Identity; Resolved = $false; DisplayName = $Identity; PrimarySmtpAddress = ''; ExternalDirectoryObjectId = ''; RecipientTypeDetails = ''; SecurityEnabled = $false; Error = '' }
    $object = $null
    foreach ($command in 'Get-Recipient', 'Get-Group') {
        try { $object = @(Invoke-XsmExchange $command @{ Identity = $Identity }) | Select-Object -First 1; if ($object) { break } }
        catch { $result.Error = $_.Exception.Message }
    }
    if ($object) {
        $result.Resolved = $true
        $result.Error = ''
        $result.DisplayName = Get-XsmPropertyValue $object 'DisplayName'
        $result.PrimarySmtpAddress = Get-XsmPropertyValue $object 'PrimarySmtpAddress'
        $result.ExternalDirectoryObjectId = (Get-XsmPropertyValue $object 'ExternalDirectoryObjectId').ToLowerInvariant()
        $result.RecipientTypeDetails = Get-XsmPropertyValue $object 'RecipientTypeDetails'
        $result.SecurityEnabled = $result.RecipientTypeDetails -in 'MailUniversalSecurityGroup', 'UniversalSecurityGroup', 'MailNonUniversalGroup', 'GlobalSecurityGroup', 'UniversalSecurityGroup', 'DomainLocalSecurityGroup', 'SecurityGroup'
    }
    $Cache[$Identity] = $result
    return $result
}

function Get-XsmExchangeInventory {
    <#
    .SYNOPSIS
        Reads the Exchange Online sharing configuration. Returns the inventory (stored in the snapshot)
        and the list of mailboxes with their sharing policy (stored in SharingPolicyMailboxes.csv).
    .PARAMETER BackupDirectory
        Folder where the raw objects are exported (Export-Clixml), for the rollback of the manual cutover.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [string]$BackupDirectory)
    $inv = [ordered]@{
        Errors = [Collections.Generic.List[string]]::new(); AcceptedDomains = @(); Organization = [ordered]@{}
        OrganizationRelationships = @(); AvailabilityAddressSpaces = @(); SharingPolicies = @()
        MailboxAssignmentsCollected = $false; MailboxCount = $null; OnPremisesOrganizations = @(); IntraOrganizationConnectors = @()
    }
    $mailboxes = [Collections.Generic.List[object]]::new()
    $raw = @{}

    # Accepted domains and organization --------------------------------------------------------------
    $inv.AcceptedDomains = @(Invoke-XsmExchange 'Get-AcceptedDomain' | ForEach-Object { (Get-XsmPropertyValue $_ 'DomainName').ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    try {
        $org = Invoke-XsmExchange 'Get-OrganizationConfig'
        $inv.Organization = [ordered]@{ Name = Get-XsmPropertyValue $org 'Name'; DisplayName = Get-XsmPropertyValue $org 'DisplayName'; Guid = Get-XsmPropertyValue $org 'Guid' }
    } catch { $inv.Errors.Add("Get-OrganizationConfig: $($_.Exception.Message)") }
    Write-XsmItem Ok ("{0} accepted domain(s){1}" -f $inv.AcceptedDomains.Count, $(if ($inv.Organization.DisplayName) { "  $($script:Dot) $($inv.Organization.DisplayName)" })) -Icon Exchange

    # Organization relationships ---------------------------------------------------------------------
    $groupCache = @{}
    $raw.OrganizationRelationships = @(Invoke-XsmExchange 'Get-OrganizationRelationship')
    $inv.OrganizationRelationships = @(foreach ($o in $raw.OrganizationRelationships) {
            $entry = [ordered]@{
                Name                  = Get-XsmPropertyValue $o 'Name'
                Enabled               = Get-XsmPropertyBool $o 'Enabled'
                DomainNames           = ConvertTo-XsmStringArray ($o.DomainNames | ForEach-Object { ([string]$_).ToLowerInvariant() })
                FreeBusyAccessEnabled = Get-XsmPropertyBool $o 'FreeBusyAccessEnabled'
                FreeBusyAccessLevel   = Get-XsmPropertyValue $o 'FreeBusyAccessLevel'
                FreeBusyAccessScope   = Get-XsmPropertyValue $o 'FreeBusyAccessScope'
                MailTipsAccessEnabled = Get-XsmPropertyBool $o 'MailTipsAccessEnabled'
                MailTipsAccessLevel   = Get-XsmPropertyValue $o 'MailTipsAccessLevel'
                MailTipsAccessScope   = Get-XsmPropertyValue $o 'MailTipsAccessScope'
                TargetApplicationUri  = Get-XsmPropertyValue $o 'TargetApplicationUri'
                TargetSharingEpr      = Get-XsmPropertyValue $o 'TargetSharingEpr'
                TargetAutodiscoverEpr = Get-XsmPropertyValue $o 'TargetAutodiscoverEpr'
                TargetOwaURL          = Get-XsmPropertyValue $o 'TargetOwaURL'
                MailboxMoveEnabled    = Get-XsmPropertyBool $o 'MailboxMoveEnabled'
                ArchiveAccessEnabled  = Get-XsmPropertyBool $o 'ArchiveAccessEnabled'
                DeliveryReportEnabled = Get-XsmPropertyBool $o 'DeliveryReportEnabled'
                PhotosEnabled         = Get-XsmPropertyBool $o 'PhotosEnabled'
                OAuthApplicationId    = Get-XsmPropertyValue $o 'OAuthApplicationId'
                WhenChanged           = Get-XsmPropertyValue $o 'WhenChangedUTC'
                FreeBusyScopeGroup    = $null
                MailTipsScopeGroup    = $null
            }
            if ($entry.FreeBusyAccessScope) { $entry.FreeBusyScopeGroup = Resolve-XsmExchangeGroup $entry.FreeBusyAccessScope $groupCache }
            if ($entry.MailTipsAccessScope) { $entry.MailTipsScopeGroup = Resolve-XsmExchangeGroup $entry.MailTipsAccessScope $groupCache }
            $entry
        })
    Write-XsmItem Ok ("{0} organization relationship(s), {1} enabled" -f $inv.OrganizationRelationships.Count, @($inv.OrganizationRelationships | Where-Object Enabled).Count) -Icon Exchange

    # Availability address spaces --------------------------------------------------------------------
    try {
        $raw.AvailabilityAddressSpaces = @(Invoke-XsmExchange 'Get-AvailabilityAddressSpace')
        $inv.AvailabilityAddressSpaces = @(foreach ($a in $raw.AvailabilityAddressSpaces) {
                [ordered]@{
                    Name                  = Get-XsmPropertyValue $a 'Name'
                    ForestName            = (Get-XsmPropertyValue $a 'ForestName').ToLowerInvariant()
                    AccessMethod          = Get-XsmPropertyValue $a 'AccessMethod'
                    TargetAutodiscoverEpr = Get-XsmPropertyValue $a 'TargetAutodiscoverEpr'
                    TargetServiceEpr      = Get-XsmPropertyValue $a 'TargetServiceEpr'
                    TargetTenantId        = (Get-XsmPropertyValue $a 'TargetTenantId').ToLowerInvariant()
                    ProxyUrl              = Get-XsmPropertyValue $a 'ProxyUrl'
                    UseServiceAccount     = Get-XsmPropertyBool $a 'UseServiceAccount'
                }
            })
        Write-XsmItem Ok ("{0} availability address space(s)" -f $inv.AvailabilityAddressSpaces.Count) -Icon Exchange
    } catch {
        $inv.Errors.Add("Get-AvailabilityAddressSpace: $($_.Exception.Message)")
        Write-XsmItem Warn "Availability address spaces not read: $($_.Exception.Message)"
    }

    # Sharing policies -------------------------------------------------------------------------------
    $raw.SharingPolicies = @(Invoke-XsmExchange 'Get-SharingPolicy')
    $policies = @(foreach ($s in $raw.SharingPolicies) {
            [ordered]@{
                Name      = Get-XsmPropertyValue $s 'Name'
                Enabled   = Get-XsmPropertyBool $s 'Enabled'
                Default   = Get-XsmPropertyBool $s 'Default'
                Domains   = ConvertTo-XsmStringArray ($s.Domains | ForEach-Object { [string]$_ })
                Mailboxes = $null
            }
        })
    $defaultPolicy = @($policies | Where-Object Default) | Select-Object -First 1

    if ($Settings.Collection.MailboxAssignments) {
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $all = @(Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox, SharedMailbox, RoomMailbox, EquipmentMailbox -PropertySets Minimum -Properties SharingPolicy -ErrorAction Stop)
            foreach ($m in $all) {
                $policyName = Get-XsmPropertyValue $m 'SharingPolicy'
                if (-not $policyName -and $defaultPolicy) { $policyName = $defaultPolicy.Name }
                $mailboxes.Add([pscustomobject]@{
                        SharingPolicy             = $policyName
                        ExternalDirectoryObjectId = (Get-XsmPropertyValue $m 'ExternalDirectoryObjectId').ToLowerInvariant()
                        PrimarySmtpAddress        = Get-XsmPropertyValue $m 'PrimarySmtpAddress'
                        RecipientTypeDetails      = Get-XsmPropertyValue $m 'RecipientTypeDetails'
                    })
            }
            foreach ($p in $policies) { $p.Mailboxes = @($mailboxes | Where-Object { $_.SharingPolicy -ieq $p.Name }).Count }
            $inv.MailboxCount = $mailboxes.Count
            $inv.MailboxAssignmentsCollected = $true
            Write-XsmItem Ok ("{0} mailbox(es) read in {1} (user, shared, room, equipment)" -f $mailboxes.Count.ToString('N0'), (Format-XsmDuration $clock.Elapsed.TotalSeconds)) -Icon People
        } catch {
            $inv.Errors.Add("Get-EXOMailbox: $($_.Exception.Message)")
            Write-XsmItem Warn "Mailboxes not read (number of mailboxes per sharing policy unknown): $($_.Exception.Message)"
        }
    } else {
        Write-XsmItem Skip 'Mailboxes per sharing policy: not collected (Collection.MailboxAssignments = $false).'
    }
    $inv.SharingPolicies = $policies
    Write-XsmItem Ok ("{0} sharing polic{1}, {2} enabled" -f $policies.Count, $(if ($policies.Count -eq 1) { 'y' } else { 'ies' }), @($policies | Where-Object Enabled).Count) -Icon Exchange

    # Hybrid objects (out of scope, shown in the inventory) -------------------------------------------
    try {
        $inv.OnPremisesOrganizations = @(Invoke-XsmExchange 'Get-OnPremisesOrganization' | ForEach-Object {
                [ordered]@{
                    Name                     = Get-XsmPropertyValue $_ 'Name'
                    OrganizationRelationship = Get-XsmPropertyValue $_ 'OrganizationRelationship'
                    HybridDomains            = ConvertTo-XsmStringArray ($_.HybridDomains | ForEach-Object { ([string]$_).ToLowerInvariant() })
                    OrganizationName         = Get-XsmPropertyValue $_ 'OrganizationName'
                    OrganizationGuid         = Get-XsmPropertyValue $_ 'OrganizationGuid'
                }
            })
    } catch { $inv.Errors.Add("Get-OnPremisesOrganization: $($_.Exception.Message)") }
    try {
        $inv.IntraOrganizationConnectors = @(Invoke-XsmExchange 'Get-IntraOrganizationConnector' | ForEach-Object {
                [ordered]@{
                    Name                 = Get-XsmPropertyValue $_ 'Name'
                    Enabled              = Get-XsmPropertyBool $_ 'Enabled'
                    TargetAddressDomains = ConvertTo-XsmStringArray ($_.TargetAddressDomains | ForEach-Object { ([string]$_).ToLowerInvariant() })
                    DiscoveryEndpoint    = Get-XsmPropertyValue $_ 'DiscoveryEndpoint'
                    TargetSharingEpr     = Get-XsmPropertyValue $_ 'TargetSharingEpr'
                }
            })
    } catch { $inv.Errors.Add("Get-IntraOrganizationConnector: $($_.Exception.Message)") }
    if ($inv.OnPremisesOrganizations.Count -or $inv.IntraOrganizationConnectors.Count) {
        Write-XsmItem Info ("Exchange hybrid detected: {0} on-premises organization(s), {1} intra-organization connector(s) - out of scope (Exchange hybrid application)" -f $inv.OnPremisesOrganizations.Count, $inv.IntraOrganizationConnectors.Count)
    }

    # Backup of the raw objects (rollback of the manual cutover) -------------------------------------
    if ($BackupDirectory -and $Settings.Collection.BackupExchangeObjects) {
        [void][IO.Directory]::CreateDirectory($BackupDirectory)
        foreach ($name in 'OrganizationRelationships', 'AvailabilityAddressSpaces', 'SharingPolicies') {
            if ($raw.ContainsKey($name)) { $raw[$name] | Export-Clixml -LiteralPath (Join-Path $BackupDirectory "$name.xml") -Depth 5 }
        }
    }
    $inv.Errors = @($inv.Errors)
    return [pscustomobject]@{ Inventory = $inv; Mailboxes = $mailboxes.ToArray() }
}

# ---------------------------------------------------------------------------------------------------
# Microsoft 365 cross-tenant access policy (read)
# ---------------------------------------------------------------------------------------------------
function ConvertTo-XsmCapability {
    <# Normalized view of a Graph m365Capability object. #>
    param([Parameter(Mandatory)]$Raw)
    $access = $Raw['inboundAccess']
    $scopes = if ($access) { $access['resourceScopes'] } else { $null }
    $convert = { param($list) , @(@($list) | Where-Object { $_ -and $_['resourceId'] } | ForEach-Object { [ordered]@{ ResourceId = ([string]$_['resourceId']); ResourceType = ([string]$_['resourceType']) } }) }
    $name = [string]$Raw['name']
    if (-not $name -and $Raw['@odata.type']) { $name = ([string]$Raw['@odata.type']) -replace '^#?microsoft\.graph\.', '' }
    $info = Get-XsmCapabilityInfo $name
    [ordered]@{
        Name         = $name
        IsAllowed    = [bool]($access -and $access['isAllowed'])
        Included     = & $convert $(if ($scopes) { $scopes['included'] })
        Excluded     = & $convert $(if ($scopes) { $scopes['excluded'] })
        LastModified = [string]$Raw['lastModifiedDateTime']
        Feature      = if ($info) { $info.Feature } else { '' }
        Level        = if ($info) { $info.Level } else { '' }
    }
}

function ConvertTo-XsmTrust {
    <# Normalized view of m365CollaborationInbound: State = NotConfigured | AllowedAllUsers | AllowedSome | Blocked. #>
    param([AllowNull()]$Raw)
    if (-not $Raw -or -not $Raw['users']) { return [ordered]@{ State = 'NotConfigured'; AccessType = ''; Targets = @() } }
    $users = $Raw['users']
    $targets = @(@($users['targets']) | Where-Object { $_ } | ForEach-Object { [ordered]@{ Target = [string]$_['target']; TargetType = [string]$_['targetType'] } })
    $type = [string]$users['accessType']
    $state = if ($type -ieq 'allowed') { if (@($targets | Where-Object { $_.Target -ieq 'AllUsers' }).Count) { 'AllowedAllUsers' } else { 'AllowedSome' } } elseif ($type -ieq 'blocked') { 'Blocked' } else { 'NotConfigured' }
    [ordered]@{ State = $state; AccessType = $type; Targets = $targets }
}

function Get-XsmXtapPartner {
    <# One partner policy with its trust and capabilities; $null when the partner policy does not exist. #>
    param([Parameter(Mandatory)][string]$TenantId)
    $p = Get-XsmGraphOrNull "/policies/crossTenantAccessPolicy/partners/$TenantId"
    if (-not $p) { return $null }
    $caps = @(Get-XsmGraphCollection "/policies/crossTenantAccessPolicy/partners/$TenantId/m365Capabilities" | ForEach-Object { ConvertTo-XsmCapability $_ })
    [ordered]@{ TenantId = $TenantId.ToLowerInvariant(); Trust = ConvertTo-XsmTrust $p['m365CollaborationInbound']; Capabilities = $caps; CapabilitiesRead = $true }
}

function Resolve-XsmGroupNames {
    <# Display names of the groups used as scopes by capabilities (object ID -> name); groups not found are left out. #>
    param([AllowEmptyCollection()][object[]]$Capabilities = @())
    $names = [ordered]@{}
    $ids = @($Capabilities | ForEach-Object { @($_.Included) + @($_.Excluded) } | Where-Object { $_ -and $_.ResourceType -eq 'group' -and $_.ResourceId -match $script:GuidPattern } | ForEach-Object { ([string]$_.ResourceId).ToLowerInvariant() } | Select-Object -Unique)
    foreach ($id in $ids) {
        try { $g = Get-XsmGraphOrNull "/groups/$($id)?`$select=id,displayName"; if ($g) { $names[$id] = [string]$g['displayName'] } }
        catch { Write-XsmLog 'WARN' "Group $id not read: $($_.Exception.Message)" }
    }
    return $names
}

function Get-XsmXtapState {
    <#
    .SYNOPSIS
        Reads the default policy and the partner policies. Capabilities are read for every partner with
        -AllPartners, otherwise for the partners in RelevantTenantIds and those with a Microsoft 365
        collaboration trust.
    #>
    param([string[]]$RelevantTenantIds = @(), [switch]$AllPartners)
    $state = [ordered]@{ Readable = $true; Error = ''; ReadAt = [DateTime]::UtcNow.ToString('o'); Default = $null; Partners = @() }
    try {
        $default = Invoke-XsmGraph GET '/policies/crossTenantAccessPolicy/default'
        $caps = @(Get-XsmGraphCollection '/policies/crossTenantAccessPolicy/default/m365Capabilities' | ForEach-Object { ConvertTo-XsmCapability $_ })
        $state.Default = [ordered]@{ Trust = ConvertTo-XsmTrust $default['m365CollaborationInbound']; Capabilities = $caps }
        $relevant = @($RelevantTenantIds | ForEach-Object { $_.ToLowerInvariant() })
        $partners = @(Get-XsmGraphCollection '/policies/crossTenantAccessPolicy/partners')
        $state.Partners = @(foreach ($p in $partners) {
                $tid = ([string]$p['tenantId']).ToLowerInvariant()
                $trust = ConvertTo-XsmTrust $p['m365CollaborationInbound']
                $entry = [ordered]@{ TenantId = $tid; Trust = $trust; Capabilities = @(); CapabilitiesRead = $false }
                if ($AllPartners -or $trust.State -ne 'NotConfigured' -or $tid -in $relevant) {
                    $entry.Capabilities = @(Get-XsmGraphCollection "/policies/crossTenantAccessPolicy/partners/$tid/m365Capabilities" | ForEach-Object { ConvertTo-XsmCapability $_ })
                    $entry.CapabilitiesRead = $true
                }
                $entry
            })
        $state.GroupNames = Resolve-XsmGroupNames (@($state.Default.Capabilities) + @($state.Partners | ForEach-Object { $_.Capabilities }))
    } catch {
        $state.Readable = $false
        $state.Error = $_.Exception.Message
    }
    return $state
}

# ---------------------------------------------------------------------------------------------------
# Partner tenants
# ---------------------------------------------------------------------------------------------------
function Resolve-XsmDomainTenant {
    <#
    .SYNOPSIS
        Microsoft Entra tenant of a domain.
    .DESCRIPTION
        1. OpenID configuration of login.microsoftonline.com (anonymous): tenant ID, cloud, region.
        2. Microsoft Graph tenantRelationships/findTenantInformationByDomainName (v1.0) when -UseGraph:
           organization name and default domain (permission CrossTenantInformation.ReadBasic.All).
        Status: Resolved | NotFound | Consumer | Error.
    #>
    param([Parameter(Mandatory)][string]$Domain, [switch]$UseGraph)
    $domainName = $Domain.Trim().ToLowerInvariant()
    if ($script:TenantResolver) { return & $script:TenantResolver $domainName }
    $result = [ordered]@{ Domain = $domainName; Status = 'Error'; TenantId = ''; DisplayName = ''; DefaultDomain = ''; Cloud = ''; Region = ''; Source = 'OpenID'; Error = '' }
    try {
        $oidc = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$domainName/v2.0/.well-known/openid-configuration" -TimeoutSec 30 -ErrorAction Stop
        if ([string]$oidc.issuer -match '/([0-9a-fA-F-]{36})/') {
            $result.TenantId = $Matches[1].ToLowerInvariant()
            $result.Status = if ($result.TenantId -eq $script:ConsumerTenantId) { 'Consumer' } else { 'Resolved' }
        }
        $result.Cloud = [string]$oidc.cloud_instance_name
        $result.Region = [string]$oidc.tenant_region_scope
    } catch {
        $text = (@([string]$_.ErrorDetails.Message, [string]$_.Exception.Message) | Where-Object { $_ }) -join ' '
        if ($text -match 'AADSTS90002|AADSTS50059|AADSTS90013|tenant .* not found|does not exist') { $result.Status = 'NotFound' }
        else { $result.Error = ($text -split "`n")[0] }
    }
    if ($UseGraph -and $result.Status -eq 'Resolved' -and -not $script:GraphTenantInfoDenied) {
        try {
            $escaped = $domainName.Replace("'", "''")
            $info = Invoke-XsmGraph GET "/tenantRelationships/findTenantInformationByDomainName(domainName='$escaped')"
            $result.DisplayName = [string]$info['displayName']
            $result.DefaultDomain = [string]$info['defaultDomainName']
            $result.Source = 'OpenID + Graph'
        } catch {
            # Permission not granted, or Microsoft Graph not usable any more in this session: stop asking.
            $script:GraphTenantInfoDenied = $true
            Write-XsmLog 'WARN' "findTenantInformationByDomainName($domainName): $($_.Exception.Message)"
        }
    }
    return $result
}

function Get-XsmExternalDomains {
    <# Every external domain named in the inventory (organization relationships, address spaces, sharing policies). #>
    param([Parameter(Mandatory)]$Inventory)
    $domains = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($o in @($Inventory.OrganizationRelationships)) { foreach ($d in @($o.DomainNames)) { [void]$domains.Add(([string]$d).ToLowerInvariant()) } }
    foreach ($a in @($Inventory.AvailabilityAddressSpaces)) { if ($a.ForestName) { [void]$domains.Add(([string]$a.ForestName).ToLowerInvariant()) } }
    foreach ($p in @($Inventory.SharingPolicies)) {
        foreach ($entry in @($p.Domains)) {
            $parsed = ConvertFrom-XsmSharingEntry $entry
            if ($parsed.Kind -eq 'Domain') { [void]$domains.Add($parsed.Domain) }
        }
    }
    return @($domains | Sort-Object)
}

function Resolve-XsmDomainTenants {
    <# Resolves a list of domains; returns an ordered hashtable domain -> result. #>
    param([string[]]$Domains = @(), [switch]$UseGraph)
    $result = [ordered]@{}
    foreach ($d in $Domains) { $result[$d] = Resolve-XsmDomainTenant -Domain $d -UseGraph:$UseGraph }
    return $result
}

# ---------------------------------------------------------------------------------------------------
# Snapshot files
# ---------------------------------------------------------------------------------------------------
function Get-XsmTenantFolderName {
    param([Parameter(Mandatory)]$Settings)
    $name = if ($Settings.Tenant.Organization) { $Settings.Tenant.Organization } else { $Settings.Tenant.TenantId }
    return ($name -replace '[^A-Za-z0-9._-]', '_')
}

function New-XsmRunDirectory {
    <# Creates output\<tenant>\<yyyy-MM-dd_HHmmss>_<Name> and returns its path. #>
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$Name)
    $stamp = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Now, $Settings.Output.Zone).ToString('yyyy-MM-dd_HHmmss')
    $path = Join-Path (Join-Path $Settings.Output.Path (Get-XsmTenantFolderName $Settings)) "$($stamp)_$Name"
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Save-XsmJson {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Path)
    [IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

function Find-XsmLatestSnapshot {
    <# Folder of the most recent Collect run of the tenant, or $null. #>
    param([Parameter(Mandatory)]$Settings)
    $folder = Join-Path $Settings.Output.Path (Get-XsmTenantFolderName $Settings)
    if (-not (Test-Path -LiteralPath $folder)) { return $null }
    $latest = Get-ChildItem -LiteralPath $folder -Directory -Filter '*_Collect' | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'snapshot.json') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { return $latest.FullName }
    return $null
}

function Import-XsmSnapshot {
    <# Reads a snapshot (folder of a Collect run or its snapshot.json) and checks it belongs to the configured tenant. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Settings)
    $file = if (Test-Path -LiteralPath $Path -PathType Container) { Join-Path $Path 'snapshot.json' } else { $Path }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Snapshot not found: $file. Run -Mode Collect first, or give -SnapshotPath." }
    try { $snapshot = [IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable -Depth 100 }
    catch { throw "The snapshot is not valid JSON ($file): $($_.Exception.Message)" }
    if (-not $snapshot['Tool'] -or -not $snapshot['Tenant'] -or -not $snapshot.ContainsKey('Items')) { throw "This file is not an X-TAP Sharing Migration snapshot: $file" }
    if ($null -eq $snapshot.Items) { $snapshot.Items = @() }
    if ([string]$snapshot.Tenant.TenantId -ne $Settings.Tenant.TenantId) { throw "The snapshot belongs to tenant $($snapshot.Tenant.TenantId), but the configuration is for $($Settings.Tenant.TenantId): $file" }
    $snapshot['Directory'] = Split-Path $file -Parent
    return $snapshot
}

function Import-XsmSharingPolicyMailboxes {
    <# Mailboxes of the snapshot (SharingPolicyMailboxes.csv), grouped by sharing policy name. #>
    param([Parameter(Mandatory)]$Snapshot)
    $file = Join-Path $Snapshot.Directory 'SharingPolicyMailboxes.csv'
    $byPolicy = @{}
    if (-not (Test-Path -LiteralPath $file)) { return $byPolicy }
    foreach ($row in (Import-Csv -LiteralPath $file -Delimiter ';' -Encoding UTF8)) {
        $key = ([string]$row.SharingPolicy).ToLowerInvariant()
        if (-not $byPolicy.ContainsKey($key)) { $byPolicy[$key] = [Collections.Generic.List[string]]::new() }
        if ($row.ExternalDirectoryObjectId) { $byPolicy[$key].Add(([string]$row.ExternalDirectoryObjectId).ToLowerInvariant()) }
    }
    return $byPolicy
}
