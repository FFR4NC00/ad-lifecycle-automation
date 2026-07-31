<#
.SYNOPSIS
    Walks through network connectivity layer by layer  -  local config, gateway,
    DNS, internet, destination, ports, route  -  the same way a helpdesk tech
    troubleshoots "the internet is down", and points at the FIRST failing
    layer as the most likely root cause.

.DESCRIPTION
    THE CORE IDEA: "the network is down" is almost never one problem  -  it's a
    chain, and the useful question is WHICH LINK broke. Each check below sits
    one step further from this machine than the last:

        [1] my own adapter/IP  ->  [2] my router  ->  [3] my DNS server
        ->  [4] name resolution  ->  [5] the internet at large
        ->  [6] the specific destination  ->  [7] the specific service/port
        ->  [8] the path in between

    Ordering by distance is what makes the result DIAGNOSTIC instead of just
    descriptive: if layer 2 fails, layers 5-8 failing tells you nothing new  - 
    of course they fail, everything past the router is unreachable. The first
    failure in the chain is where a tech starts working (or decides what to
    escalate, and to whom). That's the CompTIA troubleshooting methodology in
    executable form: identify, theorize, TEST  -  and the test order encodes the
    theory.

    We deliberately DO run every later check even after an early failure
    (rather than stopping at the first FAIL), for two reasons:
      1. Evidence: "gateway unreachable AND everything past it dead" vs.
         "gateway unreachable but internet fine" are different problems (the
         second suggests ICMP is blocked on the router, not an outage).
      2. A complete report is what you'd attach to an escalation ticket.

    Read-only: this script only LOOKS at the network (pings, DNS queries, TCP
    probes). It changes nothing, so there is no -WhatIf  -  SupportsShouldProcess
    exists to guard state changes, and a dry-run mode for a script with no
    state changes would be a no-op that just implies (wrongly) that something
    here is dangerous.

    PowerShell 5.1 compatible. No modules required beyond what ships with
    Windows 10/11 and Server 2016+ (NetTCPIP / DnsClient are in-box).

.PARAMETER Target
    Hostname or IP to test reachability against. Default: google.com  -  a
    hostname on purpose, so the DNS layers get exercised on a default run.

.PARAMETER Ports
    TCP ports to test on the target. Default: 80 and 443 (HTTP/HTTPS)  -  the
    ports that matter for "can I reach this website".

.EXAMPLE
    .\Test-NetworkHealth.ps1

.EXAMPLE
    # Is our own DC reachable, including AD's key ports?
    .\Test-NetworkHealth.ps1 -Target DC01.corp.local -Ports 53,88,389,445

.EXAMPLE
    # Deliberately test something unreachable, to see a failure report:
    .\Test-NetworkHealth.ps1 -Target 192.0.2.1
    # (192.0.2.0/24 is TEST-NET-1, reserved for documentation  -  it never
    #  routes on the real internet, so it's a guaranteed-safe "down" target.)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Target = "google.com",

    [Parameter(Mandatory = $false)]
    # ValidateRange on the array: PowerShell applies it to EACH element, so a
    # typo like port 80000 is rejected before the script body runs.
    [ValidateRange(1, 65535)]
    [int[]]$Ports = @(80, 443)
)

# ============================================================================
# LOGGING  -  identical pattern to the rest of the portfolio
# ============================================================================
$LogFolder = Join-Path -Path $PSScriptRoot -ChildPath "Logs"
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogFolder ("NetHealth_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

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

# ============================================================================
# RESULT TRACKING
# ============================================================================
# Every layer records ONE result object into this list. Collecting structured
# results (instead of just printing as we go) is what lets us build the
# summary table and the "first failed layer" conclusion at the end  -  the same
# collect-then-report pattern as Check-SystemHealth.ps1.
$Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [int]$Layer,
        [string]$Name,
        [ValidateSet("PASS", "FAIL")][string]$Status,
        [string]$Detail
    )
    $Results.Add([PSCustomObject]@{
        Layer  = $Layer
        Name   = $Name
        Status = $Status
        Detail = $Detail
    })
    $level = "SUCCESS"
    if ($Status -eq "FAIL") { $level = "ERROR" }
    Write-Log ("[Layer {0}] {1}: {2}  -  {3}" -f $Layer, $Name, $Status, $Detail) -Level $level
}

