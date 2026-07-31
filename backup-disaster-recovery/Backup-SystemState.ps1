<#
.SYNOPSIS
    Runs a System State backup of this server (DC01) to a dedicated backup drive
    using wbadmin, with pre-flight checks, full logging, and verification that
    the backup actually succeeded.

.DESCRIPTION
    "System State" on a Domain Controller is the bundle Windows needs to rebuild
    the machine's identity and the directory itself: the AD database (NTDS.dit),
    SYSVOL (Group Policy and logon scripts), the registry, boot files, and the
    COM+ database. It is THE backup that matters on a DC  -  losing it means
    rebuilding the domain from scratch.

    PowerShell 5.1 compatible. Windows Server 2022. Must run elevated.

    WHY wbadmin.exe AND NOT THE WindowsServerBackup POWERSHELL MODULE?
    Both work. The module (New-WBPolicy / Add-WBSystemState / Start-WBBackup)
    gives you PowerShell objects and is nicer for building recurring policies.
    We use wbadmin.exe here, deliberately, for three reasons:
      1. Exit codes: wbadmin sets a clean process exit code we can trust
         ($LASTEXITCODE), which is exactly what an unattended scheduled job
         needs to report success/failure accurately.
      2. Symmetry: the RESTORE side of this project (see the disaster recovery
         runbook) is wbadmin in DSRM  -  there is no PowerShell-module path for a
         System State recovery. Using one tool for both directions means the
         commands you practice are the commands you'd use in a real recovery.
      3. Ubiquity: wbadmin syntax is what you'll find in Microsoft docs, exam
         objectives, and every DR guide ever written. Knowing it IS the skill.

.PARAMETER BackupTarget
    Drive letter of the DEDICATED backup volume, in the form "E:".

    WHY A SEPARATE VOLUME? Backing up to the same disk you're protecting is a
    classic rookie mistake: if that disk dies, it takes the backup with it  - 
    you had redundancy of nothing. wbadmin will actually refuse a target that's
    part of the backup (a "critical volume") for exactly this reason. In this
    lab the target is a second virtual disk attached to the DC01 VM; in
    production it would be a separate physical disk, a NAS/UNC path, or  - 
    better  -  rotated offsite/cloud copies (the "3-2-1 rule": 3 copies, 2
    different media, 1 offsite).

.PARAMETER MinimumFreeGB
    Abort if the target has less than this many GB free. Default 15. A Server
    2022 DC System State typically lands around 10-14 GB, and wbadmin keeps
    older versions until space forces deletion, so we want headroom.

.EXAMPLE
    .\Backup-SystemState.ps1 -BackupTarget E:

.EXAMPLE
    # Preview mode  -  runs all the pre-flight checks but does NOT start a backup:
    .\Backup-SystemState.ps1 -BackupTarget E: -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    # ValidatePattern rejects bad input BEFORE the script body even runs.
    # '^[A-Za-z]:$' means: exactly one letter followed by a colon ("E:").
    # This blocks accidental inputs like "E:\" or "E:\Backups"  -  wbadmin's
    # -backupTarget wants a bare drive letter (or a UNC path, which we keep
    # out of scope here to keep the validation honest).
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$BackupTarget,

    [Parameter(Mandatory = $false)]
    [int]$MinimumFreeGB = 15
)

# ============================================================================
# CONFIGURATION
# ============================================================================
# Normalize the drive letter to uppercase so logs and comparisons are consistent.
$BackupTarget = $BackupTarget.ToUpper()

$LogFolder = Join-Path -Path $PSScriptRoot -ChildPath "Logs"

# ============================================================================
# LOGGING  -  identical pattern to New-Employee.ps1 / Check-SystemHealth.ps1
# so the whole portfolio reads as one consistent codebase.
# ============================================================================
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogFolder ("SystemStateBackup_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO"
    )
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

Write-Log "===== Backup-SystemState.ps1 started ====="
Write-Log "Target: $BackupTarget  MinimumFreeGB: $MinimumFreeGB  Computer: $env:COMPUTERNAME"

# ============================================================================
# PRE-FLIGHT CHECK 1: Are we running elevated?
# ============================================================================
# System State backups touch the AD database and registry  -  Windows requires
# Administrator (or Backup Operator) rights. Checking up front produces a clear
# message instead of a cryptic wbadmin "access denied" twenty seconds in.
#
# How this works: we ask Windows for our current identity, wrap it in a
# WindowsPrincipal (which can answer role questions), and ask "am I in the
# built-in Administrators role right now?"  -  "right now" matters because with
# UAC you can BE an admin but be running non-elevated.
$identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "This script must run ELEVATED (Run as Administrator). System State backup requires admin rights." -Level ERROR
    exit 1
}
Write-Log "Elevation check passed (running as administrator)."

