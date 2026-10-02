# Changelog — X-TAP Sharing Migration

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH (see the guide, Annex E).
Author: Nicolas Fabert.

## [1.0.3] — 2026-10-02

### Fixed
- **Apply confirmation**: `YES` is accepted in any case (`yes`, `Yes`), spaces ignored. Any other answer still cancels, but the console now says which answer was refused and that `YES` was expected, and the summary card is titled **Phase … cancelled - nothing was changed** with the changes not applied and the command to run again (it said *Phase … applied - with items to look at*). The cancellation is also the first warning of `Result.html`. Exit code `2`, as before.
- The **In place** line of an Apply summary, and the *Already in place* figure of `Result.html`, count the actions of the phase that ran only (an Exchange capability already in place was counted in the Entra phase).

### Added
- **Why a phase has nothing to change**: when an Apply (or one phase of a Plan) has nothing to change, the console, the summary card (*Why* and *Next* lines) and `Result.html` say why, in plain words: *not needed* (only Anonymous / `*` sharing policy entries for All users: they go to the default policy, so phase Entra needs no partner trust and no security group - run `-Phase Exchange`), *already in place* (the trusts, groups or capabilities, by name), *blocked* (with the next step, for example `-Phase Entra first`) or *no item is migrated*. The phase section of the console gives the same explanation instead of *Nothing in this phase*, and the Plan summary gives the next command that has something to do. An Apply with nothing to do is titled **Phase … - nothing to change**.
- **Why nothing is migrated**: step 2 of Plan and Apply gives the number of items not migrated and their reasons (out of scope: Hybrid, Disabled, TenantNotFound …; `Include = No` in `Selection.csv`; a `Features` or `Partners` rule; `-Feature`), and how many of them `Selection.csv` can force (Disabled, Unused, PartnerSide), with the path of the file. The same line is in the summary card (Plan, Apply), and Collect gives the count that can be forced.
- Guide: a note in chapter 2 (*When phase Entra has nothing to do*), the Phase Entra step of chapter 8, three rows in Annex A (*0 item(s) migrated*, *Cancelled … YES expected*, *Phase Entra - nothing to change*); exit code `2` also covers a cancelled Apply.
- 50 Pester tests.

### Changed
- An Apply counts as its own problems only the blocked actions **of its phase**: an Exchange capability in conflict no longer turns an Entra phase into *applied - with items to look at* (exit code `2`); it is listed on the *Other* line (*phase Exchange: 5 change(s) to do, 1 blocked or in conflict*).

### Documentation
- README and guide: the `Install-Module` commands use `-Force`, with what to do when an older version still conflicts; the README links and the guide summary come before the download note.

## [1.0.2] — 2026-10-01

### Fixed
- **Two administrators**: `-Mode Plan -Phase Entra` now expects the `Authentication.EntraAdmin` account (it expected `ExchangeAdmin`, so the Entra administrator was refused without `-UserPrincipalName`), and a level chosen during the Entra phase is recorded in `LevelChoices.json` under the account of that run. One function, `Get-XsmExpectedAccount`, gives the account of every mode and phase.

### Documentation
- Guide chapter 8 — **Two administrators**: the Entra and Exchange phases run separately from the same Collect folder — what to hand over (the Collect folder and the configuration, or a shared copy of the tool), `-SnapshotPath` and `-UserPrincipalName`, the same `-SelectionPath` / `-Feature`, the order and what the Exchange phase does when it runs first. Matching example in the script help and the README, two rows in Annex A, prerequisites (the Entra administrator needs only `Microsoft.Graph.Authentication`).
- README redesigned like the other repositories: light and dark graphics rendered from the guide (`tools\New-ReadmeImages.ps1`), How it works, From inventory to cutover, Reports grid, requirements per phase.
- 47 Pester tests.

## [1.0.1] — 2026-10-01

### Changed
- **Exchange hybrid and partners on Exchange Server are out of scope, and can no longer be forced.** An item classified **OnPremises** (organization relationship or availability address space whose partner endpoint is not Exchange Online) was overridable in `Selection.csv`; it is now refused, like **Hybrid**. Both are checked before every other reason (a disabled or unused hybrid / on-premises object is still reported as Hybrid / OnPremises), and the item notes give the endpoint host and the reason. The guide says it from the principles on, with a dedicated box in chapter 3 (Exchange hybrid: dedicated hybrid application; partners on Exchange Server: not impacted today according to Microsoft).

