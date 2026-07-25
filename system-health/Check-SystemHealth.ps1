<#
.SYNOPSIS
    Runs a health check on the local Windows machine: disk space, critical
    services, recent error events, CPU and memory  -  then produces a console
    report, an optional text/HTML file, and an optional email alert.

.DESCRIPTION
    Designed to run unattended via Task Scheduler (see the README for exact
    setup steps), but works fine run interactively too.

    PowerShell 5.1 compatible. Uses CIM (Get-CimInstance) rather than the older
    WMI cmdlets  -  CIM is the modern replacement and works over firewall-friendly
    WinRM if you later extend this to remote machines.

.PARAMETER ReportFolder
    Where report files are written. Defaults to a "Reports" folder next to the script.

.PARAMETER Html
    Also produce an HTML version of the report (nicer for emailing/browsing).

.PARAMETER SendEmail
    Send the report by email using the SMTP settings in the CONFIGURATION block.
    Leave off until you've filled in real SMTP values.

.EXAMPLE
    .\Check-SystemHealth.ps1

.EXAMPLE
    .\Check-SystemHealth.ps1 -Html -SendEmail
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ReportFolder = (Join-Path $PSScriptRoot "Reports"),

    [switch]$Html,

    [switch]$SendEmail
)

# ============================================================================
# CONFIGURATION  -  *** EDIT TO MATCH YOUR ENVIRONMENT ***
# ============================================================================

# Flag any drive with less than this % free. 15% is a common ops threshold:
# low enough to avoid noise, high enough to leave time to react before a
# full disk starts breaking services.
$DiskFreePercentThreshold = 15

# Services that MUST be running on this machine. The defaults below make sense
# for a Domain Controller lab. Use each service's short name (the "Service
# name" in services.msc, not the display name). Find names with:
#   Get-Service | Sort DisplayName | Format-Table Name, DisplayName
$CriticalServices = @(
    "Dnscache",     # DNS Client
    "LanmanServer", # Server (file/print sharing)
    "Netlogon",     # Domain logon channel
    "NTDS",         # Active Directory Domain Services (DC only  -  remove on a client)
    "DNS",          # DNS Server (DC only  -  remove on a client)
    "W32Time"       # Windows Time (Kerberos breaks if clocks drift!)
)

# How far back to scan event logs, in hours.
$EventLookbackHours = 24

# --- Email settings (placeholders  -  fill in your own) -----------------------
$EmailSettings = @{
    SmtpServer = "smtp.corp.local"          # <-- your SMTP relay / mail server
    Port       = 25                          # 25 for internal relay, 587 for auth'd submission
    From       = "healthcheck@corp.local"    # <-- sender address
    To         = "admin@corp.local"          # <-- who gets the report
    UseSsl     = $false                      # $true if your server requires TLS (usually with 587)
}
# NOTE on Send-MailMessage: it works fine in PowerShell 5.1 but Microsoft has
# marked it obsolete because it doesn't support modern authentication (OAuth).
# For a lab or an internal anonymous relay it's the simplest option, and it's
# what we use below. The README covers the modern alternatives (Microsoft
# Graph API / MailKit) and when you'd need them  -  knowing that trade-off is a
# good interview talking point.

# ============================================================================
# SETUP
# ============================================================================
if (-not (Test-Path $ReportFolder)) {
    New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
}

$Timestamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$ComputerName = $env:COMPUTERNAME
$ReportTxt    = Join-Path $ReportFolder "HealthCheck_${ComputerName}_$Timestamp.txt"

# We collect findings into these two lists as we go, then decide at the end
# whether the machine is "HEALTHY" or "ISSUES FOUND". Separating data
# collection from reporting keeps each check simple and makes it easy to add
# new checks later  -  they just need to append to these lists.
$Issues   = New-Object System.Collections.Generic.List[string]
$Sections = New-Object System.Collections.Generic.List[string]

