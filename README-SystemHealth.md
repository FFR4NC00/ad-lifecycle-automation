# Check-SystemHealth.ps1

## What it does

Runs a point-in-time health check of the local Windows machine and produces a readable report:

- **Disk space** on all local fixed drives, flagging anything under 15% free (threshold configurable)
- **Critical services** from a configurable list (defaults suit a Domain Controller: DNS Client, Server, Netlogon, NTDS, DNS Server, Windows Time), flagging anything not running
- **Error-level event log entries** from the System and Application logs over the last 24 hours, summarized by count per source
- **CPU and memory snapshot**

Output goes to the console and a timestamped text file; `-Html` adds a styled HTML version; `-SendEmail` mails the report with a subject line that carries the verdict (`[HEALTHY]` / `[ISSUES FOUND (n)]`) so it can be triaged from the inbox. Exit code is `0` when healthy and `1` when issues were found, so Task Scheduler and monitoring tools can react to it.

## Prerequisites

- Windows PowerShell 5.1 (built into Server 2016+ / Windows 10+) — no modules needed
- Local admin rights are recommended (some event log and service queries are restricted otherwise)
- For email: an SMTP server the machine can reach. Edit the `$EmailSettings` block at the top of the script (server, port, from, to, SSL). In a lab without a mail server, simply don't use `-SendEmail` — everything else works.

## How to run

```powershell
# Console + text report
.\Check-SystemHealth.ps1

# Also produce HTML
.\Check-SystemHealth.ps1 -Html

# Full monty (after configuring SMTP settings)
.\Check-SystemHealth.ps1 -Html -SendEmail

# Custom report location
.\Check-SystemHealth.ps1 -ReportFolder "C:\HealthReports"
```

## Example output

```
############################################################
 SYSTEM HEALTH REPORT
 Computer : DC01
 Time     : 2026-07-23 06:00:03
 Verdict  : ISSUES FOUND (1)
############################################################

 !! ATTENTION REQUIRED:
    - LOW DISK: Drive C: has only 11.2% free (6.7 GB)

============================================================
 DISK SPACE (flag below 15% free)
============================================================
  Drive C:      59.7 GB total      6.7 GB free  ( 11.2% free)   <-- LOW DISK SPACE

============================================================
 CRITICAL SERVICES
============================================================
  Dnscache        Running       (DNS Client)
  LanmanServer    Running       (Server)
  Netlogon        Running       (Netlogon)
  NTDS            Running       (Active Directory Domain Services)
  DNS             Running       (DNS Server)
  W32Time         Running       (Windows Time)

============================================================
 ERROR EVENTS - System & Application (last 24 hours)
============================================================
  Total Error events: 5

  Count  Source
  -----  ------
      3  Schannel
      2  DistributedCOM

============================================================
 CPU & MEMORY SNAPSHOT
============================================================
  CPU load (snapshot) : 4%
  Memory              : 2.9 GB used / 4 GB total (73% used)
```

## Scheduling with Task Scheduler

**Goal:** run every morning at 6:00 AM whether or not anyone is logged in.

### Option A — one PowerShell command (recommended, and itself a portfolio point)

Run as admin on the target machine:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Check-SystemHealth.ps1" -Html'

$trigger = New-ScheduledTaskTrigger -Daily -At 6:00AM

# SYSTEM runs with local admin rights, needs no password, and never expires.
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Daily Health Check" `
    -Action $action -Trigger $trigger -Principal $principal `
    -Description "Runs Check-SystemHealth.ps1 every morning"
```

Test it immediately: `Start-ScheduledTask -TaskName "Daily Health Check"` then check the Reports folder and the task's "Last Run Result" (0x0 = healthy, 0x1 = issues found).

### Option B — the GUI, step by step

1. Open **Task Scheduler** → **Create Task** (not "Basic Task" — you need the extra options).
2. **General tab:** name it; select **"Run whether user is logged on or not"**; tick **"Run with highest privileges"**; Configure for: your OS version.
3. **Triggers tab:** New → Daily → 6:00 AM.
4. **Actions tab:** New →
   - Program/script: `powershell.exe`
   - Arguments: `-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Check-SystemHealth.ps1" -Html`
   - (`-NoProfile` skips loading profile scripts for speed and predictability; `-ExecutionPolicy Bypass` applies only to this one process so the machine-wide policy can't silently break your scheduled job.)
5. **Settings tab:** tick "Run task as soon as possible after a scheduled start is missed."
6. Click OK. If you chose a named account instead of SYSTEM, you'll be prompted for its password.

### Run-as-account considerations (interview-worthy)

- **SYSTEM** is the simple, sane default for a *local* health check: full local rights, no password to store or rotate, keeps working after password changes. Its limitation: it accesses the network as the *computer account*, so it can't authenticate to arbitrary remote shares or SMTP servers requiring user credentials.
- **A dedicated service account** (e.g., `svc-healthcheck`) is the answer when the task must reach network resources or when you want its activity separately auditable. Grant it "Log on as a batch job," give it least privilege, and in a modern domain prefer a **gMSA** (group Managed Service Account) so Windows rotates the password automatically.
- **Never schedule tasks under your own admin account** — the task breaks at your next password change, and your personal account gains a standing unattended-execution footprint.

## About email: Send-MailMessage vs. modern alternatives

`Send-MailMessage` is built into PS 5.1 and is fine for a lab or an internal anonymous relay. Microsoft marks it obsolete because it can't do modern auth (OAuth2), which providers like Microsoft 365 and Gmail now require for direct submission. If this were pointed at M365 in production, the current approaches are: (1) the **Microsoft Graph API** (`Send-MgUserMail` from the Microsoft.Graph module, using an app registration with certificate auth), (2) the **MailKit** .NET library for full SMTP with OAuth, or (3) an internal SMTP relay/connector that accepts unauthenticated mail from known server IPs — which is what most on-prem monitoring actually uses. Knowing *why* the old cmdlet is deprecated and what replaces it is a stronger interview answer than either blindly using or blindly avoiding it.

## Known limitations

- **CPU/memory are single snapshots**, not averages — a momentary spike can false-alarm and a duty-cycle problem can hide between runs. Real monitoring (PRTG, Zabbix, SCOM, Prometheus) samples continuously; this script is a daily report card, not a monitoring platform.
- **Local machine only.** Extending to multiple servers means either a foreach over `Invoke-Command` (PowerShell Remoting) from a central admin box, or deploying the task to each machine and centralizing reports — both are natural next iterations.
- **Event summarization counts by source only**; it doesn't dedupe message text or track trends across days.
- **Thresholds are static.** A 2 TB drive at 14% free (287 GB) is not an emergency; percent-only thresholds are naive. A better rule combines percent and absolute GB.
