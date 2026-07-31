<#
.SYNOPSIS
    Searches Active Directory's Recycle Bin for deleted objects matching a
    search term, shows you exactly what it found, and restores the one you
    choose back to its original location.

.DESCRIPTION
    This is the "someone deleted the wrong user at 4:55 PM on a Friday" script.
    With the AD Recycle Bin enabled (a ONE-TIME domain setup step  -  see the
    README, not this script), deleted objects keep ALL their attributes  - 
    group memberships, password, SID, everything  -  for 180 days by default,
    and can be restored fully intact. Without the Recycle Bin, a deleted
    object is stripped to a "tombstone" with almost no attributes, and your
    only options are an authoritative restore from backup (see the runbook)
    or painful tombstone reanimation.

    PREREQUISITE: the AD Recycle Bin must already be enabled in the forest.
    Objects deleted BEFORE it was enabled are NOT recoverable this way.

    PowerShell 5.1 compatible. Requires the ActiveDirectory module. Run as a
    domain admin (or an account delegated rights on the Deleted Objects
    container).

.PARAMETER SearchTerm
    Full or partial name of the deleted object, e.g. "mgarcia", "Garcia",
    "Sales". Matched against the object's name, case-insensitively.

.EXAMPLE
    .\Restore-DeletedADObject.ps1 -SearchTerm mgarcia

.EXAMPLE
    # Preview: search and display matches, but never restore anything.
    .\Restore-DeletedADObject.ps1 -SearchTerm Garcia -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchTerm
)

