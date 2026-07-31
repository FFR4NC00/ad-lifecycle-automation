# Home Lab Troubleshooting Notes

These are my notes on four real problems I hit while building this lab. I wrote them up postmortem style because that's how real IT and ops teams document incidents, and I wanted practice doing it the right way. The format is loosely based on Google's SRE postmortem template from their engineering book. I scaled it down since this is just my own home lab and not a company outage, but I kept the same bones. What happened, what it affected, why it happened, how I found it, how I fixed it, and what I'd do differently next time.

---

## Issue 1 Client VM install got blocked by a TPM requirement

**Date**
2026-07-24

**Status**
Resolved

**Summary**
Windows 11 Setup wouldn't let me continue inside a new Hyper V Gen 2 VM. It said the system didn't meet Windows 11's requirements.

**Impact**
Just blocked the client VM build for a few minutes before the OS install even started. Nothing broke, I just couldn't move forward yet.

**Root Cause**
Hyper V Gen 2 VMs can have a virtual TPM, but it's off by default. Windows 11 Setup checks for TPM 2.0 as part of its hardware check, and a VM without vTPM enabled fails that check exactly like real hardware without a TPM chip would.

**Trigger**
I created a new Gen 2 VM with default settings and went straight into installing the OS without checking the security settings first.

**Detection**
Windows Setup told me directly. The screen said this PC doesn't currently meet Windows 11 system requirements, the PC must support TPM 2.0. Caught immediately, before any install progress happened.

**Resolution**
Shut the VM down. Went to Hyper V Manager, VM Settings, Security, and turned on "Enable Trusted Platform Module." Secure Boot was already on with the Microsoft Windows template, which vTPM needs anyway. Restarted setup and it passed the check with no other changes.

**Action Items**

| What | Type | Status |
|---|---|---|
| Add "enable TPM in VM settings" to my normal VM build checklist before first boot | prevent | Done |
| Remember that only Gen 2 VMs support vTPM at all | note to self | Done |

**Lessons Learned**

What went well. The error caught me early, before I wasted any time on an actual install.

What went wrong. I already knew Windows 11 needs TPM 2.0 and still didn't check the VM's security settings before booting it.

Where I got lucky. The error message named the exact missing requirement instead of giving me a vague failure to chase down.

---

## Issue 2 My original client device couldn't join a domain at all

**Date**
2026-07-24

**Status**
Resolved, but the plan changed

**Summary**
I originally planned to join my laptop, running Windows 11 Home, to the lab domain as a second physical device. Turns out the domain join option doesn't exist anywhere in that edition.

**Impact**
Had to redesign part of my plan mid build. Didn't waste much time since I caught it before doing any real work on the laptop.

**Root Cause**
Microsoft locks traditional Active Directory domain join behind Pro, Enterprise, and Education editions. It's a licensing thing, not a setting I could flip. No registry trick changes that in any supported way.

**Trigger**
I got to the domain join step and went looking for "Domain or workgroup" under System Properties. It just wasn't there.

**Detection**
Just looking at the settings myself while following my plan. I caught it before trying anything, since the option was missing, not failing.

**Resolution**
Instead of paying for an edition upgrade, I built a second Hyper V VM called Client01 using Microsoft's free 90 day Windows 11 Enterprise evaluation ISO. That edition supports domain join out of the box. Same learning outcome, DNS setup, domain join, logging in as a domain user, just no laptop and no cost.

**Action Items**

| What | Type | Status |
|---|---|---|
| Check OS edition and licensing limits for every device before locking in a lab plan | prevent | Done, will do this upfront next time |
| Keep a running list of which Windows features are edition locked, domain join, Hyper V, Group Policy Editor, BitLocker | note to self | Done |

**Lessons Learned**

What went well. The free Enterprise eval fully covered what I actually wanted to learn. No real loss.

What went wrong. I planned the whole topology before checking whether every device could actually support it.

Where I got lucky. Microsoft's free eval program meant I didn't have to make an actual purchase decision in the middle of the project.

---

## Issue 3 Domain join failed even though DNS looked fine

**Date**
2026-07-24

**Status**
Resolved

**Summary**
Client01 wouldn't join corp.local. Windows said it couldn't contact a domain controller, even though I could ping the DC and nslookup worked when I pointed it at the DC directly.

**Impact**
Blocked the domain join for one troubleshooting round. No data lost, just delayed getting to the verification step.

