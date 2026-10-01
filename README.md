# X-TAP Sharing Migration

Moves cross-tenant **Free/Busy, MailTips and calendar sharing** from Exchange Online **organization relationships, sharing policies and availability address spaces** to the **Microsoft 365 cross-tenant access policy (X-TAP)** — for one tenant, in **two phases** (Entra, then Exchange) that different administrators can run.

![Inventory report](docs/images/report-inventory.png)

## Why

Organization relationships and sharing policies rely on **Exchange Web Services**, which is being retired in Exchange Online. Microsoft documents the move to X-TAP ([Migrate to Microsoft 365 Cross-Tenant Access Policy](https://learn.microsoft.com/exchange/sharing/migrate-to-m365-xtap)); the hard part in a real tenant is the inventory — which relationships are hybrid, which partner hides behind which domain, which sharing policy applies to which mailboxes — and keeping a trace of every decision. This tool does that part.

## How it works

```
Collect (read-only)  ──►  Plan (read-only)  ──►  Apply -Phase Entra  ──►  Apply -Phase Exchange  ──►  manual cutover
Inventory.html            Plan.html              groups + trusts          capabilities               with each partner
Selection.csv             target vs tenant       (Security/Groups admin)  (Exchange admin)           commands + rollback
```

- **Collect** reads Exchange Online and the current X-TAP, finds the tenant of each external domain, and classifies every item: **in scope** (external Microsoft 365 tenant) or **out of scope** with the reason — Exchange **hybrid** (handled by the Exchange hybrid application), on-premises partner, disabled, unused, no tenant… The **initial picture** is kept as an HTML report and a JSON snapshot.
- **Choose**: accept the proposal, force a level, a scope or a security group in the configuration (per feature or per partner), or complete **Selection.csv** item by item.
- **One feature at a time**: `-Feature FreeBusy, MailTips` limits Plan and Apply to some features — for example while calendar sharing is not yet rolled out in X-TAP for your tenant or the partner's.
- **One configuration per partner tenant**, whatever the number of relationships and domains. When they give different levels for the same users, **the administrator chooses** (asked once, recorded).
- **Partner tenant IDs** found from the domains must be **confirmed by the partner** before any trust is created (`PartnersToConfirm.txt`). Availability address spaces (your users read the partner) are listed as **to be configured by the partner**.
- **Plan / Apply** compare the target with the tenant, show every action, ask for confirmation, apply one phase and **verify** by reading the tenant again. An existing capability scoped by hand is **kept** unless you choose `Merge` or `Replace`.
- **Out of scope, never configured, cannot be forced**: Exchange **hybrid** with your own on-premises servers (dedicated Exchange hybrid application) and partners on **Exchange Server** (relationship to an on-premises endpoint). They appear in the inventory with the reason, for information.
- **Never** changes an Exchange Online object, **never** deletes anything. Microsoft Graph **v1.0** only.

![Plan in the console](docs/images/console-plan.png)

## Requirements

| Item | Requirement |
|---|---|
| PowerShell | 7.4 or later |
| Modules | `Microsoft.Graph.Authentication` 2.25+, `ExchangeOnlineManagement` 3.9+ |
| Collect | Exchange role that can read the configuration; Graph `Policy.Read.All`, `CrossTenantInformation.ReadBasic.All`, `Group.Read.All` |
| Phase Entra | Security Administrator (+ Groups Administrator) or Global Administrator |
| Phase Exchange | Exchange Administrator or Global Administrator |

## Quick start

```powershell
git clone https://github.com/Nico77600/XTapSharingMigration.git
cd XTapSharingMigration
notepad .\config\XTapSharingMigration.config.psd1          # Tenant.TenantId, Tenant.Organization

.\Invoke-XTapSharingMigration.ps1                           # inventory (read-only)
.\Invoke-XTapSharingMigration.ps1 -Mode Plan                # what would be configured (read-only)
.\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase Entra     # groups and trusts
.\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase Exchange  # Free/Busy, MailTips, calendar sharing
.\Invoke-XTapSharingMigration.ps1 -Mode Plan -Feature FreeBusy, MailTips   # only some features
```

The zip of each [release](https://github.com/Nico77600/XTapSharingMigration/releases) contains only the files needed to run.

## Documentation

The **administrator guide** covers the principles, what is in scope, the partner tenant ID confirmation, the configuration rules, `Selection.csv`, the reports, **what to do after the script** (rollout check, partner contact, change window, cutover, test matrix, checking `GetSchedule` in the browser developer tools, rollback, cleanup), troubleshooting and the internals:

- [docs/XTapSharingMigration-Guide.md](docs/XTapSharingMigration-Guide.md)
- `docs/XTapSharingMigration-Guide.html` — the same guide as a single HTML file (download it and open it locally)

## Tests

```powershell
Invoke-Pester -Path .\tests          # Pester 5+, simulated tenant, no connection to Microsoft 365
.\tests\New-DemoReports.ps1          # the three HTML reports from the simulated tenant
```

## License

[MIT](LICENSE)

## Disclaimer

Personal project, provided as is. It is not an official Microsoft product and is not supported by Microsoft. Test it in your environment before production use, and coordinate every cutover with the partner organizations.