# Per-layer escalation guidance, used by the final summary. This mapping IS
# the troubleshooting knowledge: each entry answers "the first failure was at
# layer N  -  where does a tech look next?"
$LayerGuidance = @{
    1 = "Local machine: check cable/Wi-Fi, adapter enabled, and DHCP. An address starting 169.254.x.x means DHCP FAILED and Windows self-assigned (APIPA)  -  fix DHCP/cabling first, nothing else can work."
    2 = "Local network: this machine can't reach its own router. Check physical connectivity, the switch/AP, VLAN membership, or the router itself. Everything beyond the gateway depends on this."
    3 = "DNS server unreachable: the path to the configured DNS server is broken, or that server is down. On a domain machine this should be the DC (DC01)  -  check the DC and the route to it."
    4 = "Name resolution: the DNS server is reachable but not answering/resolving. Check the DNS Server service on DC01, its forwarders, and this client's configured DNS servers (a common misconfig: a client pointed at a public DNS that can't resolve internal corp.local names, or vice versa)."
    5 = "Internet egress: LAN and DNS are fine but nothing external responds  -  likely ISP outage, modem, or a perimeter firewall change. This is where 'it's not us, open a ticket with the provider' becomes a defensible statement."
    6 = "Destination host: general connectivity works but this specific target doesn't respond to ping. Either it's down, or it filters ICMP  -  check layer 7: if ports connected anyway, the host is UP and just ignores ping."
    7 = "Service/port: the host answers ping but the service port doesn't connect  -  the service is stopped, listening elsewhere, or a firewall blocks that port. This is a service problem, not a network problem: escalate to whoever owns the application."
    8 = "Path: the trace shows where packets stop. Consecutive * hops at the end = the failure point (or ICMP-silent routers); hand the trace to the network team/ISP  -  it's exactly the evidence they need."
}

Write-Log "===== Test-NetworkHealth.ps1 started ====="
Write-Log "Target: $Target   Ports: $($Ports -join ', ')   Computer: $env:COMPUTERNAME"

# ============================================================================
# LAYER 1: LOCAL IP CONFIGURATION
# ============================================================================
# Start at the machine itself  -  "is MY end plugged in and configured"  -  before
# blaming anything out there. (Physical layer first: it's the A+ methodology
# and also just the embarrassment-minimizing order; nobody wants to escalate
# an ISP outage that turns out to be their own disabled adapter.)
Write-Host ""
Write-Host "--- Layer 1: Local IP configuration -------------------------" -ForegroundColor Cyan

# Get-NetAdapter lists physical + virtual adapters. We want ones that are Up
# and not the loopback-ish virtuals. Hyper-V lab note: a "vEthernet" adapter
# IS the real adapter on a VM, so we filter by Status, not by name.
$upAdapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" })

# These get filled by layer 1 and consumed by layers 2 and 3  -  the script
# tests the gateway and DNS server the machine is ACTUALLY configured with,
# not assumptions.
$gateway    = $null
$dnsServers = @()