**Root Cause**
Running ipconfig /all on Client01 showed two DNS servers. One was the DC's IP, set manually and correct. The other was an IPv6 DNS server the ISP router handed out automatically. Windows generally prefers IPv6 for name resolution when both exist, so the automatic domain lookup process was asking the ISP's public IPv6 DNS server first, which obviously has no idea what corp.local is, instead of asking my DC.

**Trigger**
IPv6 being on by default on the client's network adapter, combined with my home router handing out IPv6 DNS servers automatically.

**Detection**
I worked through it step by step. ipconfig /all showed the dual DNS setup. Ping confirmed I could reach the DC fine. nslookup only worked because I manually told it which server to ask, which skips the normal resolution order. That gap between my manual test working and the automatic process failing was the big clue.

**Resolution**
Turned off IPv6 completely on both DC01 and Client01's network adapters. That removed the ambiguity and left one clear path for DNS. Tried the domain join again and it worked right away.

**Action Items**

| What | Type | Status |
|---|---|---|
| Turn off IPv6 on lab VM adapters as a default step for any future single domain lab on a home network | prevent | Done, added to my setup guide |
| If a manual DNS test works but an automatic process still fails, check for multiple DNS servers and resolution order next time before anything else | note to self | Done |

**Lessons Learned**

What went well. Going step by step with ipconfig, then ping, then nslookup narrowed things down fast instead of me just guessing.

What went wrong. I didn't think about my home network being dual stack and how that could sneak a second DNS server into a lab built around one manually set DNS server.

Where I got lucky. The router's IPv6 behavior was consistent, so once I had a theory it was easy to confirm and fix.

---

## Issue 4 Script errors showed up at the exact same spot no matter how I moved the file

**Date**
2026-07-24

**Status**
Resolved

**Summary**
New Employee.ps1 kept throwing a PowerShell parser error near the end of the file, something like unexpected token and missing closing brace. It happened at the exact same line both times I moved the file over, once through copy paste in Notepad, and once with a direct file copy through Hyper V Enhanced Session.

**Impact**
Blocked me from testing the script twice, once per transfer attempt. Cost me somewhere around 15 to 20 minutes before I figured out what was actually going on.

**Root Cause**
The scripts used em dashes in a bunch of comments. Windows PowerShell 5.1 reads .ps1 files without a UTF 8 byte order mark using the system's default codepage instead of UTF 8. That multi byte em dash character was getting misread under that assumption, which corrupted how the parser understood the rest of the file near the end.

**Trigger**
The scripts were written with em dashes and saved as UTF 8 without a BOM, which is a common default in a lot of text editors but not what PowerShell 5.1 assumes.

**Detection**
The big clue was that the exact same error showed up at the exact same line through two totally different transfer methods that don't share any obvious failure mode, clipboard paste versus raw file copy. That ruled out the transfer itself being the problem and pointed at something both methods kept unchanged, the actual bytes and encoding of the file.

**Resolution**
I scanned all three scripts for anything outside plain ASCII, found the em dash was the only culprit, swapped every one of them for a regular hyphen, then double checked the files were pure ASCII and had the same line counts as the originals so I knew nothing else got lost. Moved them back over and ran them clean.

**Action Items**

| What | Type | Status |
|---|---|---|
| Avoid em dashes and curly quotes in PowerShell scripts meant for PowerShell 5.1, or save with a UTF 8 BOM on purpose | prevent | Done, applied to all three scripts |
| If the same error shows up through multiple unrelated transfer or reproduction paths, look at what they have in common instead of what's different | note to self | Done |

**Lessons Learned**

What went well. A quick script checking for non ASCII characters confirmed my theory in under a minute instead of me eyeballing 472 lines of code by hand.

What went wrong. The original scripts had stylistic em dashes that looked completely normal on screen and gave zero warning they'd cause a parsing issue.

Where I got lucky. This turned out to be a known PowerShell 5.1 quirk with a clear explanation once I knew what to search for, not some brand new mystery bug.

---

## Why I bothered writing these up

The point of doing this postmortem style isn't to prove something broke, it's to make the next version of this problem less likely and leave myself notes I can actually use later instead of having to re debug the same thing from scratch. Every issue above ended with something concrete I changed, either in how I build VMs, how I write scripts, or how I troubleshoot in general.
