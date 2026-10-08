# X-TAP Sharing Migration

Inventories Exchange Online organization relationships, sharing policies and availability address spaces, then configures the equivalent Microsoft 365 cross-tenant access policy in two phases.

This folder contains everything needed to run the tool: Invoke-XTapSharingMigration.ps1, the module, the configuration, the report template and the guide. Tests and build tools stay outside it, in the repository.

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows. Unblock them once, from this folder:
>
> ```powershell
> Get-ChildItem . -Recurse -File | Unblock-File
> ```

## Requirements
- PowerShell 7.4 or later.
- Microsoft.Graph.Authentication 2.25+ for every run.
- ExchangeOnlineManagement 3.9+ for Collect only.
- Read permissions for Collect and Plan.
- Security or Global Administrator for Entra changes; Exchange or Global Administrator for Exchange changes.

## Quick start
```powershell
notepad .\config\XTapSharingMigration.config.psd1          # Tenant.TenantId, Tenant.Organization

.\Invoke-XTapSharingMigration.ps1                           # inventory (read-only)
.\Invoke-XTapSharingMigration.ps1 -Mode Plan                # what would be configured (read-only)
.\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase Entra     # groups and trusts
.\Invoke-XTapSharingMigration.ps1 -Mode Apply -Phase Exchange  # Free/Busy, MailTips, calendar sharing
.\Invoke-XTapSharingMigration.ps1 -Mode Plan -Feature FreeBusy, MailTips   # only some features
```

## Content
| Item | Role |
|---|---|
| `config\` | Example configuration file. |
| `docs\` | Administrator guide in Markdown and HTML, with images. |
| `src\` | Module code, one file per stage. |
| `templates\` | HTML report template. |
| `Invoke-XTapSharingMigration.ps1` | Entry script to run. |
| `XTapSharingMigration.psd1` | PowerShell module manifest. |
| `XTapSharingMigration.psm1` | PowerShell module loader. |
| `LICENSE` | MIT license. |
| `README.md` | This package quick start. |

## Documentation
- [Guide](docs/XTapSharingMigration-Guide.md) - also `docs/XTapSharingMigration-Guide.html`, a single file to open locally

Project page, releases and change log: https://github.com/Nico77600/XTapSharingMigration

License: [MIT](LICENSE).