# ============================================================================
# PRE-FLIGHT CHECK 2: Is the Windows Server Backup feature installed?
# ============================================================================
# wbadmin.exe exists on every server, but the System State backup capability
# only works once the Windows-Server-Backup FEATURE is installed. Checking the
# feature (not just the exe) is the difference between a helpful error and a
# confusing one.
try {
    $wsbFeature = Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction Stop
}
catch {
    Write-Log "Could not query Windows features: $($_.Exception.Message)" -Level ERROR
    exit 1
}

if (-not $wsbFeature.Installed) {
    Write-Log "The Windows Server Backup feature is NOT installed." -Level ERROR
    Write-Log "Install it (one time, no reboot needed) with:  Install-WindowsFeature Windows-Server-Backup" -Level ERROR
    Write-Log "Then re-run this script." -Level ERROR
    exit 1
}
Write-Log "Windows Server Backup feature is installed."

# ============================================================================
# PRE-FLIGHT CHECK 3: Does the target drive exist, and is it a sane choice?
# ============================================================================
# Get-CimInstance Win32_LogicalDisk gives us existence, type, and free space in
# one query. DriveType 3 = local fixed disk (what we want for a backup VHDX).
$targetDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID = '$BackupTarget'" -ErrorAction SilentlyContinue

if ($null -eq $targetDisk) {
    Write-Log "Backup target '$BackupTarget' does not exist on this machine. Attach/online the backup disk first (see README for the Hyper-V + Initialize-Disk steps)." -Level ERROR
    exit 1
}

# Refuse to back up TO the volume we're protecting. $env:SystemDrive is "C:"  - 
# a System State backup always includes the system volume's critical files, so
# targeting C: would be a backup that dies with the disk it lives on. wbadmin
# itself would object, but failing here with a plain-English reason is better.
if ($BackupTarget -eq $env:SystemDrive.ToUpper()) {
    Write-Log "Backup target is the SYSTEM drive ($env:SystemDrive). A backup stored on the volume it protects is not a backup  -  use a dedicated second disk." -Level ERROR
    exit 1
}

if ($targetDisk.DriveType -ne 3) {
    # Not fatal  -  a USB disk (type 2) might be legitimate  -  but worth flagging.
    Write-Log "Target '$BackupTarget' is not a fixed disk (DriveType=$($targetDisk.DriveType)). Continuing, but confirm this is really your backup disk." -Level WARN
}

# ============================================================================
# PRE-FLIGHT CHECK 4: Free space
# ============================================================================
# We can't know the exact backup size in advance (it depends on the AD database
# and how much wbadmin can reuse from previous versions), so we enforce a
# configurable floor instead. Better to abort now with a clear message than to
# fail at 90% complete after twenty minutes.
$freeGB = [math]::Round($targetDisk.FreeSpace / 1GB, 1)
$sizeGB = [math]::Round($targetDisk.Size / 1GB, 1)
Write-Log "Target $BackupTarget has $freeGB GB free of $sizeGB GB total."

if ($freeGB -lt $MinimumFreeGB) {
    Write-Log "Only $freeGB GB free on $BackupTarget  -  below the $MinimumFreeGB GB minimum. Free up space or use a larger disk. (wbadmin auto-deletes the OLDEST System State versions when full, but starting a backup into a nearly-full disk risks failure mid-run.)" -Level ERROR
    exit 1
}
Write-Log "Free space check passed."

# ============================================================================
# RECORD WHAT EXISTS BEFORE THE BACKUP
# ============================================================================
# We list existing backup versions BEFORE running, so that afterwards we can
# prove a NEW version appeared. This is the difference between "the command
# ran" and "a backup now exists"  -  which is the whole point of the exercise.
#
# 2>&1 merges wbadmin's error stream into its output stream so we capture
# everything into one variable; Out-String flattens it to plain text.
$versionsBefore = (& wbadmin get versions "-backupTarget:$BackupTarget" 2>&1 | Out-String)
$countBefore = ([regex]::Matches($versionsBefore, "Version identifier")).Count
Write-Log "Existing backup versions on target before this run: $countBefore"

