# Changelog — X-TAP Sharing Migration

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH (see the guide, Annex E).
Author: Nicolas Fabert.

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
