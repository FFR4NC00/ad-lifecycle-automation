# Project Addendum: Layered Network Troubleshooting Toolkit

*(Extends the existing portfolio: AD lifecycle automation, system health
monitoring, and backup/disaster recovery. This piece adds CompTIA A+ Core 1
networking and Core 2 troubleshooting-methodology competency.)*

## The problem it solves

"The internet is down" is the single most common helpdesk ticket, and it is
almost never accurate. The real situation is that *one layer* of a chain is
down — the adapter, DHCP, the local router, the DNS server, name resolution,
the internet uplink, the destination host, or just one service port on it —
and every one of those looks identical from the user's chair: pages don't
load.

The first ten minutes of competent triage is always the same sequence of
manual checks: `ipconfig`, ping the gateway, ping DNS, `nslookup` something,
ping 8.8.8.8, ping the destination, test the port, tracert. Test-NetworkHealth.ps1
automates exactly that sequence, in exactly that order, and — the part manual
checking often skips under pressure — draws the correct conclusion: **the
first failing layer is the root cause; later failures are consequences.** One
command produces the full picture, a plain-language "most likely issue is at
layer N, look here next" verdict, and a timestamped log ready to attach to an
escalation ticket.

The ordering is the methodology. Working outward from the machine (local
config → gateway → DNS → internet → destination → service → path) is the A+
troubleshooting model made executable: identify the problem, establish a
theory of probable cause, test the theory — and know precisely what to
escalate, to whom, with evidence, when it's not yours to fix.

## How it completes the toolkit

The portfolio now covers a junior sysadmin's actual week: accounts are
provisioned and removed correctly (**lifecycle scripts**), the server's health
is watched daily (**health check**), mistakes and disasters are recoverable
(**Recycle Bin restore, System State backup, DR runbook**), and when a user
says "nothing works," triage takes one command instead of ten minutes
(**network toolkit**). Every script shares the same conventions — timestamped
logging with severity levels, meaningful exit codes, config separated from
logic, heavy self-documentation — so the set reads as one engineered codebase,
not five disconnected scripts.

A concrete cross-link worth demonstrating: `Test-NetworkHealth.ps1 -Target
DC01.corp.local -Ports 53,88,389,445` turns the generic tool into an "is the
domain controller serving AD" probe (DNS, Kerberos, LDAP, SMB) — the exact
check you'd run from a client when domain logons misbehave.

## Resume bullet points

- Built a layered network diagnostics tool (PowerShell) that automates
  first-line connectivity triage — local IP/DHCP state, gateway, DNS server
  vs. DNS resolution, internet egress, destination, per-port TCP, and route
  path — and identifies the first failing layer as probable root cause with
  plain-language next-step guidance
- Encoded structured troubleshooting methodology (CompTIA A+ model) into
  automation: checks ordered by network distance, dependent-failure logic to
  separate root causes from consequences, and edge-case handling (APIPA
  detection, ICMP-filtering hosts, cache-bypassed DNS queries)
- Produced escalation-ready evidence automatically: timestamped severity-coded
  logs and a PASS/FAIL summary per layer, with exit codes enabling the tool to
  be chained into monitoring and alerting workflows
- Applied the toolkit to Active Directory service verification (DNS/Kerberos/
  LDAP/SMB port probing against the domain controller), bridging network
  diagnostics with the directory-services administration demonstrated
  elsewhere in the portfolio

*(Interview tip: the strongest demo of this project is the failure cases, not
the passing one. Break DNS on Client01 on purpose, run the script, and show
that it fingers layers 3–4 while proving layer 5 still works — then say "and
this is why 'the internet is down' tickets are usually DNS." That's the whole
competency in thirty seconds.)*