if ($upAdapters.Count -eq 0) {
    Add-Result -Layer 1 -Name "Local IP config" -Status FAIL -Detail "No network adapter is Up. (Cable unplugged / Wi-Fi off / adapter disabled.)"
}
else {
    # Get-NetIPConfiguration bundles per-adapter IP + gateway + DNS in one
    # call. We take the first Up adapter that has both an IPv4 address and a
    # gateway  -  i.e., the adapter that actually carries this machine's
    # traffic (a machine can easily have extra adapters with neither).
    $ipconfig = Get-NetIPConfiguration |
        Where-Object { $_.NetAdapter.Status -eq "Up" -and $_.IPv4Address -and $_.IPv4DefaultGateway } |
        Select-Object -First 1

    if ($null -eq $ipconfig) {
        # Adapter is up but has no usable IPv4+gateway combo. Check for the
        # APIPA signature: 169.254.x.x is what Windows self-assigns when DHCP
        # gets no answer. It LOOKS like an address; it routes nowhere. Being
        # able to read "169.254" as "DHCP failed" is core helpdesk literacy.
        $anyIPv4 = ($upAdapters | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -ne "127.0.0.1" } | Select-Object -First 1)
        if ($anyIPv4 -and $anyIPv4.IPAddress -like "169.254.*") {
            Add-Result -Layer 1 -Name "Local IP config" -Status FAIL -Detail "APIPA address $($anyIPv4.IPAddress)  -  DHCP failed; Windows self-assigned. No routing possible."
        }
        else {
            Add-Result -Layer 1 -Name "Local IP config" -Status FAIL -Detail "Adapter is Up but has no IPv4 address + default gateway combination."
        }
    }
    else {
        $ip      = $ipconfig.IPv4Address.IPAddress
        $prefix  = $ipconfig.IPv4Address.PrefixLength      # e.g. 24 = 255.255.255.0
        $gateway = $ipconfig.IPv4DefaultGateway.NextHop

        # DHCP or static? That's an interface property, not an address one:
        $dhcpState = (Get-NetIPInterface -InterfaceIndex $ipconfig.InterfaceIndex -AddressFamily IPv4).Dhcp

        # DNS servers configured on this adapter (IPv4 only  -  AddressFamily 2).
        $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $ipconfig.InterfaceIndex -AddressFamily IPv4).ServerAddresses)

        $detail = "Adapter '$($ipconfig.InterfaceAlias)': $ip/$prefix ($dhcpState), gateway $gateway, DNS: $($dnsServers -join ', ')"
        if ($dnsServers.Count -eq 0) {
            # Unusual but possible: valid IP, no DNS. Everything name-based
            # will fail even though "the network" is fine  -  worth failing
            # layer 1 loudly since it's a local config problem.
            Add-Result -Layer 1 -Name "Local IP config" -Status FAIL -Detail "$detail  -  NO DNS SERVERS CONFIGURED."
        }
        else {
            Add-Result -Layer 1 -Name "Local IP config" -Status PASS -Detail $detail
        }
    }
}

# ============================================================================
# LAYER 2: DEFAULT GATEWAY REACHABILITY
# ============================================================================
# The gateway (your router) is the door out of the local network. If we can't
# ping the door, nothing beyond it is meaningfully testable  -  this single
# check splits the universe into "problem is in this room" vs "problem is out
# there", which is the most valuable fork in all of network troubleshooting.
Write-Host ""
Write-Host "--- Layer 2: Default gateway reachability --------------------" -ForegroundColor Cyan

if (-not $gateway) {
    Add-Result -Layer 2 -Name "Gateway ping" -Status FAIL -Detail "No default gateway is configured (see Layer 1)  -  nothing to ping."
}
else {
    # Test-Connection = PowerShell's ping. -Count 2: one lost packet happens;
    # two lost packets is a signal. -Quiet: just give me $true/$false  - 
    # perfect for pass/fail logic (we don't need latency stats here).
    $gwOk = Test-Connection -ComputerName $gateway -Count 2 -Quiet -ErrorAction SilentlyContinue
    if ($gwOk) {
        Add-Result -Layer 2 -Name "Gateway ping" -Status PASS -Detail "Gateway $gateway responded."
    }
    else {
        Add-Result -Layer 2 -Name "Gateway ping" -Status FAIL -Detail "Gateway $gateway did NOT respond to ping."
    }
}

# ============================================================================
# LAYER 3: DNS SERVER REACHABILITY (as a HOST  -  not resolution yet)
# ============================================================================
# Why test this separately from "does DNS resolution work" (layer 4)?
# Because they fail differently and the fix differs:
#   - Server unreachable  -> a NETWORK problem (path/host down) -> network fix
#   - Server reachable but resolution fails -> a SERVICE problem (DNS service
#     stopped, bad forwarders, wrong server configured) -> DNS fix
# Collapsing them into one check would tell you "DNS is broken" without
# telling you WHICH KIND of broken  -  and the whole point of this script is
# knowing which kind.
#
# One honest wrinkle: some DNS servers ignore ping (ICMP filtered) while
# happily serving DNS. So if ping fails, we ALSO probe TCP port 53 before
# declaring the server unreachable  -  a host answering on the DNS port is
# reachable in the way that matters, whatever it thinks of ping.
Write-Host ""
Write-Host "--- Layer 3: DNS server reachability -------------------------" -ForegroundColor Cyan

