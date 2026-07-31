# Backup & Recovery — Backup-SystemState.ps1 & Restore-DeletedADObject.ps1

Extends the AD lifecycle + health check portfolio with the CompTIA A+ Operational
Procedures layer: scheduled backups, tested restores, and a documented disaster
recovery procedure (see `DISASTER-RECOVERY-RUNBOOK.md`).

## Prerequisites — one-time setup on DC01

### 1. A dedicated backup disk (E:)

Never back up a volume to itself. In this Hyper-V lab, attach a second virtual
disk to DC01. On the **Hyper-V host**:

```powershell
New-VHD -Path "D:\VMs\DC01\DC01-Backup.vhdx" -SizeBytes 60GB -Dynamic
Add-VMHardDiskDrive -VMName "DC01" -Path "D:\VMs\DC01\DC01-Backup.vhdx"
```

Then **inside DC01**, bring it online and format it as E::

```powershell
Get-Disk | Where-Object PartitionStyle -eq 'RAW' |
    Initialize-Disk -PartitionStyle GPT -PassThru |
    New-Partition -DriveLetter E -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "Backups"
```

Size guidance: a Server 2022 DC System State runs roughly 10–14 GB per version,
and wbadmin keeps older versions until space runs out (then prunes oldest-first),
so 60 GB comfortably holds several versions.

### 2. The Windows Server Backup feature

```powershell
Install-WindowsFeature Windows-Server-Backup
```

One time, no reboot needed. The backup script checks for this and refuses to run
without it.

### 3. Enable the AD Recycle Bin (one-time, forest-level, IRREVERSIBLE)

```powershell
Enable-ADOptionalFeature 'Recycle Bin Feature' `
    -Scope ForestOrConfigurationSet -Target 'corp.local'
```

Two things to know before you press Enter:

- **It cannot be disabled afterwards.** There is no `Disable-ADOptionalFeature`
  path for this. (In practice nobody ever wants to turn it off — but "this
  change is irreversible, and I knew that before I made it" is exactly the kind
  of thing to be able to say in an interview.)
- **It is not retroactive.** Objects deleted *before* enabling it are only
  tombstones and can't be fully restored this way. Enable it on day one of any
  new domain.

Verify: `Get-ADOptionalFeature -Filter * | Select Name, EnabledScopes` — the
Recycle Bin Feature should show a non-empty EnabledScopes.

## Running the backup

```powershell
# Preview: runs every pre-flight check (elevation, feature, target disk,
# free space) but starts no backup — a "validate my environment" mode:
.\Backup-SystemState.ps1 -BackupTarget E: -WhatIf

# Real run (10–30 minutes on a lab DC):
.\Backup-SystemState.ps1 -BackupTarget E:

# With a custom free-space floor:
.\Backup-SystemState.ps1 -BackupTarget E: -MinimumFreeGB 20
```

### Example output

```
[2026-07-30 23:00:01] [INFO] ===== Backup-SystemState.ps1 started =====
[2026-07-30 23:00:01] [INFO] Target: E:  MinimumFreeGB: 15  Computer: DC01
[2026-07-30 23:00:01] [INFO] Elevation check passed (running as administrator).
[2026-07-30 23:00:02] [INFO] Windows Server Backup feature is installed.
[2026-07-30 23:00:02] [INFO] Target E: has 47.3 GB free of 59.9 GB total.
[2026-07-30 23:00:02] [INFO] Free space check passed.
[2026-07-30 23:00:04] [INFO] Existing backup versions on target before this run: 3
[2026-07-30 23:00:04] [INFO] Starting System State backup — this typically takes 10-30 minutes...
[2026-07-30 23:19:41] [INFO] wbadmin finished in 00:19:37 with exit code 0.
[2026-07-30 23:19:44] [SUCCESS] BACKUP SUCCEEDED. New version on E:: 07/30/2026-23:00 (versions on target: 3 -> 4)
[2026-07-30 23:19:44] [INFO] To restore from this backup you would reference: -version:07/30/2026-23:00
```

The script verifies success three ways — wbadmin's exit code, its output text,
and (the one that actually matters) a **new backup version visible on the
target**. Any of the three failing means exit code 1.

## Scheduling the backup (nightly, 11:00 PM)

Run elevated on DC01:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Backup-SystemState.ps1" -BackupTarget E:'

$trigger = New-ScheduledTaskTrigger -Daily -At 11:00PM

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Nightly System State Backup" `
    -Action $action -Trigger $trigger -Principal $principal `
    -Description "System State backup of DC01 to E: via Backup-SystemState.ps1"
```

