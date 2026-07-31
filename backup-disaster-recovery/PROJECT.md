# Project Addendum: Backup & Disaster Recovery for the AD Lab

*(Extends the existing portfolio: AD user lifecycle automation + system health
monitoring. This piece adds the CompTIA A+ Operational Procedures layer —
backup strategy, tested restores, and documented disaster recovery.)*

## The business problem

Two uncomfortable truths that every IT department eventually learns the hard
way:

1. **An untested backup is not a backup — it's a hope.** Backup jobs "succeed"
   for months while quietly producing nothing restorable: the target filled
   up, the job backed up the wrong thing, the media died. The only proof a
   backup works is a restore that worked. Organizations discover this either
   through scheduled restore drills or during the actual disaster — and only
   one of those is survivable.

2. **Active Directory is a single point of failure for the entire business.**
   When AD is down, nobody logs in, no shared drive opens, no Group Policy
   applies, email authentication breaks. And AD's failure modes aren't only
   hardware — a mistaken bulk deletion or a bad script replicates everywhere
   at the speed of replication. "We have RAID" answers none of this; RAID
   faithfully mirrors your mistakes.

## What this project does about it

- **Automated, verified backups:** a scheduled nightly System State backup of
  DC01 to a dedicated disk, with pre-flight checks (feature installed,
  elevation, target sanity, free space) and — the important part — three-layer
  verification that a restorable artifact actually exists afterward (exit
  code + tool output + a new backup version visible on the target). Failures
  surface as exit code 1 in Task Scheduler, not as silence.
- **Tested object-level recovery:** an interactive AD Recycle Bin restore
  script that finds deleted objects, shows a human exactly what would be
  restored (original name, type, deletion time, original OU), demands explicit
  confirmation, restores by GUID, and verifies the object is back. Deleting
  and restoring a test user is a five-minute drill — so restores get practiced
  routinely instead of attempted for the first time during an incident.
- **A written disaster recovery runbook:** the full "DC01 died" procedure —
  DSRM, wbadmin System State recovery, the authoritative vs. non-authoritative
  decision, verification steps, and a what-can-go-wrong table — written as a
  document to drill from, deliberately *not* automated, because full-DC
  recovery is a judgment-laden procedure where automation would remove the
  judgment.

Together with the existing scripts this completes a lifecycle: accounts are
provisioned correctly (onboarding), removed safely (offboarding), the server
is watched (health check), mistakes are recoverable (Recycle Bin), and
catastrophe has a rehearsed answer (backup + runbook).

## Resume bullet points

- Implemented automated nightly System State backups of a Windows Server 2022
  domain controller (wbadmin, Task Scheduler under SYSTEM) with pre-flight
  validation and multi-layer success verification, alerting on failure via
  meaningful exit codes
- Built an interactive Active Directory Recycle Bin recovery tool
  (PowerShell) with search/preview/confirm workflow, GUID-based restore,
  deleted-parent detection, and post-restore verification — and validated it
  through repeated delete/restore drills
- Authored and lab-tested a disaster recovery runbook for full domain
  controller System State recovery, covering DSRM procedures, authoritative
  vs. non-authoritative restore decision criteria, and post-recovery
  validation (dcdiag, SYSVOL, client logon testing)
- Measured and documented recovery objectives for the environment (RPO bounded
  by nightly backup cadence; RTO measured by timed recovery drills), and
  identified the gaps against 3-2-1 backup best practice with concrete
  remediation steps

*(Interview tip: the strongest sentence you can say about this project is some
version of "I've actually restored from my backups — here's what I found the
first time I tried." Nobody expects a junior candidate to have run a DSRM
recovery; having done one, in a lab, on purpose, is a differentiator.)*