# ============================================================================
# RUN THE BACKUP
# ============================================================================
# $PSCmdlet.ShouldProcess: in a normal run this returns $true and the backup
# runs; with -WhatIf it prints "What if: ..." and skips  -  but note that all the
# pre-flight checks above STILL ran, so -WhatIf doubles as a "validate my
# environment" mode. That's deliberate: checks are read-only, so they're safe
# to always run, and a preview that validates nothing wouldn't tell you much.
if ($PSCmdlet.ShouldProcess("$env:COMPUTERNAME", "Run System State backup to $BackupTarget")) {

    Write-Log "Starting System State backup  -  this typically takes 10-30 minutes on a lab DC. Progress lines from wbadmin follow."
    $startTime = Get-Date

    # About the arguments:
    #   start systemstatebackup   = the operation
    #   -backupTarget:E:          = where the backup goes (note: colon syntax,
    #                               no space  -  wbadmin is picky about this)
    #   -quiet                    = don't stop to ask "do you want to start? Y/N",
    #                               which would hang forever in a scheduled task
    #
    # We use the call operator (&) with separate argument strings rather than
    # building one big string and using Invoke-Expression  -  Invoke-Expression
    # re-parses text as code and is a well-known injection foot-gun; & passes
    # arguments literally and safely.
    $wbOutput = & wbadmin start systemstatebackup "-backupTarget:$BackupTarget" -quiet 2>&1 | Out-String

    # $LASTEXITCODE is PowerShell's record of the last NATIVE EXE's exit code.
    # Capture it IMMEDIATELY  -  any other native command we run would overwrite it.
    $wbExitCode = $LASTEXITCODE
    $elapsed = (Get-Date) - $startTime

    # Write wbadmin's full output into our log file (but not the console  -  it's
    # long). The log is where you'd go to diagnose a failure.
    Add-Content -Path $LogFile -Value "----- wbadmin output begin -----" -Encoding UTF8
    Add-Content -Path $LogFile -Value $wbOutput -Encoding UTF8
    Add-Content -Path $LogFile -Value "----- wbadmin output end -----" -Encoding UTF8

    Write-Log ("wbadmin finished in {0:hh\:mm\:ss} with exit code {1}." -f $elapsed, $wbExitCode)

    # ------------------------------------------------------------------------
    # VERIFY: exit code AND output text AND a new version on disk.
    # ------------------------------------------------------------------------
    # Three layers of verification, because each alone can mislead:
    #   - Exit code 0 is necessary but we've all seen tools exit 0 on failure.
    #   - The success phrase confirms wbadmin's own view of the result.
    #   - A new "Version identifier" on the target proves a restorable artifact
    #     actually exists  -  the only verification that ultimately matters.
    if ($wbExitCode -ne 0) {
        Write-Log "BACKUP FAILED  -  wbadmin exit code $wbExitCode. See the log for full wbadmin output: $LogFile" -Level ERROR
        exit 1
    }

    if ($wbOutput -notmatch "successfully") {
        Write-Log "wbadmin exited 0 but its output does not report success  -  treating as FAILED. Review the log: $LogFile" -Level ERROR
        exit 1
    }

    $versionsAfter = (& wbadmin get versions "-backupTarget:$BackupTarget" 2>&1 | Out-String)
    $countAfter = ([regex]::Matches($versionsAfter, "Version identifier")).Count

    if ($countAfter -gt $countBefore) {
        # Pull the LAST "Version identifier: MM/DD/YYYY-HH:MM" line  -  that's our
        # new backup, and that identifier string is exactly what you feed to
        # "wbadmin start systemstaterecovery -version:..." in a restore.
        $lastVersion = ([regex]::Matches($versionsAfter, "Version identifier:\s*(\S+)") |
                        Select-Object -Last 1).Groups[1].Value
        Write-Log "BACKUP SUCCEEDED. New version on ${BackupTarget}: $lastVersion (versions on target: $countBefore -> $countAfter)" -Level SUCCESS
        Write-Log "To restore from this backup you would reference: -version:$lastVersion (see DISASTER-RECOVERY-RUNBOOK.md)"
    }
    else {
        # Exit code said success but no new version is visible  -  rare, but this
        # is exactly the silent failure mode the verification exists to catch.
        Write-Log "wbadmin reported success but NO new backup version is visible on $BackupTarget ($countBefore -> $countAfter). Treating as FAILED  -  investigate before trusting this backup." -Level ERROR
        exit 1
    }
}
else {
    # -WhatIf path: all checks passed, no backup was run.
    Write-Log "Preview mode: all pre-flight checks PASSED. No backup was started (remove -WhatIf to run it)."
}

Write-Log "===== Backup-SystemState.ps1 finished ====="
exit 0