function Add-Section {
    # Small helper: every check hands its formatted output here so the final
    # report assembles itself in order.
    param([string]$Title, [string[]]$Lines)
    $Sections.Add(("=" * 60))
    $Sections.Add(" $Title")
    $Sections.Add(("=" * 60))
    foreach ($l in $Lines) { $Sections.Add($l) }
    $Sections.Add("")
}

# ============================================================================
# CHECK 1: DISK SPACE
# ============================================================================
# Win32_LogicalDisk with DriveType=3 means "local fixed disks"  -  this filter
# excludes CD-ROM drives (5), network drives (4), and removable media (2),
# which would otherwise clutter the report or false-alarm at 0% free.
$diskLines = @()
$disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType = 3"

foreach ($disk in $disks) {
    # Guard against a 0-size volume (rare, but division by zero kills scripts).
    if ($disk.Size -eq 0) { continue }

    # Sizes come back in BYTES. 1GB is a PowerShell numeric literal constant  - 
    # dividing by it converts bytes to gigabytes cleanly.
    $sizeGB = [math]::Round($disk.Size / 1GB, 1)
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    $freePct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)

    $line = "  Drive {0}  {1,8} GB total  {2,8} GB free  ({3,5}% free)" -f $disk.DeviceID, $sizeGB, $freeGB, $freePct

    if ($freePct -lt $DiskFreePercentThreshold) {
        $line += "   <-- LOW DISK SPACE"
        # Also record it as an issue for the overall verdict + email subject.
        $Issues.Add("LOW DISK: Drive $($disk.DeviceID) has only $freePct% free ($freeGB GB)")
    }
    $diskLines += $line
}
Add-Section -Title "DISK SPACE (flag below $DiskFreePercentThreshold% free)" -Lines $diskLines

# ============================================================================
# CHECK 2: CRITICAL SERVICES
# ============================================================================
$serviceLines = @()
foreach ($svcName in $CriticalServices) {
    # SilentlyContinue: if a service doesn't exist on this machine (e.g., the
    # "DNS" server service on a client VM), Get-Service returns $null instead
    # of spraying red errors. We report "not installed" as informational  - 
    # you should trim the list per machine, but the script shouldn't crash.
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue

    if ($null -eq $svc) {
        $serviceLines += "  {0,-15} NOT INSTALLED on this machine (remove from `$CriticalServices?)" -f $svcName
        continue
    }

    if ($svc.Status -eq "Running") {
        $serviceLines += "  {0,-15} Running       ({1})" -f $svc.Name, $svc.DisplayName
    }
    else {
        $serviceLines += "  {0,-15} {1,-13} ({2})   <-- NOT RUNNING" -f $svc.Name, $svc.Status, $svc.DisplayName
        $Issues.Add("SERVICE DOWN: '$($svc.DisplayName)' ($($svc.Name)) is $($svc.Status)")
    }
}
Add-Section -Title "CRITICAL SERVICES" -Lines $serviceLines

# ============================================================================
# CHECK 3: RECENT ERROR EVENTS (System + Application, last N hours)
# ============================================================================
# Get-WinEvent with -FilterHashtable does the filtering ON the event log
# service itself, which is dramatically faster than fetching every event and
# filtering in PowerShell (the classic Get-EventLog ... | Where-Object trap  - 
# that approach can take minutes on a busy server; this takes seconds).
#   LogName   = which logs to search (accepts an array)
#   Level     = 2 means "Error" (1=Critical, 3=Warning, 4=Information)
#   StartTime = only events newer than this
$eventLines = @()
$since = (Get-Date).AddHours(-$EventLookbackHours)

# If there are ZERO matching events, Get-WinEvent throws an error instead of
# returning an empty list (a well-known quirk). SilentlyContinue turns that
# into a $null result, which our checks below handle as "no errors  -  good!".
$errorEvents = Get-WinEvent -FilterHashtable @{
    LogName   = @("System", "Application")
    Level     = 2
    StartTime = $since
} -ErrorAction SilentlyContinue

