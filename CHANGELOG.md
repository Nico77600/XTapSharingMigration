# Changelog

X-TAP Sharing Migration · Nicolas Fabert

[Latest release](https://github.com/Nico77600/XTapSharingMigration/releases/latest) · [User guide](package/docs/XTapSharingMigration-UserGuide.md)

## 1.0.4 — 9 November 2026

### What changed for you

- **Calendar Sharing scopes are written correctly.** An explicit `All` uses `All/group` for both named sharing and Anonymous publishing. Free/Busy and MailTips keep `All/user`.
- **Plan detects the difference.** Resource type is part of scope comparison. An old `All/user` is no longer reported as matching `All/group`; `Keep` preserves it and reports a conflict. `Merge` requires a deliberate `Replace` to change a differently typed `All`.
- **Each Sharing Policy keeps its own users.** Even a single policy defaults to a mailbox security group instead of an assumed tenant-wide scope. Missing or incomplete assignments and extra group members block automatic policy-scoped actions pending review. Members are never removed automatically.
- **Cutover instructions are feature-specific.** Test Calendar Sharing while Sharing Policies remain enabled. Wildcard retirement and cleanup commands are commented out to protect on-premises/hybrid dependencies. Re-enabling a Sharing Policy alone does not override applicable X-TAP capabilities.
- **Getting started is clearer.** Latest-release links point to the ready-to-run ZIP; the guides separate download, configuration, read-only steps and changes. Reports distinguish stored configuration from working sharing.

### Observations behind these changes

Testing showed that the detail levels offered to users can differ from what the legacy Sharing Policies are set to, and that they can change after the X-TAP settings have been applied. This supports testing applicable X-TAP directly without disabling the fallback, but does **not** isolate propagation, a service update or the scope change as the cause.

The script could also write `All/user` and then treat it as equivalent to `All/group`. Offline regressions now cover the exact payload, scope mismatch detection, policy membership and repeat-run behavior. Offered levels and configuration readback are **not** proof of a completed invitation, acceptance or calendar-read workflow.

**Before upgrading:** use a fresh Collect, review saved configuration and `Selection.csv` overrides, then run Plan. `All` remains available when you explicitly want tenant-wide sharing.

**Checks recorded at the time:** 61 offline Pester tests, including regressions for the scope payload, scope comparison, Sharing Policy membership and repeat runs.

## 1.0.3 — 2 October 2026

- **Clearer confirmation.** `YES`, `yes` and surrounding spaces are accepted; any other answer cancels and says why. Cancellation changes nothing and keeps exit code `2`.
- **Phase-specific summaries.** Already-in-place counts and blocked actions are attributed to the phase being run.
- **A useful “nothing to do” result.** The console and reports explain whether settings are already in place, the phase is unnecessary, items are blocked or nothing was selected, with the next step.
- **Clearer setup guidance.** Module installation and two-administrator instructions were expanded.

**Checks recorded at the time:** 50 offline Pester tests. The changes addressed confusing cancellation and no-change summaries, not new sharing permissions.

## 1.0.2 — 1 October 2026

- **The right administrator is expected.** `Plan -Phase Entra` uses the Entra account; recorded level choices use the account of the current run.
- **Two-administrator handover is documented.** Both phases use the same Collect folder, configuration and selection.
- **README presentation was refreshed.** Light/dark graphics and clearer report previews were added.

**Checks recorded at the time:** 47 offline Pester tests.

## 1.0.1 — 1 October 2026

- **Hybrid and on-premises partners stay excluded.** They can no longer be forced into migration through `Selection.csv`, even when disabled or unused.
- **Troubleshooting shows what to inspect.** Browser examples distinguish Free/Busy, silent MailTips and a calendar share refused by policy.

**Observations behind the change:** browser captures showed that offered sharing levels could still be followed by a refused share. Out-of-scope MailTips could look like “no automatic reply”. The recorded offline suite had 46 tests.

## 1.0.0 — 1 October 2026

First public version.

- **Collect:** read-only inventory of Exchange Online sharing, mailbox assignments, X-TAP settings and partner domains, with reports and Exchange object backups.
- **Plan:** preview the target configuration, confirm partner tenant IDs and choose users and detail levels.
- **Apply:** separate Entra and Exchange phases, confirmation, dependency handling and configuration readback.
- **Keep by default:** preserve existing capabilities rather than silently widen their scopes.
- **Manual cutover:** proposed Exchange commands with warnings and rollback, never executed by the tool.
- **Offline reports and guides:** HTML, CSV, console summaries, packaging and documentation tools.

**Observations behind the defaults:** authentication order mattered when Graph and Exchange modules shared a session; an existing group scope must not be widened silently; default collaboration trust must be reported rather than automatically changed. The recorded offline suite had 45 tests.
