<#
.SYNOPSIS
    Offboards an employee: disables the account, strips group memberships,
    moves it to a Disabled Users OU, hides it from the address list, stamps
    the description with the date/reason, and logs every action.

.DESCRIPTION
    Offboarding is deliberately NON-destructive: we disable, we never delete.
    Deleting an account destroys its SID, which breaks file-permission audit
    trails and makes "we need to check what Bob had access to" impossible.
    Most orgs disable immediately, then delete after a retention period
    (30/60/90 days) via a separate cleanup process.

    PowerShell 5.1 compatible. Requires the ActiveDirectory module.

.PARAMETER Username
    The sAMAccountName of the user to offboard, e.g. "mgarcia".

.PARAMETER Reason
    Short free-text reason recorded in the account's description field,
    e.g. "Resignation", "Termination - ticket #4521", "Contract ended".

.EXAMPLE
    .\Offboard-Employee.ps1 -Username mgarcia -Reason "Resignation - last day 2026-07-31"

.EXAMPLE
    # Dry run:
    .\Offboard-Employee.ps1 -Username mgarcia -Reason "Test" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Reason
)

# ============================================================================
# CONFIGURATION  -  *** EDIT TO MATCH YOUR LAB ***
# ============================================================================
$DomainDN       = "DC=corp,DC=local"

# The OU where disabled accounts are parked. Create it once in your lab:
#   New-ADOrganizationalUnit -Name "Disabled Users" -Path "DC=corp,DC=local"
$DisabledUsersOU = "OU=Disabled Users,$DomainDN"

$LogFolder = Join-Path -Path $PSScriptRoot -ChildPath "Logs"

# ============================================================================
# LOGGING (same pattern as New-Employee.ps1  -  see that file for the full
# explanation of why we log this way)
# ============================================================================
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogFolder ("Offboard_{0}_{1}.log" -f $Username, (Get-Date -Format "yyyyMMdd_HHmmss"))

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
# MAIN
# ============================================================================
Write-Log "===== Offboard-Employee.ps1 started for '$Username' ====="
Write-Log "Reason: $Reason"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Log "Could not load ActiveDirectory module: $($_.Exception.Message)" -Level ERROR
    exit 1
}

# ----------------------------------------------------------------------------
# STEP 1: Find the user (fail fast if the username is wrong)
# ----------------------------------------------------------------------------
try {
    # -Properties: Get-ADUser only returns a small default attribute set for
    # performance. Anything extra (Description, MemberOf, Enabled state, etc.)
    # must be requested by name. Forgetting -Properties is the #1 beginner
    # confusion with Get-ADUser ("why is Description blank?!").
    $user = Get-ADUser -Identity $Username -Properties Description, MemberOf, Enabled, DistinguishedName -ErrorAction Stop
}
catch {
    Write-Log "User '$Username' not found in AD. Check the spelling (this parameter is the sAMAccountName, not the display name)." -Level ERROR
    exit 1
}

Write-Log "Found user: $($user.Name) ($($user.DistinguishedName))"

# Idempotency check: warn if the account is already disabled, but keep going  - 
# maybe a previous run got interrupted halfway and we're finishing the job.
if (-not $user.Enabled) {
    Write-Log "Account is ALREADY disabled. Continuing anyway to complete remaining offboarding steps." -Level WARN
}

# ----------------------------------------------------------------------------
# STEP 2: Disable the account
# ----------------------------------------------------------------------------
# This is FIRST on purpose: the moment offboarding starts, the person must not
# be able to log in. Everything after this step is cleanup; this step is the
# actual security control.
if ($PSCmdlet.ShouldProcess($Username, "Disable account")) {
    try {
        Disable-ADAccount -Identity $Username -ErrorAction Stop
        Write-Log "DISABLED account '$Username'" -Level SUCCESS
    }
    catch {
        Write-Log "Failed to disable account: $($_.Exception.Message)" -Level ERROR
        exit 1   # If we can't even disable, abort  -  nothing else matters more.
    }
}

# ----------------------------------------------------------------------------
# STEP 3: Record, then remove, group memberships
# ----------------------------------------------------------------------------
# We log the groups BEFORE removing them. Two reasons:
#   1. Audit: "what did this person have access to?" is a common HR/legal ask.
#   2. Rehire/mistake insurance: if the person comes back (or the wrong user
#      was offboarded), the log tells you exactly which groups to restore.
try {
    # Get-ADPrincipalGroupMembership returns full group objects for everything
    # the user is a member of  -  cleaner than parsing the MemberOf DN strings.
    $groups = Get-ADPrincipalGroupMembership -Identity $Username -ErrorAction Stop
}
catch {
    Write-Log "Could not read group memberships: $($_.Exception.Message)" -Level ERROR
    $groups = @()
}