### Added
- Guide chapter 11 — **what the browser shows**: for Free/Busy (`GetSchedule`), MailTips (`GetMailTips`) and calendar sharing (`GetSharingPermissionInfo`, `CreateSharingPermission`), the action to do in Outlook on the web, the request to filter in the developer tools, and what is expected or not, with illustrations rebuilt from lab captures of both directions (in scope, out of scope with error `5016`, `7002` when X-TAP is not used, MailTips out of scope that are silent, share refused with `ErrorNotAllowedExternalSharingByPolicy` while calendar sharing was still rolling out). Annex A has the matching rows.
- 46 Pester tests.
## [1.0.0] — 2026-10-01

First public version.

### Added
- **Collect** (read-only): organization relationships (with their scope groups), availability address spaces, sharing policies and the mailboxes assigned to each of them, accepted domains, hybrid objects; current Microsoft 365 X-TAP (default and partner policies, trusts, capabilities, scope group names); Microsoft Entra tenant of each external domain (OpenID metadata, partner name from Microsoft Graph). Writes `Inventory.html`, `snapshot.json`, `Selection.csv`, `PartnersToConfirm.txt`, `SharingPolicyMailboxes.csv` and an `Export-Clixml` backup of the Exchange objects.
- **One partner configuration per tenant**: every relationship, domain or sharing policy entry of the same tenant ends in one partner policy, one trust and one capability per feature and level (scopes added).
- **Classification** of every item, in scope or out of scope with the reason: Hybrid, SameTenant, OnPremises, Disabled, Unused, TenantNotFound, Consumer, ResolutionError, NotMigratable, PartnerSide.
- **Availability address spaces** are **PartnerSide**: they let your users read the partner's free/busy, so their X-TAP equivalent is configured by the partner for your tenant ID. Nothing is configured in your tenant unless forced; the partner appears in the coordination list with what to configure; the address space is in the cutover.
- **Level choice**: several levels of the same feature for the same partner and users (for example `AvailabilityOnly` and `LimitedDetails` on two relationships) are listed by Collect and asked by an interactive Plan or Apply; answers recorded in `LevelChoices.json` next to the snapshot. Unanswered: only these items are blocked. Several sharing policies in use: one security group of mailboxes per policy (`SharingPolicy:<name>`).
- **Decisions** in this order: `Selection.csv`, `Partners` rule, `Features` rule, Exchange Online. Forced level, scope (All, object ID, configuration group, existing group by name, sharing policy group, several scopes) and partner exclusion.
- **Partner tenant ID confirmation** (`Entra.RequireConfirmedPartners`): `Partners` entry with `TenantId`, `TargetTenantId` of an availability address space, or existing partner policy; mismatch between the tenant ID given by the partner and the tenant of its domain blocks the partner.
- **Plan** and **Apply** in two phases — **Entra** (security groups, Microsoft 365 collaboration trust) and **Exchange** (capabilities in partner and default policies) — with confirmation, retries, skipped actions when a dependency failed, and verification by reading the tenant again. `-Phase All` for a Global Administrator.
- **`-Feature`** (Plan, Apply): limit a run to some features — FreeBusy, MailTips, CalendarSharing, AnonymousCalendarSharing — while a capability is not yet rolled out; the other items are listed as not in this run, above every other rule, and the cutover warns on relationships partly migrated.
- `Apply.ExistingCapability` = **Keep** (default) | Merge | Replace, `Apply.DisableOtherLevels`, `Entra.ReplaceRestrictedTrust`.
- **Manual cutover** commands per Exchange object, with rollback and cleanup, in the reports and `ManualCutover.txt`; the tool never runs them. Guide chapter 11: rollout check, partner contact (message template), change window, pre-checks, test matrix, `GetSchedule` in the browser developer tools, GO / STOP, rollback, cleanup.
- Self-contained **HTML reports** (Inventory, Plan, Result), same visual identity as Purview DLP Report; CSV of the actions; console with steps, tables and summary card; daily log file.
- **Tests**: 45 Pester tests with a simulated tenant and an in-memory Microsoft Graph; `tests\New-DemoReports.ps1`.
- `tools\Build-Documentation.ps1` (HTML guide) and `tools\New-XsmPackage.ps1` (release package, tenant values emptied and checked).

### Lab findings (2026-10-01), built into 1.0.0
- ExchangeOnlineManagement loads `Microsoft.IdentityModel` 8.19 into the session; a later interactive Graph sign-in then fails with "Method not found … WithLogging". **Collect signs in to Microsoft Graph first**, then Exchange Online.
- `Connect-MgGraph -UseDeviceCode` writes its message to the output stream: it is now shown in the console. The device code limit of the Graph module is 120 seconds.
- A Free/Busy capability scoped by hand to a group would have been widened to all users by a plain update: hence `ExistingCapability = Keep` by default.
- The default cross-tenant access policy shows `m365CollaborationInbound` blocked when it was never configured; the tool reports it and never changes the default trust.
