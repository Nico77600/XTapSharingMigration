#
#  X-TAP Sharing Migration - configuration file
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : 1.0.1
#
#  Read by Invoke-XTapSharingMigration.ps1. It is a PowerShell data file: text between quotes,
#  $true / $false, numbers, @( ) for lists and @{ } for groups of settings. Lines starting with # are
#  comments. Relative paths (.\output, .\logs) are relative to the tool folder.
#
#  The guide (docs\XTapSharingMigration-Guide.md, chapter 6) explains every setting with examples.
#
@{
    # ---------------------------------------------------------------------
    # Tenant to configure. Safety check: after every sign-in, the tool stops if it is connected to
    # another tenant. Organization (xxx.onmicrosoft.com) is required in certificate mode.
    # ---------------------------------------------------------------------
    Tenant = @{
        TenantId     = ''
        Organization = ''
    }

    # ---------------------------------------------------------------------
    # Authentication.
    #   Interactive : an administrator signs in (browser window, MFA supported).
    #   DeviceCode  : code to enter on https://microsoft.com/devicelogin (terminal without a browser).
    #   Certificate : app-only (application with a certificate) - see the guide, Annex C.
    # The two phases can be run by different administrators: ExchangeAdmin is expected for -Mode Collect,
    # -Mode Plan and -Phase Exchange; EntraAdmin for -Phase Entra and -Phase All ('' = any account of the
    # tenant). -UserPrincipalName on the command line overrides both.
    # ---------------------------------------------------------------------
    Authentication = @{
        Mode                  = 'Interactive'
        ExchangeAdmin         = ''
        EntraAdmin            = ''
        DisableWAM            = $true   # browser instead of the Windows broker (WAM): keep $true with PowerShell 7
        GraphClientId         = ''      # '' = Microsoft Graph Command Line Tools; or your own app registration (delegated permissions)
        AppId                 = ''      # Certificate: application (client) ID
        CertificateThumbprint = ''      # Certificate: thumbprint in Cert:\CurrentUser\My or Cert:\LocalMachine\My
    }

    # ---------------------------------------------------------------------
    # Collection (-Mode Collect, read-only).
    # ---------------------------------------------------------------------
    Collection = @{
        MailboxAssignments            = $true    # number of mailboxes per sharing policy (needed to scope several sharing policies)
        BackupExchangeObjects         = $true    # Export-Clixml of the Exchange objects into the run folder (rollback of the manual cutover)
        HybridRelationshipNamePattern = '^O365 to On-premises'   # organization relationship created by the Hybrid Configuration Wizard: out of scope
        # Host names that identify a partner hosted in Exchange Online (TargetSharingEpr, TargetAutodiscoverEpr,
        # TargetApplicationUri). Another host means a partner on Exchange Server: out of scope, cannot be forced.
        Microsoft365Endpoints         = @('outlook.com', 'office365.com', 'office365.us', 'outlook.office365.us', 'outlook.cn', 'partner.outlook.cn')
    }

    # ---------------------------------------------------------------------
    # What to configure in Microsoft 365 X-TAP, per feature, for every partner.
    #   Migrate : $false = the feature is never migrated
    #   Level   : 'AsDiscovered' = the level found in Exchange Online, or a level forced for every partner:
    #               FreeBusy                 Basic | LimitedDetails          (time only | with subject and location)
    #               MailTips                 Limited | All
    #               CalendarSharing          Simple | Detail | Reviewer
    #               AnonymousCalendarSharing Simple | Detail | Reviewer      (published calendars, default policy)
    #   Scope   : 'AsDiscovered' = the scope found in Exchange Online, or a scope forced for every partner:
    #               'All'                          every user of this tenant
    #               '<object ID>'                  an existing Microsoft Entra security group
    #               'Group:<key>'                  a group of the Groups section below
    #               'Group:<display name>'         an existing security group, by name (must be unique)
    #               'SharingPolicy:<policy name>'  a group of the mailboxes of a sharing policy (created by -Phase Entra)
    #               several values separated by |  (for example 'Group:Sales | Group:Marketing')
    # A feature not yet rolled out in your tenant or the partner's (Message Center MC1446796): leave it
    # out for one run with -Feature (for example -Feature FreeBusy, MailTips), or here with Migrate = $false.
    # ---------------------------------------------------------------------
    Features = @{
        FreeBusy                 = @{ Migrate = $true; Level = 'AsDiscovered'; Scope = 'AsDiscovered' }
        MailTips                 = @{ Migrate = $true; Level = 'AsDiscovered'; Scope = 'AsDiscovered' }
        CalendarSharing          = @{ Migrate = $true; Level = 'AsDiscovered'; Scope = 'AsDiscovered' }
        AnonymousCalendarSharing = @{ Migrate = $true; Level = 'AsDiscovered'; Scope = 'AsDiscovered' }
    }

    # ---------------------------------------------------------------------
    # Partner tenants. The tool finds the tenant ID of each partner from its domains; before the Entra
    # phase trusts it, the partner confirms it (see Entra.RequireConfirmedPartners). -Mode Collect writes
    # PartnersToConfirm.txt with the entries to paste here.
    #   TenantId : tenant ID confirmed by the partner's administrator. The tool stops if a domain of
    #              Match belongs to another tenant.
    #   Match    : one domain of the partner (or its tenant ID) - links the rule to the items found
    #   Name     : display only
    #   Include  : $false excludes the partner
    #   Per feature (rules that win over Features): Migrate, Level, Scope (same values as above)
    # ---------------------------------------------------------------------
    Partners = @(
        # @{ Name = 'Fabrikam'; Match = 'fabrikam.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
        # @{ Name = 'Fabrikam'; Match = 'fabrikam.com'; TenantId = '00000000-0000-0000-0000-000000000000'; FreeBusy = @{ Level = 'Basic'; Scope = 'Group:FreeBusy-Fabrikam' }; MailTips = @{ Migrate = $false } }
        # @{ Match = 'tailspintoys.com'; Include = $false }
    )

    # ---------------------------------------------------------------------
    # Security groups used as scopes, referenced as 'Group:<key>'.
    #   Create = $true : created by -Phase Entra when no group has this DisplayName
    #   MembershipRule : dynamic membership rule (needs Microsoft Entra ID P1); '' = assigned group (you add the members)
    #   Id             : instead of DisplayName, the object ID of an existing group
    # ---------------------------------------------------------------------
    Groups = @{
        # 'FreeBusy-Fabrikam' = @{
        #     DisplayName    = 'SG-XTAP-FreeBusy-Fabrikam'
        #     Description    = 'Users whose free/busy Fabrikam can see (Microsoft 365 X-TAP)'
        #     Create         = $true
        #     MembershipRule = '(user.accountEnabled -eq true) and (user.userType -eq "Member") and (user.mail -endsWith "@contoso.com")'
        # }
    }

    # ---------------------------------------------------------------------
    # Several sharing policies in use: each one gets its own scope, a security group of its mailboxes
    # ('SharingPolicy:<name>'). Create = $true: -Phase Entra creates the group (assigned membership, the
    # mailboxes of the snapshot) and adds the missing members on the next runs; members are never removed.
    # ---------------------------------------------------------------------
    SharingPolicyGroups = @{
        Create     = $true
        NameFormat = 'SG-XTAP-SharingPolicy-{0}'
    }

    # ---------------------------------------------------------------------
    # Microsoft 365 collaboration trust (Entra phase), created for every partner with a capability.
    #   RequireConfirmedPartners : the trust is created only for a partner whose tenant ID is confirmed -
    #                              by a Partners rule with TenantId, by the TargetTenantId of an availability
    #                              address space, or by an existing partner policy. $false trusts the tenant
    #                              ID found from the domains (not recommended).
    #   ReplaceRestrictedTrust   : a trust that is blocked, or restricted to some users of the partner, is
    #                              never changed unless $true (it is then allowed for all users of the partner).
    # ---------------------------------------------------------------------
    Entra = @{
        RequireConfirmedPartners = $true
        ReplaceRestrictedTrust   = $false
    }

    # ---------------------------------------------------------------------
    # Changes (Exchange phase). Nothing is ever deleted.
    #   ExistingCapability : the capability already exists in X-TAP with another scope (or is not allowed)
    #                          'Keep'    - not changed, reported as a conflict (default: a scope set by hand
    #                                      is never widened or narrowed by the tool)
    #                          'Merge'   - the target scope is added to the existing one (nobody loses access)
    #                          'Replace' - the existing scope is replaced by the target scope
    #   DisableOtherLevels : another level of the same feature already allowed in the same policy (for
    #                        example Basic when LimitedDetails is planned) is set to not allowed
    # ---------------------------------------------------------------------
    Apply = @{
        ExistingCapability = 'Keep'
        DisableOtherLevels = $false
    }

    # ---------------------------------------------------------------------
    # Output files: one sub-folder per tenant and per run (output\<tenant>\<date>_<mode>).
    # ---------------------------------------------------------------------
    Output = @{
        Path         = '.\output'
        CsvDelimiter = ';'               # ';' opens directly in Excel with French regional settings
        TimeZone     = 'Europe/Paris'    # dates of the reports and names of the run folders
    }

    Logging = @{
        Path          = '.\logs'
        RetentionDays = 90
    }
}
