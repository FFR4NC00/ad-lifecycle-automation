# DISASTER RECOVERY RUNBOOK — Full System State Recovery of DC01

**Scenario this runbook covers:** DC01 (the only domain controller for
corp.local) is broken badly enough that the directory itself must be recovered
from backup — corrupted AD database, botched schema change, ransomware,
catastrophic misconfiguration, or "the VM boots but the domain is wrecked."

**What this runbook is:** a manual, step-by-step procedure to study, practice
in the lab, and reference under pressure.

**What it is deliberately NOT:** a script. Full System State recovery is a
slow, high-stakes, decision-laden procedure — you must choose the right backup
version, the right restore type (authoritative vs. non-authoritative), and
verify at every stage. Automating it would remove the judgment that is the
entire job. Backups are automated; recovery is deliberate.

---

## ⚠️ READ THIS FIRST — Safety rules

1. **Practice this ONLY in the lab, and only with a safety net.** Before every
   practice run, take a Hyper-V checkpoint of DC01 on the host:

   ```powershell
   Checkpoint-VM -Name "DC01" -SnapshotName "Pre-DR-drill $(Get-Date -Format yyyy-MM-dd)"
   ```

   If the drill goes sideways, `Restore-VMCheckpoint` puts you back in minutes.
   The checkpoint is your undo button *for the drill*. It is **not** a backup
   strategy (see rule 3).

2. **Never attempt this procedure for the first time on a production DC.**
   A first attempt involves mistakes — wrong version chosen, DSRM password
   unknown, marking the wrong subtree authoritative. In the lab a mistake
   costs an afternoon; in production it can cost the domain. The only
   acceptable time to be doing this for the first time in production is never
   — which is precisely why you drill it now.

3. **In multi-DC environments, never "restore" a DC by rolling back a VM
   snapshot/checkpoint taken while it was running.** AD replication tracks
   changes with Update Sequence Numbers (USNs); rolling a live DC back in time
   makes its USNs contradict what its replication partners have already seen —
   **USN rollback** — and the other DCs quarantine it. (Server 2012+ hypervisor
   VM-GenerationID protection mitigates this for supported checkpoint
   operations, but the safe professional habit is: DCs are recovered through
   System State restore, not snapshot rollback.) In our single-DC lab there
   are no replication partners, which is why the checkpoint safety net in rule
   1 is acceptable *for drills*.

4. **Know your DSRM password before you need it.** It was set when the DC was
   promoted and it is NOT your domain admin password. If you don't know it,
   reset it now, while the DC is healthy:

   ```
   ntdsutil
     set dsrm password
       reset password on server null
       <enter and confirm the new password>
       quit
     quit
   ```

   Store it wherever your lab documents secrets. A recovery that stalls at the
   DSRM login screen is the most preventable failure in this entire runbook.

---

## Concepts you need before touching anything

### What a System State restore actually does

It rolls the machine's identity components — the AD database (NTDS.dit),
SYSVOL, registry, boot configuration — back to the moment of the backup. AD
changes made *after* that backup (new users, password changes, group edits)
are lost unless another DC replicates them back. **Your Recovery Point
Objective (RPO) is the age of your newest backup** — with the nightly 11 PM
schedule, up to ~24 hours of directory changes.

### Directory Services Restore Mode (DSRM)

A special safe-mode boot in which AD DS is **not running**, so the database
files aren't locked and can be replaced. You log in with the **local** DSRM
administrator account (`.\Administrator` + the DSRM password) — the domain is
unavailable in this mode, so domain credentials won't work. Every System State
restore on a DC happens from inside DSRM.

### Non-authoritative vs. authoritative restore — the decision that matters

- **Non-authoritative (the default — what plain `wbadmin start
  systemstaterecovery` does):** the DC is restored from backup and then, on
  normal reboot, **accepts replication from other DCs as newer truth**. The
  restored data is treated as "old," and its partners bring it up to date.
  **Use when:** the DC itself was broken (corruption, failed hardware) but the
  *directory content* on other DCs is fine. This is the standard "fix the
  broken DC" restore.

- **Authoritative:** after restoring in DSRM but **before** rebooting
  normally, you use `ntdsutil`'s *authoritative restore* to mark specific
  objects/subtrees as authoritative — their version numbers are inflated (by
  100,000 per day of backup age) so that during replication **the restored
  copies win** and propagate outward, overwriting the "newer" state on every
  other DC.
  **Use when:** the *content* is the disaster — an OU or critical objects were
  deleted, and a plain restore would just get re-deleted by replication the
  moment the DC came back online (the other DCs "know" the deletion and would
  helpfully replicate it right back).
  **Never** mark the entire database authoritative unless you fully intend to
  roll the whole domain's directory back in time — that is a domain-wide
  decision, not a repair.

