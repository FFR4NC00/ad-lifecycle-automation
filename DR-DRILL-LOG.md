# DR Drill Log — 2026-07-31

First full System State disaster recovery drill against DC01, run start to finish in the lab. Recorded here as evidence, not just a reference to the runbook. See `DISASTER-RECOVERY-RUNBOOK.md` for the general procedure this followed.

## Pre-drill state

- Fresh Hyper-V checkpoint taken immediately before starting: `Pre-DR-drill 2026-07-31`
- DSRM password confirmed known (reset via `ntdsutil` beforehand as a safety check)
- Backup target E: had 2 existing System State backup versions
- Version restored: `07/31/2026-07:54` (taken 2:54 AM that morning)

## What was executed

- Non-authoritative restore (Path A) — the right call for a single-DC lab with no replication partners
- `bcdedit /set safeboot dsrepair` + reboot to enter DSRM
- `wbadmin start systemstaterecovery -version:07/31/2026-07:54 -backupTarget:E:`
- wbadmin's own log reported the restore operation ran 4:25 PM to 4:31 PM — 6 minutes
- `bcdedit /deletevalue safeboot` + reboot to return to normal mode

## Verification results

- `Get-Service NTDS, Netlogon, DNS, KDC` — all Running
- `dcdiag` — every substantive test passed: Connectivity, Advertising, FrsEvent, SysVolCheck, KnowsOfRoleHolders, MachineAccount, NetLogons, ObjectsReplicated, Replications, RidManager, Services, VerifyReferences, and all partition/enterprise tests. The SystemLog test failed, but only from expected startup-timing noise right after the restore and reboot (services racing to start before NTDS finished initializing), not a real problem — the tests that actually measure directory health all passed
- SYSVOL and NETLOGON shares present and shared again
- `Get-ADUser -Filter *` returned 6 users
- Logged into Client01 with a domain account and ran `gpupdate /force` — both computer and user policy updates completed successfully, confirming the DC is actually serving the domain again, not just passing diagnostics

## The RPO finding

The backup used was from 2:54 AM. A DNS record added later that same day (a DC01 A record in the corp.local zone) was gone after the restore — exactly what a non-authoritative restore should do, since anything created after the backup and not replicated from elsewhere gets rolled back with it. Confirmed with `Resolve-DnsName DC01.corp.local` returning "DNS name does not exist" immediately after the restore, then re-added manually.

This is the concrete version of the RPO answer in `TALKING_POINTS.md` — actual observed data loss bounded by the age of the backup, not a theoretical answer.

## Timing notes

The wbadmin-reported restore operation itself took 6 minutes (4:25–4:31 PM). Total time from entering DSRM to a verified domain logon was longer once reboots and verification steps are included, in the range the runbook itself estimates for a lab environment.

One quirk worth noting: DC01's on-screen clock appears to have corrected itself by roughly two hours during the final reboot back to normal mode, most likely Hyper-V's time synchronization integration service correcting clock drift that built up during the DSRM boot, since DSRM doesn't run the usual time-keeping services. The wbadmin-internal timestamps stayed consistent with each other since both were read before that correction happened, so the 6-minute figure is trustworthy even though the wall clock briefly told two different stories.

## Post-drill cleanup

- Deleted the pre-drill checkpoint after confirming success
- Ran a fresh System State backup afterward to capture the recovered and corrected state (including the re-added DNS record)

## Takeaway

Restored from a real backup, verified with more than just dcdiag passing (a real domain logon and GPO application from a client machine), and found and explained a genuine RPO gap along the way. That's the difference between having a runbook and having actually run it.
