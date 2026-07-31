# Lab Setup

How the environment behind this project was built: one Hyper-V host running two VMs that form a small Active Directory domain. See `network-diagram.svg` for the topology at a glance, and `TROUBLESHOOTING.md` for the real problems hit along the way and how they were fixed.

## Environment

| Component | Details |
|---|---|
| Host | Windows 11 Pro, wired Ethernet, Hyper-V |
| DC01 | Windows Server 2022 Standard (Evaluation), static IP, Active Directory Domain Services + DNS |
| Client01 | Windows 11 Enterprise (Evaluation), DHCP, domain-joined |
| Domain | corp.local |

Hyper-V was chosen over a third-party hypervisor because it's built into Windows 11 Pro at no extra cost. Both VMs run on a single physical host connected to the home network over Ethernet, using a Hyper-V External Virtual Switch so the VMs get real IP addresses on the LAN rather than being hidden behind NAT.

## 1. Enable Hyper-V

Confirmed virtualization was enabled in BIOS (Task Manager, Performance tab, CPU, shows Virtualization Enabled), then enabled the Hyper-V Windows feature and rebooted.

## 2. Create an external virtual switch

In Hyper-V Manager, created a new External virtual switch bound to the host's Ethernet adapter, with "Allow management operating system to share this network adapter" checked. This lets VMs connect directly to the same network as the host and router, rather than sitting behind Hyper-V's default NAT.

## 3. Build DC01

Created a Generation 2 VM, 4GB static memory, 2 virtual processors, 80GB dynamic disk, connected to the external switch. Installed Windows Server 2022 Standard Evaluation with the Desktop Experience (GUI) option.

Configured networking with a static IP outside the router's DHCP range, DNS pointed at itself, and a hostname of DC01.

## 4. Promote DC01 to a domain controller

Installed the Active Directory Domain Services role, then promoted the server as a new forest with root domain `corp.local`. Configured DNS forwarders (Google and Cloudflare public DNS) so the domain controller could still resolve the public internet for Windows Update and similar traffic.

## 5. Create the OU and group structure

Created an Employees OU with Sales, IT, HR, and Finance sub-OUs, a Disabled Users OU for offboarded accounts, and the security groups referenced by the automation scripts (Sales-Team, IT-Team, HR-Team, Finance-Team, All-Employees).

## 6. Build Client01

Windows 11 Home cannot join a traditional Active Directory domain, that capability is restricted to Pro, Enterprise, and Education editions. Rather than upgrade a physical device, built a second Generation 2 VM using Microsoft's free 90-day Windows 11 Enterprise evaluation ISO, connected to the same external switch.

Enabled the virtual TPM in the VM's Security settings (required for Windows 11 setup inside a Gen 2 VM, off by default). Configured the client's DNS to point at DC01's static IP while leaving its own IP address on automatic DHCP.

## 7. Join the domain

Joined Client01 to `corp.local`. Both VMs had IPv6 disabled on their network adapters, this was required to fix a domain join failure where the client's automatic name resolution was preferring an ISP-provided IPv6 DNS server over the manually configured domain controller. Full detail on that one is in `TROUBLESHOOTING.md`.

## 8. Verify

Confirmed the environment by running the onboarding script from this repo against Active Directory, then logging into Client01 as the newly created domain user to confirm the account, group memberships, and forced password change all worked end to end.