- **Where the AD Recycle Bin fits:** with the Recycle Bin enabled (as in this
  lab), object deletions are recovered with `Restore-ADObject` — no reboot, no
  DSRM, attributes intact. **The Recycle Bin has made most authoritative
  restores unnecessary.** Authoritative restore remains the answer when the
  Recycle Bin wasn't enabled, the deleted-object lifetime (180 days) has
  passed, or damage goes beyond deletions. Recovery options, cheapest first:
  Recycle Bin → authoritative restore → full domain rebuild.

- **Single-DC lab reality check:** with no replication partners, nothing can
  overwrite what you restore, so a non-authoritative restore is effectively
  final and the authoritative marking is technically redundant. Understand the
  distinction anyway — it exists *because* of replication, and multi-DC is
  what production looks like. Interviewers ask this exact question (see
  TALKING_POINTS.md #2).

---

## THE PROCEDURE

### Phase 0 — Before you begin (5 minutes that save hours)

- [ ] Hyper-V checkpoint taken on the host (Safety rule 1).
- [ ] DSRM password confirmed known (Safety rule 4).
- [ ] Backup disk (E:) is attached to the VM and intact.
- [ ] List available backups and **write down the version identifier you
      intend to use**:

  ```
  wbadmin get versions -backupTarget:E:
  ```

  Each version shows a `Version identifier` like `07/30/2026-23:00`. Choose
  the most recent one from *before* the damage occurred — the newest backup is
  usually right for hardware/corruption failures, but if the disaster was a
  bad change (e.g., a destructive script run at 2 PM), you want the last
  backup *before* 2 PM, not after it.
- [ ] Backup age sanity check: a System State backup older than the tombstone /
      deleted-object lifetime (180 days by default) must not be restored —
      it reintroduces objects other DCs have long forgotten (lingering
      objects). With nightly backups this should never be an issue; verify
      anyway.

### Phase 1 — Boot DC01 into DSRM

Two ways in. The reliable, scriptable way (do this while Windows still boots):

```
bcdedit /set safeboot dsrepair
shutdown /r /t 0
```

The machine reboots directly into Directory Services Restore Mode.

Alternative when Windows is up: `msconfig` → Boot tab → Safe boot → **Active
Directory repair** → restart. If Windows won't boot normally at all: use the
recovery environment / F8-style boot menu to select **Directory Services
Repair Mode**.

**Log in as the LOCAL administrator:** username `.\Administrator`, password =
the **DSRM** password. Domain accounts will not work here — AD DS is not
running, which is the whole point.

You can confirm you're really in DSRM: the desktop shows "Safe Mode" in the
corners, and `Get-Service NTDS` shows the service stopped.

### Phase 2 — Run the System State recovery

In an elevated command prompt or PowerShell, using the version identifier you
wrote down in Phase 0:

```
wbadmin start systemstaterecovery -version:07/30/2026-23:00 -backupTarget:E: -quiet
```

- Replace the `-version:` value with **your** identifier, exactly as
  `wbadmin get versions` printed it.
- `-quiet` suppresses the interactive Y/N prompt. Omit it the first few
  practice runs so you read what wbadmin says it's about to do.
- Expect 15–45 minutes in the lab. Do not interrupt it. wbadmin prints
  progress and finishes with an explicit success or failure statement — read
  it. If it failed, **stop and diagnose**; do not reboot into normal mode on
  top of a half-restored database (this is a moment the Phase 0 checkpoint
  exists for).

### Phase 3 — DECISION POINT: authoritative or not?

**Path A — Non-authoritative (the default; the DC was broken, the data is
fine, or this is a single-DC lab):** do nothing extra here. Proceed to
Phase 4.

**Path B — Authoritative (specific deleted content must survive
replication):** while STILL in DSRM, after the wbadmin restore has succeeded
and before any normal reboot:

```
ntdsutil
  activate instance ntds
  authoritative restore
    restore subtree "OU=Sales,OU=Employees,DC=corp,DC=local"
    quit
  quit
```

- Restore the **narrowest scope that covers the damage** — a single object
  (`restore object "CN=Maria Garcia,OU=Sales,..."`) beats a subtree beats the
  entire database. Everything you mark authoritative overwrites the rest of
  the domain's view of those objects, including changes made after your
  backup.
- ntdsutil reports how many records it updated — record that number in your
  incident notes.

### Phase 4 — Return to normal boot

Remove the safeboot flag (otherwise the DC loops back into DSRM forever —
a classic gotcha):

```
bcdedit /deletevalue safeboot
shutdown /r /t 0
```

First boot after a restore is slow — SYSVOL re-initializes and services sort
themselves out. Give it several minutes before judging it.

### Phase 5 — Verify (a restore is not done until it's verified)

Run each of these on DC01 after the reboot:

```powershell
# 1. Core services running?
Get-Service NTDS, Netlogon, DNS, KDC | Format-Table Name, Status

# 2. DC health — read the output, don't just run it:
dcdiag

# 3. SYSVOL shared again? (Group Policy dies without it)
Get-SmbShare | Where-Object Name -in "SYSVOL","NETLOGON"

# 4. The directory answers queries?
Get-ADUser -Filter * | Measure-Object

# 5. If this was an authoritative restore: the recovered objects exist?
Get-ADUser -SearchBase "OU=Sales,OU=Employees,DC=corp,DC=local" -Filter *

# 6. (Multi-DC environments) replication healthy?
repadmin /showrepl
repadmin /replsummary
```

Then the test that actually matters: **log on from Client01 with a domain
account**, open a domain resource (the Home$ share), and run
`gpupdate /force` successfully. A DC that passes dcdiag but can't log a user
on hasn't been recovered.

Finally, write down what you did: which backup version, restore type,
start/end times, verification results. In production this is your incident
record; in the lab it's your portfolio evidence — and the elapsed time is your
measured **Recovery Time Objective** (see TALKING_POINTS.md #4).

### Phase 6 — After the drill (lab hygiene)

- If the drill succeeded and you want to keep the restored state: delete the
  pre-drill checkpoint (checkpoints held long-term degrade VM performance and
  are not backups).
- If the drill failed: `Restore-VMCheckpoint`, figure out what went wrong,
  fix it, run the drill again. A failed drill in the lab is a successful
  outcome of *having* a lab.
- Run a fresh backup: the restore changed system state, so your next backup
  should capture the now-known-good configuration.

---

## What can go wrong (and why each one argues for practicing in a lab)

| Failure | Cause | Prevention / response |
|---|---|---|
| Can't log into DSRM | DSRM password unknown/forgotten | Reset it with ntdsutil **while the DC is healthy** (Safety rule 4). If already locked out with no checkpoint: password reset via offline tooling or rebuild — in a lab, the checkpoint saves you. |
| DC boots into DSRM forever after restore | `safeboot` flag never removed | `bcdedit /deletevalue safeboot`, reboot. |
| Restore "succeeds," domain still broken | Restored a backup taken *after* the damage | Phase 0's "choose the version deliberately" step exists for this. Redo with an earlier version. |
| Restored objects vanish minutes after recovery (multi-DC) | Non-authoritative restore of deleted objects — partners replicated the deletion right back | That's what authoritative restore is *for* (Phase 3 Path B). |
| Post-restore changes overwritten domain-wide (multi-DC) | Over-broad authoritative restore (whole database instead of one subtree) | Narrowest scope possible; whole-database authoritative restore is a domain-rollback decision, not a repair. |
| Replication partners refuse the restored DC (multi-DC) | USN rollback from a snapshot-based "restore" | Safety rule 3: System State restore, never live-snapshot rollback, for DCs. |
| Backup unusable | Older than deleted-object/tombstone lifetime, or backup disk died with the server | Nightly schedule + monitoring the backup task's exit code; and the honest lab limitation — same-host storage — is exactly why production follows 3-2-1. |
| Kerberos failures after restore | Machine account password drift (the restored DC's secrets are older than what members expect) | Usually self-heals for member machines via secure-channel reset (`Test-ComputerSecureChannel -Repair` on an affected client). Time skew makes it worse — verify W32Time after recovery. |

---

## Scope boundary

This runbook recovers **one DC's System State**. It does not cover: full-forest
recovery (all DCs lost — a substantially bigger procedure with a specific
Microsoft-documented order of operations), bare-metal recovery of the OS
volume (System State assumes bootable-ish hardware/VM), or member-server data
recovery. Knowing where the current runbook's edges are is part of the
competency being demonstrated.
