# Test-NetworkHealth.ps1

## What it checks, and in what order

Eight layers, each one step further from the machine than the last:

| # | Layer | Question it answers |
|---|-------|---------------------|
| 1 | Local IP configuration | Is my adapter up, with a real (non-APIPA) address, gateway, and DNS servers? DHCP or static? |
| 2 | Default gateway | Can I reach my own router — the door out of this network? |
| 3 | DNS server reachability | Can I reach the DNS server *as a host* (ping, falling back to TCP 53 for servers that filter ping)? |
| 4 | DNS resolution | Does name→IP lookup actually work (queried live with `-DnsOnly`, bypassing the cache)? |
| 5 | Internet reachability | Can I reach a known external IP (8.8.8.8) *without DNS involved at all*? |
| 6 | Destination ping | Does the specific target respond to ping? |
| 7 | Port connectivity | Do the target's actual service ports accept a TCP connection? |
| 8 | Route path | Where along the path do packets stop, if anywhere (traceroute)? |

## Why the order matters (the escalation logic)

Each layer *depends on* the ones before it: no local IP → nothing else can
possibly work; no gateway → nothing beyond the LAN can work; and so on. So
when several layers fail, **the first failure is the root cause and the rest
are consequences** — the script's final verdict points there, because that's
where a tech starts working.

The script deliberately **keeps running after a failure** rather than stopping
early. Two reasons: the full pattern is itself evidence (gateway ping fails
but internet works = the router filters ICMP, not an outage — the script
detects the same pattern for ping-filtering targets at layers 6/7), and a
complete report is what you attach to an escalation ticket.

Separating layers that beginners lump together is most of the diagnostic
value:

- **3 vs 4** — DNS server *unreachable* is a network problem; server reachable
  but *not resolving* is a service problem. Different fix, different escalation.
- **4 vs 5** — resolution fails but 8.8.8.8 pings = "the internet is fine, DNS
  is broken." To the user those are identical ("no websites work"); to the
  fix they're opposites.
- **6 vs 7** — ping proves a host exists; a TCP connect proves the *service*
  is reachable. "Ping works, port 443 doesn't" sends the ticket to the app
  owner, not the network team.

The script is **read-only** — pings, DNS queries, TCP probes; it changes
nothing. That's why it has no `-WhatIf`: `SupportsShouldProcess` guards state
changes, and this script has none to guard.

## How to run

```powershell
# Default: google.com, ports 80 and 443 (exercises every layer incl. DNS)
.\Test-NetworkHealth.ps1

# Test connectivity to the domain controller, including core AD ports
# (53 DNS, 88 Kerberos, 389 LDAP, 445 SMB):
.\Test-NetworkHealth.ps1 -Target DC01.corp.local -Ports 53,88,389,445

# Deliberately test an unreachable address to see a failure report.
# 192.0.2.1 is in TEST-NET-1, a range reserved for documentation that never
# routes on the real internet — a guaranteed-safe "down" target:
.\Test-NetworkHealth.ps1 -Target 192.0.2.1

# A host that exists but where a port is closed (fails layer 7 only):
.\Test-NetworkHealth.ps1 -Target google.com -Ports 80,443,8080
```

Exit code is `0` if every layer passed, `1` if anything failed — so it can be
chained ("run the net check; if it fails, alert").

## Example output — clean pass

```
=================================================================
 NETWORK HEALTH SUMMARY — CLIENT01 -> google.com
 2026-07-31 09:14:22
=================================================================
 [1] Local IP config       PASS  Adapter 'Ethernet': 10.0.0.25/24 (Enabled), gateway 10.0.0.1, DNS: 10.0.0.10
 [2] Gateway ping          PASS  Gateway 10.0.0.1 responded.
 [3] DNS server reachable  PASS  Reachable: 10.0.0.10
 [4] DNS resolution        PASS  'google.com' -> 142.250.72.14
 [5] Internet (8.8.8.8)    PASS  External IP 8.8.8.8 responded — raw internet connectivity works.
 [6] Destination ping      PASS  google.com responded to ping.
 [7] Port connectivity     PASS  80=OPEN, 443=OPEN
 [8] Route path            PASS  11 hop(s); path completed, last hop 142.250.72.14.
-----------------------------------------------------------------
 ALL LAYERS PASSED — connectivity from CLIENT01 to google.com (ports 80,443) is healthy.
```

## Example output — failure case (unreachable target 192.0.2.1)

```
=================================================================
 NETWORK HEALTH SUMMARY — CLIENT01 -> 192.0.2.1
 2026-07-31 09:20:41
=================================================================
 [1] Local IP config       PASS  Adapter 'Ethernet': 10.0.0.25/24 (Enabled), gateway 10.0.0.1, DNS: 10.0.0.10
 [2] Gateway ping          PASS  Gateway 10.0.0.1 responded.
 [3] DNS server reachable  PASS  Reachable: 10.0.0.10
 [4] DNS resolution        PASS  'www.microsoft.com' -> 23.192.147.86
 [5] Internet (8.8.8.8)    PASS  External IP 8.8.8.8 responded — raw internet connectivity works.
 [6] Destination ping      FAIL  192.0.2.1 did not respond to ping (host down, name unresolvable, OR it filters ICMP — see Layer 7).
 [7] Port connectivity     FAIL  80=CLOSED/FILTERED, 443=CLOSED/FILTERED
 [8] Route path            FAIL  30 hop(s); path DID NOT complete — packets stop before the target (see hop list in log).
-----------------------------------------------------------------
 Most likely issue is at LAYER 6 (Destination ping).
 Next step: Destination host: general connectivity works but this specific target doesn't respond to ping. Either it's down, or it filters ICMP — check layer 7: if ports connected anyway, the host is UP and just ignores ping.
```

Reading it the way a tech would: layers 1–5 pass, so *our* side and the
internet are fine — the problem is specific to that destination. That's an
"escalate/report to whoever owns the target" verdict, reached in one command,
with the evidence attached.

Another instructive run: break DNS on purpose (point the client at a bogus
DNS server), and the report shows 1–2 PASS, 3–4 FAIL, **5 PASS** — the exact
"internet is fine, DNS is broken" pattern that presents to users as "the
whole internet is down."

## Notes & limitations

- **Layer 6 false alarms are handled:** hosts that filter ping show FAIL at
  layer 6 but OPEN ports at layer 7 — the script detects this pattern and the
  final verdict says "treat as healthy" instead of blaming the target.
- **Perimeter ICMP blocking** can make layer 5 fail even when internet access
  works over TCP. If layer 5 fails but layer 7 connects to an external
  target, suspect ICMP filtering at the firewall.
- **Traceroute is slow against dead targets** — it waits out per-hop timeouts
  and can take a couple of minutes. Normal; wait for it.
- **IPv4 only** by design, matching the lab. Dual-stack adds `-AddressFamily
  IPv6` variants of each check.
- Unanswered traceroute hops display as `* (no response)`; scattered silent
  hops mid-path are routers deprioritizing ICMP and are normal — silence from
  some point *all the way to the end* is the signature of a real break.
