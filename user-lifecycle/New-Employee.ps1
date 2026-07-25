<#
.SYNOPSIS
    Onboards a new employee: creates the AD account, sets attributes, adds groups,
    creates a home folder, and logs everything it does.

.DESCRIPTION
    This script is designed for a lab domain (e.g., corp.local) but follows the same
    patterns a real IT department would use. Everything environment-specific lives in
    the CONFIGURATION section near the top  -  change those values to match YOUR lab.

    PowerShell 5.1 compatible. Requires the ActiveDirectory module (RSAT, or run it
    directly on your Domain Controller VM, which already has the module).

.PARAMETER FirstName
    Employee's first name. Used for display name, UPN, and username generation.

.PARAMETER LastName
    Employee's last name.

.PARAMETER Department
    Must match one of the keys in $DepartmentConfig below (e.g., Sales, IT, HR).
    This drives BOTH which OU the account lands in and which groups it joins.

.PARAMETER JobTitle
    Free text, stored in the AD 'title' attribute.

.PARAMETER Manager
    Optional. The sAMAccountName (username) of the manager, e.g. "jsmith".
    Stored in the AD 'manager' attribute (which HR tools and Outlook org charts use).

.EXAMPLE
    .\New-Employee.ps1 -FirstName Maria -LastName Garcia -Department Sales -JobTitle "Account Executive" -Manager jsmith

.EXAMPLE
    # Dry run  -  shows what WOULD happen without changing anything:
    .\New-Employee.ps1 -FirstName Maria -LastName Garcia -Department Sales -JobTitle "AE" -WhatIf
#>

# ============================================================================
# PARAMETERS
# ============================================================================
# [CmdletBinding(SupportsShouldProcess = $true)] is what gives this script FREE
# support for -WhatIf and -Confirm. When a user passes -WhatIf, every action we
# wrap in $PSCmdlet.ShouldProcess(...) is skipped and instead prints
# "What if: ..."  -  this is the standard, professional way to build a dry-run
# mode in PowerShell (rather than inventing your own -DryRun switch).
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # [Parameter(Mandatory = $true)] means PowerShell will PROMPT for the value
    # if the caller forgets it  -  the script can never run with a blank name.
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]          # Rejects empty strings ("") too, not just missing values
    [string]$FirstName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$LastName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Department,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$JobTitle,

    # Manager is optional  -  new hires sometimes don't have one assigned yet.
    [Parameter(Mandatory = $false)]
    [string]$Manager
)

# ============================================================================
# CONFIGURATION   -  *** EDIT THIS SECTION TO MATCH YOUR LAB ***
# ============================================================================

# Your AD domain's DNS name. Run `Get-ADDomain | Select DNSRoot` on your DC
# to confirm what yours is.
$DomainDNS  = "corp.local"

# The distinguished name (DN) suffix of your domain. "corp.local" becomes
# "DC=corp,DC=local"  -  each dot-separated piece becomes a DC= component.
$DomainDN   = "DC=corp,DC=local"

# Department configuration: this ONE hashtable controls where accounts go and
# which groups they get. To support a new department, you add an entry here  - 
# no code changes needed. That separation of "config" from "logic" is a big
# deal in real automation: helpdesk staff can safely edit a config block
# without understanding the rest of the script.
#
# OU     = where the account is created. Adapt to YOUR OU tree. To see your
#          OUs, run:  Get-ADOrganizationalUnit -Filter * | Select DistinguishedName
# Groups = AD groups the user is added to. These groups MUST already exist
#          (create them in ADUC or with New-ADGroup); the script checks and
#          warns rather than crashing if one is missing.
$DepartmentConfig = @{
    "Sales" = @{
        OU     = "OU=Sales,OU=Employees,$DomainDN"
        Groups = @("Sales-Team", "All-Employees")
    }
    "IT" = @{
        OU     = "OU=IT,OU=Employees,$DomainDN"
        Groups = @("IT-Team", "All-Employees")
    }
    "HR" = @{
        OU     = "OU=HR,OU=Employees,$DomainDN"
        Groups = @("HR-Team", "All-Employees")
    }
    "Finance" = @{
        OU     = "OU=Finance,OU=Employees,$DomainDN"
        Groups = @("Finance-Team", "All-Employees")
    }
}

