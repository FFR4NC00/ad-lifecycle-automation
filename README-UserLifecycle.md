# User Lifecycle Automation — New-Employee.ps1 & Offboard-Employee.ps1

## What it does

**New-Employee.ps1** automates everything a helpdesk tech would otherwise click through in Active Directory Users and Computers (ADUC) when a new hire starts: it creates the account in the correct department OU, generates a unique username and a complexity-compliant temporary password (flagged "must change at next logon"), sets identity attributes (display name, UPN, email, title, department, manager), adds the user to the department's security groups, creates a home folder with correct NTFS permissions, and writes a timestamped log of every action. It supports `-WhatIf` for a full dry run.

**Offboard-Employee.ps1** performs a security-first offboarding: it disables the account immediately, records and then removes all group memberships, hides the mailbox from the Global Address List (when Exchange schema attributes exist), stamps the description field with the disable date and reason, moves the account to a Disabled Users OU, and logs everything. It never deletes — accounts are disabled and retained for auditability.

## Prerequisites

1. **A domain-joined machine with the ActiveDirectory PowerShell module.** Easiest option in a lab: run the scripts directly on your Domain Controller VM (the module ships with the AD DS role). On a client/admin VM, install RSAT: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
2. **A domain admin (or appropriately delegated) account** to run the scripts.
3. **Your OU structure created.** The default config expects:
   ```
   OU=Employees,DC=corp,DC=local
     OU=Sales / OU=IT / OU=HR / OU=Finance
   OU=Disabled Users,DC=corp,DC=local
   ```
   Quick lab setup:
   ```powershell
   New-ADOrganizationalUnit -Name "Employees" -Path "DC=corp,DC=local"
   "Sales","IT","HR","Finance" | ForEach-Object {
       New-ADOrganizationalUnit -Name $_ -Path "OU=Employees,DC=corp,DC=local"
   }
   New-ADOrganizationalUnit -Name "Disabled Users" -Path "DC=corp,DC=local"
   ```
4. **The department groups created:**
   ```powershell
   "Sales-Team","IT-Team","HR-Team","Finance-Team","All-Employees" | ForEach-Object {
       New-ADGroup -Name $_ -GroupScope Global -Path "DC=corp,DC=local"
   }
   ```
5. **(Optional) A home folder share.** On a single-DC lab:
   ```powershell
   New-Item C:\HomeFolders -ItemType Directory
   New-SmbShare -Name 'Home$' -Path C:\HomeFolders -FullAccess "CORP\Domain Admins"
   ```
   In production this would live on a dedicated file server, never a DC. Set `$HomeFolderRoot = $null` in the script to skip this feature entirely.
6. **Adapt the CONFIGURATION block** at the top of each script: `$DomainDNS`, `$DomainDN`, the `$DepartmentConfig` OU paths and group names, `$HomeFolderRoot`, and `$DisabledUsersOU`. To discover your actual values run `Get-ADDomain | Select DNSRoot, DistinguishedName` and `Get-ADOrganizationalUnit -Filter * | Select DistinguishedName`.

## How to run

Always dry-run first:

```powershell
.\New-Employee.ps1 -FirstName Maria -LastName Garcia -Department Sales `
    -JobTitle "Account Executive" -Manager jsmith -WhatIf
```

Then for real (drop `-WhatIf`):

```powershell
.\New-Employee.ps1 -FirstName Maria -LastName Garcia -Department Sales `
    -JobTitle "Account Executive" -Manager jsmith
```

Offboarding:

```powershell
.\Offboard-Employee.ps1 -Username mgarcia -Reason "Resignation - last day 2026-07-31" -WhatIf
.\Offboard-Employee.ps1 -Username mgarcia -Reason "Resignation - last day 2026-07-31"
```

If script execution is blocked, allow local scripts for your session:
`Set-ExecutionPolicy -Scope Process RemoteSigned`

## Example output (onboarding)

```
[2026-07-23 14:30:55] [INFO] ===== New-Employee.ps1 started =====
[2026-07-23 14:30:56] [INFO] Username selected: mgarcia
[2026-07-23 14:30:56] [INFO] Manager resolved: jsmith -> CN=John Smith,OU=Sales,...
[2026-07-23 14:30:57] [SUCCESS] CREATED user 'mgarcia' (Maria Garcia) in OU: OU=Sales,OU=Employees,DC=corp,DC=local
[2026-07-23 14:30:57] [SUCCESS] SET manager for 'mgarcia' -> 'jsmith'
[2026-07-23 14:30:58] [SUCCESS] ADDED 'mgarcia' to group 'Sales-Team'
[2026-07-23 14:30:58] [SUCCESS] ADDED 'mgarcia' to group 'All-Employees'
[2026-07-23 14:30:59] [SUCCESS] CREATED home folder: \\DC01\Home$\mgarcia
[2026-07-23 14:30:59] [SUCCESS] GRANTED NTFS Modify on '\\DC01\Home$\mgarcia' to CORP\mgarcia

==================== SUMMARY ====================
  Username     : mgarcia
  Display Name : Maria Garcia
  UPN          : mgarcia@corp.local
  OU           : OU=Sales,OU=Employees,DC=corp,DC=local
  Groups       : Sales-Team, All-Employees
  Temp Password: Kr7mwvq#84Tn  (user must change at first logon)
  Log file     : ...\Logs\Onboard_20260723_143055.log
=================================================
```

## Known limitations (also good interview honesty)

- **Names, not immunity to collisions:** the CN ("Name") is `First Last`; two users with the identical full name in the same OU would collide on CN even though the sAMAccountName logic would handle it. Fix: append the username to the CN.
- **No Exchange/M365 mailbox provisioning** — only the AD `mail` attribute is set. Real onboarding would call Exchange Online or Graph API.
- **The temp password is displayed on screen** (deliberately never logged). A production version would deliver it via a secure channel (e.g., password reset portal, LAPS-style vault, or manager delivery workflow).
- **Home folder ACL can race replication:** granting NTFS rights to a seconds-old account occasionally fails to resolve the SID; the script warns and continues. Re-running the ACL step a minute later fixes it.
- **Single-domain assumption** — no multi-domain/forest logic.
- **Offboarding doesn't touch mailboxes, licenses, MFA tokens, or third-party SaaS** — in a real org those live in a broader leaver checklist/IDM system.
