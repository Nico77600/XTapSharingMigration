# X-TAP Sharing Migration

**Author:** Nicolas Fabert

Read your existing Exchange Online sharing settings, review a plan, then configure Microsoft 365 X-TAP in two phases. Start with the inventory: it changes nothing in the tenant.

**New here?** Double-click [the user guide](docs/XTapSharingMigration-UserGuide.html). It explains every step, including where to type commands and which account to use.

[Latest release](https://github.com/Nico77600/XTapSharingMigration/releases/latest) &middot; [What's new](https://github.com/Nico77600/XTapSharingMigration/blob/main/CHANGELOG.md) &middot; [Project](https://github.com/Nico77600/XTapSharingMigration)

## Requirements

| Item | What you need |
|---|---|
| Console | **PowerShell 7.4+**, not Windows PowerShell 5.1 |
| Modules | `Microsoft.Graph.Authentication` 2.25+; `ExchangeOnlineManagement` for Collect (install 3.10.1+) |
| Read-only inventory | An Exchange administrator with read access to sharing settings and the Graph read permissions explained in the guide |
| Apply, Entra phase | Security Administrator plus Groups Administrator for new groups, or Global Administrator |
| Apply, Exchange phase | Exchange Administrator or Global Administrator |
| Coordination | The partner's confirmed tenant ID and an agreed test plan |

## Quick start

### 1. Open the right folder

Extract the release ZIP. Open **PowerShell 7** and go to the folder that directly contains `Invoke-XTapSharingMigration.ps1`. Replace the example path with your extraction path:

```powershell
Set-Location 'C:\Tools\XTapSharingMigration'
Get-ChildItem . -Recurse -File -Force | Unblock-File
$PSVersionTable.PSVersion
```

**Expected:** version 7.4 or later. If the script is not in this folder, find the correct extracted folder before continuing. In a source checkout only, the runtime files are under `package`.

### 2. Install the modules and fill in your tenant

```powershell
Install-Module Microsoft.Graph.Authentication -MinimumVersion 2.25.0 -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement -MinimumVersion 3.10.1 -Scope CurrentUser -Force
notepad .\config\XTapSharingMigration.config.psd1
```

In the existing `Tenant` section, enter your **tenant ID** and **`xxx.onmicrosoft.com` domain**, then save. Do not paste configuration sections into the console. The user guide shows where to find the values.

### 3. Run only the inventory

```powershell
.\Invoke-XTapSharingMigration.ps1
```

**Expected:** sign-in prompts, then a Collect folder with `Inventory.html`. Open it. **No tenant configuration has changed.**

**If it fails:** read the last error; use the troubleshooting chapter of the user guide. Do not disable existing sharing or change `Keep` to `Replace` to make an error disappear.

### 4. Review before changing anything

Continue in [the user guide](docs/XTapSharingMigration-UserGuide.html): confirm the partner, review Plan, then Apply Entra and Apply Exchange separately. Each Apply changes the tenant only after confirmation. The tool never executes the manual Exchange cutover.

Calendar Sharing uses a group of each policy's collected mailboxes by default. Choosing `All` is a deliberate tenant-wide change. A configuration readback does not prove a real share works; test with the partner before retiring legacy rules.

## Content

- **Run:** `Invoke-XTapSharingMigration.ps1`.
- **Keep together:** the module files `XTapSharingMigration.psd1`, `XTapSharingMigration.psm1`, and the `src` and `templates` folders.
- **Edit your choices:** `config\XTapSharingMigration.config.psd1`.
- **Read offline:** the user and technical HTML guides in `docs`.
- **Project information:** this `README.md` and the MIT `LICENSE`.

The release also includes `CHANGELOG.md`. The source repository additionally contains Markdown guides, images, tests and build tools; those are not all shipped in the runtime ZIP. Runtime paths remain unchanged.

## Documentation

- [User guide — open locally](docs/XTapSharingMigration-UserGuide.html)
- [Technical guide — open locally](docs/XTapSharingMigration-Guide.html)
- [User guide — read on GitHub](https://github.com/Nico77600/XTapSharingMigration/blob/main/package/docs/XTapSharingMigration-UserGuide.md)
- [Latest release — choose the project ZIP under Assets](https://github.com/Nico77600/XTapSharingMigration/releases/latest)

Reports, inventories and logs contain organization data. Keep them private and remove sensitive values before requesting help.

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.

Coordinate every cutover with the partner organizations.