**Why SYSTEM is the right run-as account here:** System State backup needs
Administrator or Backup Operator rights *on the local machine*, and the target
is a *local* disk — SYSTEM has full local rights, stores no password, and never
expires. If the target were a network share instead, SYSTEM would authenticate
as the computer account (`CORP\DC01$`), so you'd either grant that computer
account write access on the share or switch to a dedicated service account /
gMSA. Never use your own admin account — the task dies at your next password
change. (Same reasoning as the health check task; it's a pattern, not a
coincidence.)

Test it now rather than waiting for 11 PM:
`Start-ScheduledTask -TaskName "Nightly System State Backup"`, then check the
Logs folder and the task's Last Run Result (0x0 = success, 0x1 = failure).

## Running a Recycle Bin restore

Typical drill: delete a test user, then bring them back intact.

```powershell
# Create a victim, note their groups, delete them:
Get-ADUser tsmith | Remove-ADUser -Confirm:$false

# Find and preview (searches, displays, restores nothing):
.\Restore-DeletedADObject.ps1 -SearchTerm tsmith -WhatIf

# Restore for real:
.\Restore-DeletedADObject.ps1 -SearchTerm tsmith
```

### Example output

```
[2026-07-30 15:02:11] [INFO] ===== Restore-DeletedADObject.ps1 started =====
[2026-07-30 15:02:12] [INFO] AD Recycle Bin is enabled — good.

Found 1 deleted object(s) matching '*tsmith*':

  [1] Tom Smith
       Type            : user
       Deleted (approx): 7/30/2026 2:58:40 PM
       Original parent : OU=IT,OU=Employees,DC=corp,DC=local
       sAMAccountName  : tsmith

Restore 'Tom Smith' (user) back to 'OU=IT,OU=Employees,DC=corp,DC=local'? Type YES to proceed: YES
[2026-07-30 15:02:31] [SUCCESS] RESTORED 'Tom Smith' (GUID 1b2c...) to 'OU=IT,OU=Employees,DC=corp,DC=local'
[2026-07-30 15:02:31] [SUCCESS] VERIFIED: object now exists as 'CN=Tom Smith,OU=IT,OU=Employees,DC=corp,DC=local'
[2026-07-30 15:02:31] [INFO] Post-restore reminders for a user account: check whether it should be ENABLED...
```

Behavior notes:

- **Zero matches** exits cleanly (code 0) with the likely reasons: purged after
  the 180-day deleted-object lifetime, deleted before the Recycle Bin was
  enabled, or spelled differently.
- **Multiple matches** are listed with an index; you pick one, or Q to quit.
- **Deleted parent containers are detected**: if the OU an object lived in was
  also deleted, the script flags it and tells you to restore the parent first
  (AD restores objects to their original parent, which must exist — always
  restore top-down).
- Confirmation requires typing the literal word `YES` — deliberate friction for
  an action that changes the directory.

## Known limitations

- The backup script targets a local drive letter only (no UNC targets) — a
  deliberate scope cut; UNC targets change the credential story (see the
  run-as-account note above).
- One backup target, on the same host as the VM: fine for a lab, but it fails
  the 3-2-1 rule (no second medium, nothing offsite). Acknowledge this
  proactively — see TALKING_POINTS.md.
- The restore script restores one object per run (by design — restores should
  be deliberate). A mass-restore after a scripted mass-deletion would loop
  `Restore-ADObject` over a filtered set instead.
- Recycle Bin restores cover *deleted objects*. Corrupted/modified-but-not-
  deleted objects and full-DC loss are the runbook's territory, not this
  script's.