if ($null -eq $errorEvents -or $errorEvents.Count -eq 0) {
    $eventLines += "  No Error-level events in the last $EventLookbackHours hours."
}
else {
    $eventLines += "  Total Error events: $($errorEvents.Count)"
    $eventLines += ""
    $eventLines += "  Count  Source"
    $eventLines += "  -----  ------"

    # Group-Object collapses the events by source so the report says
    # "37 x Schannel" instead of listing 37 near-identical lines. Summarizing
    # is what makes a report actually readable at 7am.
    $grouped = $errorEvents | Group-Object -Property ProviderName | Sort-Object Count -Descending
    foreach ($g in $grouped) {
        $eventLines += "  {0,5}  {1}" -f $g.Count, $g.Name
    }

    # A busy error log is worth flagging, but with a softer threshold  -  a
    # couple of errors a day is normal Windows background noise.
    if ($errorEvents.Count -gt 20) {
        $Issues.Add("EVENT LOG: $($errorEvents.Count) Error events in the last $EventLookbackHours hours (top source: $($grouped[0].Name))")
    }
}
Add-Section -Title "ERROR EVENTS - System & Application (last $EventLookbackHours hours)" -Lines $eventLines

# ============================================================================
# CHECK 4: CPU + MEMORY SNAPSHOT
# ============================================================================
# NOTE: this is a point-in-time SNAPSHOT, not an average over time. A single
# spike at the moment the script runs can look scary. That limitation (and
# how real monitoring tools solve it with sampling over time) is called out
# in the README and is a great interview talking point.
$perfLines = @()

# CPU: LoadPercentage per CPU socket, averaged (multi-socket servers).
$cpuLoad = (Get-CimInstance -ClassName Win32_Processor |
            Measure-Object -Property LoadPercentage -Average).Average
$cpuLoad = [math]::Round($cpuLoad, 0)

# Memory: Win32_OperatingSystem reports these in KILOBYTES (yes, really  - 
# a different unit than the disk class uses; always check the docs).
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$totalMemGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)   # KB / 1MB = GB
$freeMemGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$usedMemGB  = [math]::Round($totalMemGB - $freeMemGB, 1)
$memUsedPct = [math]::Round(($usedMemGB / $totalMemGB) * 100, 0)

$perfLines += "  CPU load (snapshot) : $cpuLoad%"
$perfLines += "  Memory              : $usedMemGB GB used / $totalMemGB GB total ($memUsedPct% used)"

if ($cpuLoad -gt 90)    { $Issues.Add("CPU: load snapshot at $cpuLoad%") }
if ($memUsedPct -gt 90) { $Issues.Add("MEMORY: $memUsedPct% used ($freeMemGB GB free)") }

Add-Section -Title "CPU & MEMORY SNAPSHOT" -Lines $perfLines

# ============================================================================
# ASSEMBLE THE REPORT
# ============================================================================
if ($Issues.Count -eq 0) {
    $verdict = "HEALTHY"
}
else {
    $verdict = "ISSUES FOUND ($($Issues.Count))"
}

$header = @(
    ("#" * 60),
    " SYSTEM HEALTH REPORT",
    " Computer : $ComputerName",
    " Time     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    " Verdict  : $verdict",
    ("#" * 60),
    ""
)

# If anything was flagged, put a summary of the problems right at the top  - 
# nobody should have to read the whole report to learn something is on fire.
if ($Issues.Count -gt 0) {
    $header += " !! ATTENTION REQUIRED:"
    foreach ($i in $Issues) { $header += "    - $i" }
    $header += ""
}

$reportText = ($header + $Sections) -join [Environment]::NewLine

# --- Console output ---
if ($Issues.Count -gt 0) {
    Write-Host $reportText -ForegroundColor Yellow
}
else {
    Write-Host $reportText
}