# Home folder root. In a real environment this is a file server UNC path like
# "\\FILESRV01\Home$". In a single-DC lab you can point it at a shared folder
# on the DC itself (create C:\HomeFolders, share it as Home$). Set to $null to
# skip home folder creation entirely.
$HomeFolderRoot = "\\DC01\Home$"      # <-- change to your server/share, or $null

# Where log files go. The script creates this folder if it doesn't exist.
$LogFolder = Join-Path -Path $PSScriptRoot -ChildPath "Logs"

# ============================================================================
# LOGGING SETUP
# ============================================================================
# We build ONE log file per script run, timestamped so runs never overwrite
# each other. Real IT teams live and die by logs: when someone asks "why does
# this account look wrong?" three weeks later, the log is your answer.

if (-not (Test-Path -Path $LogFolder)) {
    # Out-Null suppresses New-Item's console output  -  we don't need to see it.
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

# Example filename: Onboard_20260723_143055.log
$LogFile = Join-Path $LogFolder ("Onboard_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    <#
        Writes a message to BOTH the console and the log file, with a timestamp
        and a severity level. Centralizing logging in one function means every
        log line looks identical and we never forget to write to the file.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO"
    )

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line  = "[$stamp] [$Level] $Message"

    # Append to the log file. -Encoding UTF8 avoids weird characters in Notepad.
    Add-Content -Path $LogFile -Value $line -Encoding UTF8

    # Color-code console output so problems jump out at a glance.
    switch ($Level) {
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

# ============================================================================
# HELPER: TEMPORARY PASSWORD GENERATOR
# ============================================================================
function New-TemporaryPassword {
    <#
        Generates a random 12-character password that satisfies default AD
        complexity (upper + lower + digit + symbol). Ambiguous characters
        (O/0, l/1, I) are deliberately excluded because a helpdesk tech will
        read this password to a new hire over the phone.
    #>
    $upper  = "ABCDEFGHJKMNPQRSTUVWXYZ".ToCharArray()
    $lower  = "abcdefghjkmnpqrstuvwxyz".ToCharArray()
    $digit  = "23456789".ToCharArray()
    $symbol = "!@#$%&*".ToCharArray()

    # Guarantee at least one character from each required category...
    $chars = @()
    $chars += $upper  | Get-Random -Count 3
    $chars += $lower  | Get-Random -Count 5
    $chars += $digit  | Get-Random -Count 3
    $chars += $symbol | Get-Random -Count 1

    # ...then shuffle so the categories aren't always in the same order.
    # Sorting by a random value is a simple, PS 5.1-friendly shuffle.
    return -join ($chars | Sort-Object { Get-Random })
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================
Write-Log "===== New-Employee.ps1 started ====="
Write-Log "Input: FirstName='$FirstName' LastName='$LastName' Department='$Department' JobTitle='$JobTitle' Manager='$Manager'"

# ----------------------------------------------------------------------------
# STEP 0: Load the ActiveDirectory module
# ----------------------------------------------------------------------------
# -ErrorAction Stop turns a "non-terminating" error into a "terminating" one,
# which is what lets try/catch actually catch it. Without it, Import-Module
# would print red text but the script would blunder on and fail confusingly
# at the first AD cmdlet. You'll see this pattern on every risky call below.
try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Log "Could not load the ActiveDirectory module. Install RSAT or run this on the DC. Error: $($_.Exception.Message)" -Level ERROR
    exit 1    # Non-zero exit code = "failed", which Task Scheduler and other tools can detect.
}

# ----------------------------------------------------------------------------
# STEP 1: Validate the department
# ----------------------------------------------------------------------------
# Fail FAST and CLEARLY. If we let a bad department through, we'd crash later
# with a cryptic "cannot bind null OU" error. Checking up front lets us print
# a human-friendly message listing the valid options.
if (-not $DepartmentConfig.ContainsKey($Department)) {
    $validDepts = ($DepartmentConfig.Keys | Sort-Object) -join ", "
    Write-Log "Invalid department '$Department'. Valid departments are: $validDepts" -Level ERROR
    exit 1
}

$deptSettings = $DepartmentConfig[$Department]
$TargetOU     = $deptSettings.OU

# Also verify the OU actually exists in AD  -  catches typos in the config block.
# Note the filter syntax: AD filters are strings, and we compare the
# DistinguishedName attribute against our target.
try {
    $ouCheck = Get-ADOrganizationalUnit -Identity $TargetOU -ErrorAction Stop
}
catch {
    Write-Log "The OU '$TargetOU' does not exist in AD. Fix the OU path in the CONFIGURATION section (run Get-ADOrganizationalUnit -Filter * to list your OUs)." -Level ERROR
    exit 1
}

# ----------------------------------------------------------------------------
# STEP 2: Generate a unique username (sAMAccountName)
# ----------------------------------------------------------------------------
# Convention here: first initial + last name, lowercase, letters/digits only.
# "Maria Garcia" -> "mgarcia". This is the most common corporate convention.
#
# -replace '[^a-z0-9]', ''  strips anything that isn't a letter or digit,
# which handles names like "O'Brien" (obrien) or "van der Berg" (mvanderberg).
$baseUsername = ($FirstName.Substring(0, 1) + $LastName).ToLower() -replace '[^a-z0-9]', ''

# sAMAccountName has a hard 20-character limit (a pre-Windows-2000 legacy rule
# AD still enforces). Truncate if needed, leaving room for a collision digit.
if ($baseUsername.Length -gt 18) {
    $baseUsername = $baseUsername.Substring(0, 18)
}

# Duplicate handling: if "mgarcia" is taken, try "mgarcia2", "mgarcia3", ...
# This is the "duplicate username" error handling the requirements asked for  - 
# instead of crashing, we resolve the conflict the way a human admin would.
$Username = $baseUsername
$suffix   = 1
while ($true) {
    # -Filter uses AD's own query language; this only returns a user if one
    # exists with that exact sAMAccountName. $null result = name is free.
    $existing = Get-ADUser -Filter "SamAccountName -eq '$Username'" -ErrorAction SilentlyContinue
    if ($null -eq $existing) { break }          # Name is available  -  stop looping.

    $suffix++
    $Username = "$baseUsername$suffix"
    Write-Log "Username '$baseUsername' variant taken; trying '$Username'..." -Level WARN

    if ($suffix -gt 20) {
        # Safety valve: something is very wrong if 20 variants are all taken.
        Write-Log "Could not find a free username after 20 attempts. Aborting." -Level ERROR
        exit 1
    }
}
Write-Log "Username selected: $Username"

# ----------------------------------------------------------------------------
# STEP 3: Build the remaining identity attributes
# ----------------------------------------------------------------------------
$DisplayName = "$FirstName $LastName"
$UPN         = "$Username@$DomainDNS"        # UserPrincipalName  -  the modern "email-style" login
$Email       = "$Username@$DomainDNS"        # In a lab, email == UPN. In prod this might differ.

# Resolve the manager (if provided) BEFORE creating the user, so a typo in the
# manager name fails cleanly instead of leaving a half-configured account.
$ManagerDN = $null
if ($Manager) {
    try {
        # The 'manager' attribute in AD stores the manager's Distinguished Name,
        # not their username  -  so we look them up and grab the DN.
        $mgrObject = Get-ADUser -Identity $Manager -ErrorAction Stop
        $ManagerDN = $mgrObject.DistinguishedName
        Write-Log "Manager resolved: $Manager -> $ManagerDN"
    }
    catch {
        Write-Log "Manager '$Manager' was not found in AD. The account will be created WITHOUT a manager set." -Level WARN
        # We warn-and-continue rather than abort: a missing manager attribute is
        # cosmetic; a new hire with no account on day one is a real problem.
    }
}

# ----------------------------------------------------------------------------
# STEP 4: Create the account
# ----------------------------------------------------------------------------
$TempPassword = New-TemporaryPassword

# AD cmdlets refuse plain-text passwords; they require a SecureString.
# -AsPlainText -Force is acceptable here because the password was just
# generated in memory  -  we're not reading a stored secret.
$SecurePassword = ConvertTo-SecureString -String $TempPassword -AsPlainText -Force

# $PSCmdlet.ShouldProcess(target, action) returns:
#   - $true  in a normal run  -> the if-block executes
#   - $false when -WhatIf was passed -> PowerShell prints "What if: ..." instead
if ($PSCmdlet.ShouldProcess($Username, "Create AD user in $TargetOU")) {
    try {
        # Splatting: put all the parameters in a hashtable and pass it with @.
        # Functionally identical to one giant command line, but readable and
        # diff-friendly. You'll see splatting everywhere in production scripts.
        $newUserParams = @{
            Name                  = $DisplayName        # The CN (what ADUC shows in the tree)
            GivenName             = $FirstName
            Surname               = $LastName
            SamAccountName        = $Username
            UserPrincipalName     = $UPN
            DisplayName           = $DisplayName
            EmailAddress          = $Email
            Title                 = $JobTitle
            Department            = $Department
            Path                  = $TargetOU           # WHERE the account is created
            AccountPassword       = $SecurePassword
            Enabled               = $true
            ChangePasswordAtLogon = $true               # Forces password change at first logon  - 
                                                        # the temp password is only ever used once.
            ErrorAction           = "Stop"              # Make failures catchable (see STEP 0 note)
        }
        New-ADUser @newUserParams

        Write-Log "CREATED user '$Username' ($DisplayName) in OU: $TargetOU" -Level SUCCESS
        Write-Log "Attributes set: UPN=$UPN, Email=$Email, Title='$JobTitle', Department=$Department, ChangePasswordAtLogon=True"
    }
    catch {
        # $_ inside a catch block is the error record; .Exception.Message is the
        # human-readable part. We log it and stop  -  nothing else can succeed if
        # the account itself wasn't created.
        Write-Log "FAILED to create user '$Username': $($_.Exception.Message)" -Level ERROR
        exit 1
    }
}

# ----------------------------------------------------------------------------
# STEP 5: Set the manager attribute
# ----------------------------------------------------------------------------
if ($ManagerDN) {
    if ($PSCmdlet.ShouldProcess($Username, "Set manager to $Manager")) {
        try {
            Set-ADUser -Identity $Username -Manager $ManagerDN -ErrorAction Stop
            Write-Log "SET manager for '$Username' -> '$Manager'" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to set manager: $($_.Exception.Message)" -Level WARN
        }
    }
}

# ----------------------------------------------------------------------------
# STEP 6: Add to department groups
# ----------------------------------------------------------------------------
foreach ($groupName in $deptSettings.Groups) {
    # Check the group exists first so ONE missing group doesn't kill the loop  - 
    # we want to add the user to every group we CAN and report the ones we can't.
    $group = Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue
    if ($null -eq $group) {
        Write-Log "Group '$groupName' does not exist  -  skipped. Create it with: New-ADGroup -Name '$groupName' -GroupScope Global -Path '<your groups OU>'" -Level WARN
        continue
    }

    if ($PSCmdlet.ShouldProcess($Username, "Add to group '$groupName'")) {
        try {
            Add-ADGroupMember -Identity $groupName -Members $Username -ErrorAction Stop
            Write-Log "ADDED '$Username' to group '$groupName'" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to add to '$groupName': $($_.Exception.Message)" -Level WARN
        }
    }
}

# ----------------------------------------------------------------------------
# STEP 7: Create the home folder + NTFS permissions
# ----------------------------------------------------------------------------
# LAB PREREQUISITE: $HomeFolderRoot must be a share that exists and that YOU
# (the admin running the script) can write to. On a single-DC lab:
#   1. On the DC: New-Item C:\HomeFolders -ItemType Directory
#   2. Share it:  New-SmbShare -Name 'Home$' -Path C:\HomeFolders -FullAccess 'CORP\Domain Admins'
#      (the trailing $ makes the share hidden from casual browsing)
#   3. Set $HomeFolderRoot = "\\DC01\Home$"  (use YOUR DC's name)
# In production this would be a dedicated file server, never the DC  -  that's a
# talking point, not a blocker, for a lab.
if ($HomeFolderRoot) {
    $HomePath = Join-Path $HomeFolderRoot $Username

    if ($PSCmdlet.ShouldProcess($HomePath, "Create home folder and grant NTFS Modify")) {
        try {
            if (Test-Path $HomePath) {
                Write-Log "Home folder '$HomePath' already exists  -  skipping creation." -Level WARN
            }
            else {
                New-Item -Path $HomePath -ItemType Directory -ErrorAction Stop | Out-Null
                Write-Log "CREATED home folder: $HomePath" -Level SUCCESS
            }

            # --- NTFS permissions ---
            # Get the folder's current ACL (Access Control List), add one rule,
            # write it back. The rule below grants the new user "Modify" (read/
            # write/delete their own files but NOT change permissions  -  that
            # stays with admins).
            $acl = Get-Acl -Path $HomePath

            # FileSystemAccessRule arguments, in order:
            #   1. WHO   - "DOMAIN\username"
            #   2. WHAT  - Modify (a sensible default for personal folders)
            #   3. INHERITANCE - ContainerInherit,ObjectInherit = "apply to all
            #      subfolders and files created inside"
            #   4. PROPAGATION - None = normal inheritance behavior
            #   5. TYPE  - Allow (as opposed to a Deny rule)
            $netbios = (Get-ADDomain).NetBIOSName
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "$netbios\$Username",
                "Modify",
                "ContainerInherit,ObjectInherit",
                "None",
                "Allow"
            )
            $acl.AddAccessRule($rule)
            Set-Acl -Path $HomePath -AclObject $acl -ErrorAction Stop
            Write-Log "GRANTED NTFS Modify on '$HomePath' to $netbios\$Username" -Level SUCCESS

            # Point the AD account at its home folder (shows up in the user's
            # profile tab in ADUC; many orgs map it as the H: drive).
            Set-ADUser -Identity $Username -HomeDirectory $HomePath -HomeDrive "H:" -ErrorAction Stop
            Write-Log "SET AD HomeDirectory=$HomePath, HomeDrive=H:" -Level SUCCESS
        }
        catch {
            # A brand-new account's SID occasionally isn't replicated/resolvable
            # for a few seconds  -  if the ACL step fails, re-running just that
            # part a minute later usually works. We log and continue.
            Write-Log "Home folder step failed: $($_.Exception.Message) (If this is a fresh account, wait ~1 min and retry the ACL manually.)" -Level WARN
        }
    }
}
else {
    Write-Log "HomeFolderRoot is not configured  -  skipping home folder creation."
}

# ----------------------------------------------------------------------------
# STEP 8: Summary
# ----------------------------------------------------------------------------
Write-Log "===== Onboarding complete for $DisplayName ====="
Write-Host ""
Write-Host "==================== SUMMARY ====================" -ForegroundColor Cyan
Write-Host "  Username     : $Username"
Write-Host "  Display Name : $DisplayName"
Write-Host "  UPN          : $UPN"
Write-Host "  OU           : $TargetOU"
Write-Host "  Groups       : $($deptSettings.Groups -join ', ')"
Write-Host "  Temp Password: $TempPassword  (user must change at first logon)" -ForegroundColor Yellow
Write-Host "  Log file     : $LogFile"
Write-Host "=================================================" -ForegroundColor Cyan
# NOTE: We deliberately do NOT write the temp password to the log file.
# Passwords in log files are a classic security finding  -  the password is
# shown once, on screen, to the admin who ran the script, and nowhere else.