if ($dnsServers.Count -eq 0) {
    Add-Result -Layer 3 -Name "DNS server reachable" -Status FAIL -Detail "No DNS servers configured (see Layer 1)."
}
else {
    # Test each configured server; the layer passes if ANY responds  -  one
    # working resolver is enough for the machine to function.
    $reachable   = @()
    $unreachable = @()
    foreach ($dns in $dnsServers) {
        $ok = Test-Connection -ComputerName $dns -Count 2 -Quiet -ErrorAction SilentlyContinue
        if (-not $ok) {
            # Ping failed  -  try the port that actually matters before judging.
            $tnc = Test-NetConnection -ComputerName $dns -Port 53 -WarningAction SilentlyContinue
            $ok = $tnc.TcpTestSucceeded
            if ($ok) { Write-Log "DNS server $dns ignores ping but answers on TCP 53  -  reachable (ICMP filtered)." -Level WARN }
        }
        if ($ok) { $reachable += $dns } else { $unreachable += $dns }
    }

    if ($reachable.Count -gt 0) {
        $detail = "Reachable: $($reachable -join ', ')"
        if ($unreachable.Count -gt 0) { $detail += " | UNREACHABLE: $($unreachable -join ', ')" }
        Add-Result -Layer 3 -Name "DNS server reachable" -Status PASS -Detail $detail
    }
    else {
        Add-Result -Layer 3 -Name "DNS server reachable" -Status FAIL -Detail "No configured DNS server responded (ping AND TCP 53): $($unreachable -join ', ')"
    }
}

# ============================================================================
# LAYER 4: DNS RESOLUTION (does name -> IP actually work)
# ============================================================================
Write-Host ""
Write-Host "--- Layer 4: DNS resolution ----------------------------------" -ForegroundColor Cyan

# What name should we resolve? If -Target is a hostname, use it  -  that's the
# name the user actually cares about. If -Target is a raw IP (nothing to
# resolve), fall back to a well-known name so the layer still gets tested.
# [System.Net.IPAddress]::TryParse is the clean way to ask "is this an IP?"  - 
# it returns $true/$false instead of throwing on non-IP input.
$parsedIP = $null
$targetIsIP = [System.Net.IPAddress]::TryParse($Target, [ref]$parsedIP)
$nameToResolve = $Target
if ($targetIsIP) { $nameToResolve = "www.microsoft.com" }

try {
    # -Type A = IPv4 records; -DnsOnly = actually query the DNS server, don't
    # let the local cache or hosts file answer. That matters: a cached answer
    # would make DNS look healthy while the server is actually down  -  we're
    # testing the SERVER, so we bypass the shortcuts.
    $dnsAnswer = Resolve-DnsName -Name $nameToResolve -Type A -DnsOnly -ErrorAction Stop
    $resolvedIPs = @($dnsAnswer | Where-Object { $_.Type -eq "A" } | Select-Object -ExpandProperty IPAddress)
    Add-Result -Layer 4 -Name "DNS resolution" -Status PASS -Detail "'$nameToResolve' -> $($resolvedIPs -join ', ')"
}
catch {
    Add-Result -Layer 4 -Name "DNS resolution" -Status FAIL -Detail "Could not resolve '$nameToResolve': $($_.Exception.Message)"
}

# ============================================================================
# LAYER 5: INTERNET REACHABILITY (raw IP  -  deliberately NO DNS involved)
# ============================================================================
# 8.8.8.8 (Google Public DNS) is pinged BY ADDRESS, so this check works even
# when DNS is completely broken. That independence is the point  -  it gives
# you the classic diagnostic split:
#   Layer 5 PASS + Layer 4 FAIL = "the internet is fine, DNS is broken"
#     (which to a user is indistinguishable from 'the internet is down'  - 
#      every website fails  -  but the fix is entirely different)
#   Layer 5 FAIL = actual internet/egress problem.
Write-Host ""
Write-Host "--- Layer 5: Internet reachability (8.8.8.8, no DNS) ---------" -ForegroundColor Cyan