# --- Text file ---
$reportText | Out-File -FilePath $ReportTxt -Encoding UTF8
Write-Host "Report saved: $ReportTxt" -ForegroundColor Cyan

# --- Optional HTML file ---
# HTML version = same content, but styled, and low-disk / stopped-service
# rows are easy to spot. We build it by hand with a here-string rather than
# ConvertTo-Html so you can see exactly how the sausage is made.
$ReportHtml = $null
if ($Html) {
    $ReportHtml = Join-Path $ReportFolder "HealthCheck_${ComputerName}_$Timestamp.html"

    if ($Issues.Count -gt 0) { $verdictColor = "#c0392b" } else { $verdictColor = "#27ae60" }

    $issuesHtml = ""
    if ($Issues.Count -gt 0) {
        $issueItems = ($Issues | ForEach-Object { "<li>$_</li>" }) -join ""
        $issuesHtml = "<div class='issues'><strong>Attention required:</strong><ul>$issueItems</ul></div>"
    }

    # <pre> preserves the whitespace alignment of the text report  -  a cheap
    # trick that keeps one report format instead of maintaining two layouts.
    $htmlBody = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Health Report - $ComputerName</title>
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #222; }
  h1   { font-size: 20px; }
  .verdict { display: inline-block; padding: 4px 12px; border-radius: 4px;
             color: #fff; background: $verdictColor; font-weight: bold; }
  .issues  { background: #fdecea; border-left: 4px solid #c0392b;
             padding: 8px 16px; margin: 16px 0; }
  pre  { background: #f4f4f4; padding: 16px; border-radius: 6px; font-size: 13px; }
</style>
</head>
<body>
  <h1>System Health Report &mdash; $ComputerName</h1>
  <p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;
     <span class="verdict">$verdict</span></p>
  $issuesHtml
  <pre>$($Sections -join [Environment]::NewLine)</pre>
</body>
</html>
"@
    $htmlBody | Out-File -FilePath $ReportHtml -Encoding UTF8
    Write-Host "HTML report saved: $ReportHtml" -ForegroundColor Cyan
}

# ============================================================================
# OPTIONAL EMAIL
# ============================================================================
if ($SendEmail) {
    # Subject line carries the verdict so an admin can triage from the inbox
    # list without opening anything: "[HEALTHY] DC01" vs "[ISSUES FOUND (2)] DC01".
    $subject = "[$verdict] Health report - $ComputerName - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

    $mailParams = @{
        SmtpServer  = $EmailSettings.SmtpServer
        Port        = $EmailSettings.Port
        From        = $EmailSettings.From
        To          = $EmailSettings.To
        Subject     = $subject
        Body        = $reportText
        ErrorAction = "Stop"
    }
    if ($EmailSettings.UseSsl) { $mailParams.UseSsl = $true }

    # If we built an HTML report, attach it  -  the plain-text body still works
    # for any mail client, and the attachment is the pretty version.
    if ($ReportHtml) { $mailParams.Attachments = $ReportHtml }

    try {
        Send-MailMessage @mailParams
        Write-Host "Email sent to $($EmailSettings.To) via $($EmailSettings.SmtpServer)" -ForegroundColor Green
    }
    catch {
        # Email failure must NOT make the health check itself "fail"  -  the
        # report is already on disk. Log the problem and move on.
        Write-Host "Email failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Check the SMTP settings in the CONFIGURATION block, or test connectivity with: Test-NetConnection $($EmailSettings.SmtpServer) -Port $($EmailSettings.Port)" -ForegroundColor Yellow
    }
}

# ============================================================================
# EXIT CODE
# ============================================================================
# Exit 0 = healthy, 1 = issues found. Task Scheduler records this as the
# "Last Run Result", and monitoring tools can key off it  -  a tiny detail that
# makes the script play nicely with the rest of the ops toolchain.
if ($Issues.Count -gt 0) { exit 1 } else { exit 0 }
