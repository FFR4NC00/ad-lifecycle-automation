# Project: Active Directory Lifecycle Automation & Server Health Monitoring

## The business problem

Manual user provisioning is slow, inconsistent, and risky. When onboarding is done by hand in ADUC, every tech does it slightly differently: accounts land in the wrong OU, group memberships get forgotten (the new salesperson can't open the shared drive on day one), attributes like manager and title are skipped, and there's no record of what was done. Offboarding by hand is worse — a forgotten step means a departed employee retains live credentials and access, which is a genuine security incident waiting to happen. Meanwhile, servers fail quietly: disks fill up and services die at 2 AM, and nobody knows until users start calling.

## What this project does about it

- **Standardized, logged onboarding:** one command creates the account correctly every time — right OU, right groups, right attributes, home folder with correct NTFS permissions, temporary password with forced change at first logon — and writes an audit log of every action.
- **Security-first offboarding:** access is cut the moment the script runs (disable comes first, by design), group memberships are recorded before removal for audit/rehire purposes, and the account is preserved (never deleted) in a quarantine OU with a dated reason stamped on it.
- **Proactive health visibility:** a scheduled daily check reports disk space, critical service status, error-log activity, and resource usage, with issues surfaced at the top of the report and in the email subject line — problems get found before users find them.

A real IT department would recognize all three as junior-sysadmin bread and butter: they reduce ticket handling time, eliminate a class of human error, create the audit trail that security reviews ask for, and shift the team from reactive firefighting toward proactive maintenance.

## Deliberate design decisions (the part interviewers care about)

- Configuration is separated from logic (a single hashtable drives OU placement and group assignment), so supporting a new department is a config edit, not a code change.
- Every state-changing action supports `-WhatIf` via PowerShell's native `SupportsShouldProcess`, uses `try/catch` with `-ErrorAction Stop`, and is logged with a timestamp and severity.
- Failure handling is proportionate: a missing manager warns and continues; a failed account creation aborts; a failed email never sinks the health report that's already on disk.
- Exit codes are meaningful (0/1) so Task Scheduler and monitoring tools can consume the results.

## Resume bullet points

- Automated Active Directory user onboarding/offboarding with PowerShell, reducing a ~15-step manual ADUC process to a single audited command with dry-run (`-WhatIf`) support and full action logging
- Implemented security-first offboarding workflow: immediate account disable, audited removal of group memberships, GAL hiding, and quarantine-OU retention in place of deletion to preserve audit trails
- Built a scheduled server health-monitoring script (disk, services, event logs, CPU/RAM) with console/text/HTML reporting and email alerting, deployed via Task Scheduler under least-privilege run-as accounts
- Designed config-driven department mapping (OU + group assignment) enabling non-developers to extend the system without code changes
- Applied production scripting practices throughout: parameter validation, structured error handling with try/catch, idempotency checks, meaningful exit codes, and timestamped audit logs

*(Tip: in an interview, follow any of these with a number or a story — "in my lab, onboarding went from ~10 minutes of clicking to under 30 seconds" — concrete beats abstract.)*