foreach ($group in $groups) {
    # Every AD user has a "primary group" (almost always Domain Users) that
    # CANNOT be removed with Remove-ADGroupMember  -  AD itself refuses. So we
    # skip it instead of generating a guaranteed error on every single run.
    if ($group.Name -eq "Domain Users") {
        Write-Log "Skipping 'Domain Users' (primary group  -  cannot be removed)."
        continue
    }

    if ($PSCmdlet.ShouldProcess($Username, "Remove from group '$($group.Name)'")) {
        try {
            # -Confirm:$false suppresses the interactive "Are you sure?" prompt
            # PER GROUP  -  essential for anything meant to run unattended. Note
            # this does NOT bypass -WhatIf; ShouldProcess above handles that.
            Remove-ADGroupMember -Identity $group -Members $Username -Confirm:$false -ErrorAction Stop
            Write-Log "REMOVED '$Username' from group '$($group.Name)'" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to remove from '$($group.Name)': $($_.Exception.Message)" -Level WARN
        }
    }
}

# ----------------------------------------------------------------------------
# STEP 4: Hide from the Global Address List (Exchange environments)
# ----------------------------------------------------------------------------
# msExchHideFromAddressLists only exists if the AD schema has been extended by
# an Exchange installation. A plain lab domain does NOT have it, and setting a
# nonexistent attribute throws an error  -  so we try it, and treat failure as
# "not an Exchange environment" rather than a real problem. This is a good
# example of writing one script that works across different environments.
if ($PSCmdlet.ShouldProcess($Username, "Hide from Global Address List")) {
    try {
        Set-ADUser -Identity $Username -Replace @{ msExchHideFromAddressLists = $true } -ErrorAction Stop
        Write-Log "SET msExchHideFromAddressLists = true (hidden from GAL)" -Level SUCCESS
    }
    catch {
        Write-Log "Could not set msExchHideFromAddressLists  -  expected if this domain has no Exchange schema. Skipping." -Level WARN
    }
}

# ----------------------------------------------------------------------------
# STEP 5: Stamp the description field
# ----------------------------------------------------------------------------
# The description shows up right in the ADUC list view, so any admin glancing
# at the Disabled Users OU can see when and why each account was disabled
# without opening logs. We preserve the old description for context.
$disableStamp = "DISABLED {0} - {1}" -f (Get-Date -Format "yyyy-MM-dd"), $Reason
if ($user.Description) {
    $newDescription = "$disableStamp | Was: $($user.Description)"
}
else {
    $newDescription = $disableStamp
}

if ($PSCmdlet.ShouldProcess($Username, "Set description to '$newDescription'")) {
    try {
        Set-ADUser -Identity $Username -Description $newDescription -ErrorAction Stop
        Write-Log "SET description: '$newDescription'" -Level SUCCESS
    }
    catch {
        Write-Log "Failed to set description: $($_.Exception.Message)" -Level WARN
    }
}

# ----------------------------------------------------------------------------
# STEP 6: Move to the Disabled Users OU
# ----------------------------------------------------------------------------
# This is LAST because Move-ADObject changes the user's DistinguishedName, and
# some cmdlets/references above rely on the old DN. Ordering steps so that
# "identity-changing" operations happen last avoids a whole class of bugs.
$ouExists = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$DisabledUsersOU'" -ErrorAction SilentlyContinue
if ($null -eq $ouExists) {
    Write-Log "Disabled Users OU '$DisabledUsersOU' does not exist. Create it with: New-ADOrganizationalUnit -Name 'Disabled Users' -Path '$DomainDN'   -  account was NOT moved." -Level ERROR
}
else {
    if ($PSCmdlet.ShouldProcess($Username, "Move to $DisabledUsersOU")) {
        try {
            # Move-ADObject needs the object's DN (or GUID), not the username.
            # We re-read the user in case anything above changed it.
            $currentDN = (Get-ADUser -Identity $Username).DistinguishedName
            Move-ADObject -Identity $currentDN -TargetPath $DisabledUsersOU -ErrorAction Stop
            Write-Log "MOVED '$Username' to '$DisabledUsersOU'" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to move account: $($_.Exception.Message)" -Level ERROR
        }
    }
}

# ----------------------------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------------------------
Write-Log "===== Offboarding complete for '$Username' ====="
Write-Host ""
Write-Host "==================== SUMMARY ====================" -ForegroundColor Cyan
Write-Host "  Account      : $Username  (disabled)"
Write-Host "  Groups removed:"
foreach ($group in $groups) {
    if ($group.Name -ne "Domain Users") { Write-Host "    - $($group.Name)" }
}
Write-Host "  Moved to     : $DisabledUsersOU"
Write-Host "  Description  : $newDescription"
Write-Host "  Log file     : $LogFile"
Write-Host "=================================================" -ForegroundColor Cyan