# ============================================================================
# LOGGING  -  same pattern as the rest of the portfolio
# ============================================================================
$LogFolder = Join-Path -Path $PSScriptRoot -ChildPath "Logs"
if (-not (Test-Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogFolder ("ADRestore_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

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

Write-Log "===== Restore-DeletedADObject.ps1 started ====="
Write-Log "Search term: '$SearchTerm'  Run by: $env:USERDOMAIN\$env:USERNAME"

# ============================================================================
# STEP 0: Load the AD module and confirm the Recycle Bin is actually enabled
# ============================================================================
try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Log "Could not load the ActiveDirectory module: $($_.Exception.Message)" -Level ERROR
    exit 1
}

# Checking the Recycle Bin state up front turns "restore mysteriously returns
# nothing / fails" into a clear, actionable message. An optional feature is
# "enabled" when its EnabledScopes property is non-empty.
try {
    $rbFeature = Get-ADOptionalFeature -Filter 'Name -eq "Recycle Bin Feature"' -ErrorAction Stop
    if (-not $rbFeature.EnabledScopes -or $rbFeature.EnabledScopes.Count -eq 0) {
        Write-Log "The AD Recycle Bin is NOT enabled in this forest. Enable it once (IRREVERSIBLE  -  see README):  Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet -Target 'corp.local'" -Level ERROR
        exit 1
    }
    Write-Log "AD Recycle Bin is enabled  -  good."
}
catch {
    Write-Log "Could not query the Recycle Bin feature state: $($_.Exception.Message)" -Level ERROR
    exit 1
}

# ============================================================================
# STEP 1: Search the deleted objects
# ============================================================================
# Two things make deleted objects special:
#   1. They're hidden from normal queries  -  you must explicitly ask with
#      -IncludeDeletedObjects, and filter on isDeleted = $true.
#   2. Their Name gets mangled at deletion: "Maria Garcia" becomes
#      "Maria Garcia\0ADEL:<guid>" (the original name, a null character, and
#      the deletion marker). That's why:
#        - our -like '*term*' filter still matches (the original name is the
#          prefix), and
#        - we display 'msDS-LastKnownRDN'  -  the object's ORIGINAL name  -  plus
#          'lastKnownParent'  -  its original container  -  instead of the mangled
#          Name/DN. Show the human what they'd recognize.
#
# whenChanged serves as the deletion timestamp: deleting an object IS its last
# change, so on a deleted object these are effectively the same moment.
#
# Note the escaped `$true inside the double-quoted filter string: we want the
# literal text '$true' passed to AD's filter parser, not PowerShell expanding
# it first. (Single-quoting the whole filter would block $SearchTerm from
# expanding, so we escape just the dollar sign we want kept.)
$filter = "isDeleted -eq `$true -and name -like '*$SearchTerm*'"

try {
    # Why "$deletedMatches" and not "$matches"? Because $Matches is one of
    # PowerShell's AUTOMATIC variables  -  every use of the -match operator
    # silently overwrites it. Naming our array $matches would work right up
    # until the first -match in a loop wiped it out mid-run. Never shadow
    # automatic variables ($matches, $error, $input, $args, ...).
    $deletedMatches = @(Get-ADObject -IncludeDeletedObjects -Filter $filter `
        -Properties objectClass, whenChanged, lastKnownParent, 'msDS-LastKnownRDN', sAMAccountName -ErrorAction Stop)
    # The @( ) wrapper forces an ARRAY even when there's exactly one result.
    # Without it, one match comes back as a single object, .Count behaves
    # differently in PS 5.1, and indexing breaks  -  a classic PowerShell trap.
}
catch {
    Write-Log "Search failed: $($_.Exception.Message)" -Level ERROR
    exit 1
}

# ============================================================================
# STEP 2: Zero matches  -  say so clearly and explain the likely reasons
# ============================================================================
if ($deletedMatches.Count -eq 0) {
    Write-Log "No deleted objects found matching '*$SearchTerm*'." -Level WARN
    Write-Log "Possible reasons: (a) the object was deleted MORE than 180 days ago (default deleted-object lifetime) and has been purged; (b) it was deleted BEFORE the Recycle Bin was enabled; (c) different spelling  -  try a shorter/partial term; (d) it was never deleted (check with: Get-ADUser -Identity <name>)."
    exit 0   # Zero matches is a valid outcome, not a script failure  -  exit 0.
}

# ============================================================================
# STEP 3: Display the matches so a human can verify BEFORE anything happens
# ============================================================================
# Restoring the wrong object is nearly as bad as the deletion. This display
# step is a deliberate control: name, type, deletion time, and original
# location are enough for a tech to recognize "yes, that's the one".
Write-Host ""
Write-Host ("Found {0} deleted object(s) matching '*{1}*':" -f $deletedMatches.Count, $SearchTerm) -ForegroundColor Cyan
Write-Host ""

for ($i = 0; $i -lt $deletedMatches.Count; $i++) {
    $m = $deletedMatches[$i]
    # Property names containing a hyphen must be quoted: $m.'msDS-LastKnownRDN'
    # (unquoted, PowerShell would parse the hyphen as subtraction).
    $origName = $m.'msDS-LastKnownRDN'
    if (-not $origName) {
        # Fallback: the mangled Name is "<original><NUL>DEL:<guid>"  -  split on
        # the NUL character (`0 in PowerShell) and keep the first piece.
        $origName = ($m.Name -split "`0")[0]
    }

    Write-Host ("  [{0}] {1}" -f ($i + 1), $origName) -ForegroundColor White
    Write-Host ("       Type            : {0}" -f $m.objectClass)
    Write-Host ("       Deleted (approx): {0}" -f $m.whenChanged)
    Write-Host ("       Original parent : {0}" -f $m.lastKnownParent)
    if ($m.sAMAccountName) {
        Write-Host ("       sAMAccountName  : {0}" -f $m.sAMAccountName)
    }

    # If the object's original PARENT was also deleted, its lastKnownParent DN
    # contains the same \0ADEL marker. Restore-ADObject would fail, because AD
    # restores an object back to its original parent, and that parent must
    # exist. The fix is to restore top-down: parent OU first, then children.
    # We detect and explain this now, before the user hits a confusing error.
    if ($m.lastKnownParent -match "0ADEL") {
        Write-Host ("       !! The original parent container was ALSO deleted. Restore the parent (search for it with this script) BEFORE this object.") -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Log ("Match [{0}]: '{1}' type={2} deleted~{3} parent='{4}'" -f ($i + 1), $origName, $m.objectClass, $m.whenChanged, $m.lastKnownParent)
}

# ============================================================================
# STEP 4: Select which object to restore
# ============================================================================
if ($deletedMatches.Count -eq 1) {
    # One match: it's pre-selected; the confirmation prompt in Step 5 is still
    # the safety gate. (Auto-restoring on a single match with no confirmation
    # would make a partial-name typo dangerous.)
    $selected = $deletedMatches[0]
    Write-Log "Single match  -  pre-selected for restore (confirmation still required)."
}
else {
    # Multiple matches: the user picks by index. We validate the input in a
    # loop instead of trusting it  -  Read-Host returns a STRING, so we also
    # cast to int inside a try/catch to survive non-numeric input.
    $selected = $null
    while ($null -eq $selected) {
        $answer = Read-Host ("Enter the number of the object to restore (1-{0}), or Q to quit" -f $deletedMatches.Count)
        if ($answer -match '^[Qq]$') {
            Write-Log "User quit at selection. Nothing was restored."
            exit 0
        }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $deletedMatches.Count) {
            $selected = $deletedMatches[$index - 1]    # Human 1-based -> array 0-based
        }
        else {
            Write-Host "Invalid selection  -  enter a number between 1 and $($deletedMatches.Count), or Q." -ForegroundColor Yellow
        }
    }
}

$selectedName = $selected.'msDS-LastKnownRDN'
if (-not $selectedName) { $selectedName = $selected.Name }

# ============================================================================
# STEP 5: Confirm, then restore
# ============================================================================
# Order matters here: ShouldProcess FIRST, Read-Host confirmation INSIDE it.
# That way -WhatIf prints "What if: Restoring..." and skips the prompt entirely
#  -  a preview mode that stops to ask questions isn't much of a preview, and
# would hang if someone scripted this with -WhatIf non-interactively.
if ($PSCmdlet.ShouldProcess($selectedName, "Restore deleted AD object to '$($selected.lastKnownParent)'")) {

    Write-Host ""
    $confirm = Read-Host ("Restore '{0}' ({1}) back to '{2}'? Type YES to proceed" -f $selectedName, $selected.objectClass, $selected.lastKnownParent)
    # Requiring the literal word YES (not just Y/Enter) is a small friction
    # spike, on purpose  -  this is a restore-to-production-directory action.
    if ($confirm -cne "YES") {
        Write-Log "User declined confirmation (typed '$confirm'). Nothing was restored."
        exit 0
    }

    try {
        # We restore by ObjectGUID, not by name. The GUID is the one identifier
        # that survives deletion unchanged and is unambiguous  -  names are
        # mangled and can even collide between multiple deleted objects.
        Restore-ADObject -Identity $selected.ObjectGUID -ErrorAction Stop
        Write-Log "RESTORED '$selectedName' (GUID $($selected.ObjectGUID)) to '$($selected.lastKnownParent)'" -Level SUCCESS
    }
    catch {
        Write-Log "Restore FAILED: $($_.Exception.Message)" -Level ERROR
        if ($selected.lastKnownParent -match "0ADEL") {
            Write-Log "The original parent container is itself deleted  -  restore the parent first, then re-run this script for this object." -Level ERROR
        }
        exit 1
    }

    # ------------------------------------------------------------------------
    # STEP 6: Verify  -  trust, but verify (same philosophy as the backup script)
    # ------------------------------------------------------------------------
    # A restored object should now be findable by a NORMAL query (no
    # -IncludeDeletedObjects). If we can fetch it by GUID the ordinary way,
    # the restore genuinely took effect.
    try {
        $restored = Get-ADObject -Identity $selected.ObjectGUID -Properties whenChanged -ErrorAction Stop
        Write-Log "VERIFIED: object now exists as '$($restored.DistinguishedName)'" -Level SUCCESS
        if ($restored.objectClass -eq "user") {
            Write-Log "Post-restore reminders for a user account: check whether it should be ENABLED (restores come back in their pre-delete state), confirm group memberships (Get-ADPrincipalGroupMembership $($selected.sAMAccountName)), and consider a password reset if the deletion was security-related."
        }
    }
    catch {
        Write-Log "Restore command succeeded but verification query failed: $($_.Exception.Message)  -  check replication or query the object manually." -Level WARN
    }
}
else {
    Write-Log "Preview mode: no restore performed (remove -WhatIf to restore)."
}

Write-Log "===== Restore-DeletedADObject.ps1 finished ====="
Write-Log "Log file: $LogFile"
exit 0