$inetOk = Test-Connection -ComputerName 8.8.8.8 -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($inetOk) {
    Add-Result -Layer 5 -Name "Internet (8.8.8.8)" -Status PASS -Detail "External IP 8.8.8.8 responded  -  raw internet connectivity works."
}
else {
    Add-Result -Layer 5 -Name "Internet (8.8.8.8)" -Status FAIL -Detail "8.8.8.8 did not respond  -  no external connectivity (or outbound ICMP is blocked at the perimeter)."
}

# ============================================================================
# LAYER 6: DESTINATION REACHABILITY (ping the actual target)
# ============================================================================
Write-Host ""
Write-Host "--- Layer 6: Destination ping ($Target) ----------------------" -ForegroundColor Cyan

$destOk = Test-Connection -ComputerName $Target -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($destOk) {
    Add-Result -Layer 6 -Name "Destination ping" -Status PASS -Detail "$Target responded to ping."
}
else {
    # Note we do NOT conclude "host is down"  -  ping failing only proves ICMP
    # didn't come back. Plenty of production hosts drop ping on purpose.
    # Layer 7 is the tiebreaker; the summary logic below knows this.
    Add-Result -Layer 6 -Name "Destination ping" -Status FAIL -Detail "$Target did not respond to ping (host down, name unresolvable, OR it filters ICMP  -  see Layer 7)."
}

# ============================================================================
# LAYER 7: PORT CONNECTIVITY (the check that answers the user's real question)
# ============================================================================
# Ping proves a host exists; a TCP connect proves the SERVICE is reachable.
# Users never actually want to ping a server  -  they want the website, the
# share, the mail. "Ping works but port 443 doesn't" = the service or a
# firewall, not the network. This layer is where 'network problem' and
# 'application problem' get separated  -  which decides who the ticket goes to.
Write-Host ""
Write-Host "--- Layer 7: TCP port connectivity ---------------------------" -ForegroundColor Cyan

$portResults = @()
$anyPortOpen = $false
$allPortsOpen = $true
foreach ($port in $Ports) {
    # Test-NetConnection attempts a real TCP three-way handshake to the port.
    # TcpTestSucceeded is the verdict. -WarningAction SilentlyContinue keeps
    # its noisy "ping failed" warnings out of our clean output (we already
    # tested ping ourselves, deliberately, as its own layer).
    $tnc = Test-NetConnection -ComputerName $Target -Port $port -WarningAction SilentlyContinue
    if ($tnc.TcpTestSucceeded) {
        $portResults += "${port}=OPEN"
        $anyPortOpen = $true
    }
    else {
        $portResults += "${port}=CLOSED/FILTERED"
        $allPortsOpen = $false
    }
}

if ($allPortsOpen) {
    Add-Result -Layer 7 -Name "Port connectivity" -Status PASS -Detail ($portResults -join ", ")
}
else {
    Add-Result -Layer 7 -Name "Port connectivity" -Status FAIL -Detail ($portResults -join ", ")
}

# The ICMP-filtered special case, made explicit: ping failed but a port
# connected -> the host is definitely UP. Log it so the report teaches the
# reader instead of leaving a confusing PASS-under-a-FAIL.
if (-not $destOk -and $anyPortOpen) {
    Write-Log "Layer 6 failed but Layer 7 connected: $Target is UP and simply filters ping. Treat the Layer 6 FAIL as 'ICMP blocked', not 'host down'." -Level WARN
}

# ============================================================================
# LAYER 8: ROUTE PATH (traceroute)
# ============================================================================
# Traceroute maps every router between here and there. Its diagnostic value:
# when something upstream is broken, the hops that answer show how FAR
# packets get, and the point where answers stop is (roughly) where the
# problem lives. That's evidence you HAND OFF  -  hop 1-2 failures are yours,
# mid-path failures are the ISP's, and the trace printout is the ticket
# attachment that proves it.
Write-Host ""
Write-Host "--- Layer 8: Route path (traceroute)  -  may take a minute -----" -ForegroundColor Cyan

try {
    # -TraceRoute makes Test-NetConnection do a tracert-style hop discovery.
    # Fair warning (in the log too): against an unreachable target this waits
    # out timeouts per hop and can take a couple of minutes  -  patience is
    # part of the tool.
    $trace = Test-NetConnection -ComputerName $Target -TraceRoute -WarningAction SilentlyContinue -ErrorAction Stop

    if ($trace.TraceRoute -and $trace.TraceRoute.Count -gt 0) {
        $hopNum = 0
        foreach ($hop in $trace.TraceRoute) {
            $hopNum++
            # "0.0.0.0" is how a hop that didn't answer shows up here  -  the
            # equivalent of tracert's "* * *". A few silent hops mid-path are
            # normal (routers deprioritize ICMP); silence from some point ALL
            # THE WAY to the end is the signature of a real break.
            $hopDisplay = $hop
            if ($hop -eq "0.0.0.0") { $hopDisplay = "* (no response)" }
            Write-Log ("  Hop {0,2}: {1}" -f $hopNum, $hopDisplay)
        }
        $lastHop = $trace.TraceRoute[-1]
        if ($lastHop -ne "0.0.0.0") {
            Add-Result -Layer 8 -Name "Route path" -Status PASS -Detail "$hopNum hop(s); path completed, last hop $lastHop."
        }
        else {
            Add-Result -Layer 8 -Name "Route path" -Status FAIL -Detail "$hopNum hop(s); path DID NOT complete  -  packets stop before the target (see hop list in log)."
        }
    }
    else {
        Add-Result -Layer 8 -Name "Route path" -Status FAIL -Detail "No route information returned."
    }
}
catch {
    Add-Result -Layer 8 -Name "Route path" -Status FAIL -Detail "Traceroute failed: $($_.Exception.Message)"
}

# ============================================================================
# SUMMARY REPORT
# ============================================================================
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " NETWORK HEALTH SUMMARY  -  $env:COMPUTERNAME -> $Target"           -ForegroundColor Cyan
Write-Host " $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"                       -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

foreach ($r in $Results) {
    # -f formatting keeps columns aligned: layer, padded name, status, detail.
    $line = " [{0}] {1,-22} {2,-5} {3}" -f $r.Layer, $r.Name, $r.Status, $r.Detail
    if ($r.Status -eq "PASS") { Write-Host $line -ForegroundColor Green }
    else                      { Write-Host $line -ForegroundColor Red }
    # The summary also goes to the log file (Write-Log already logged each
    # layer as it ran; this repeats them contiguously so the log ends with a
    # readable block, same as the console).
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

Write-Host "-----------------------------------------------------------------"

# THE CONCLUSION: first failed layer = most likely root cause. Failures at
# later layers are usually CONSEQUENCES of the first one (no gateway = no
# internet = no destination...), so the earliest failure is where a tech
# starts. This mirrors real escalation: fix (or rule out) the closest problem
# first, then re-run and see how much further the chain gets.
$firstFail = $Results | Where-Object { $_.Status -eq "FAIL" } | Sort-Object Layer | Select-Object -First 1

if ($null -eq $firstFail) {
    $conclusion = "ALL LAYERS PASSED  -  connectivity from $env:COMPUTERNAME to $Target (ports $($Ports -join ',')) is healthy."
    Write-Host " $conclusion" -ForegroundColor Green
    Write-Log $conclusion -Level SUCCESS
    Write-Log "Log file: $LogFile"
    exit 0
}
else {
    # Special-case the one known false-alarm: layer 6 "failed" but a port
    # connected  -  the true first problem isn't the ping-filtering host.
    if ($firstFail.Layer -eq 6 -and $anyPortOpen) {
        $conclusion = "Most likely issue: NONE serious  -  $Target filters ping (Layer 6) but its service ports connect (Layer 7). Treat as healthy for service purposes."
        Write-Host " $conclusion" -ForegroundColor Yellow
        Write-Log $conclusion -Level WARN
    }
    else {
        $conclusion = "Most likely issue is at LAYER $($firstFail.Layer) ($($firstFail.Name))."
        Write-Host " $conclusion" -ForegroundColor Red
        Write-Host " Next step: $($LayerGuidance[$firstFail.Layer])" -ForegroundColor Yellow
        Write-Log "$conclusion Next step: $($LayerGuidance[$firstFail.Layer])" -Level ERROR
    }
    Write-Log "Log file: $LogFile"
    # Anything failed -> exit 1, so a wrapper script (or scheduled task) can
    # chain on this: "run the net check; if it fails, page someone."
    exit 1
}
