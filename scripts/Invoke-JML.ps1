<#
.SYNOPSIS
    Joiner / Mover / Leaver automation driven by an HR change file.

.DESCRIPTION
    Reads a CSV of HR changes and applies them to Active Directory:
      Joiner : create account in the department OU, set attributes, add GG_<Dept>,
               random temporary password, must change at first logon.
      Mover  : remove all GG_<Dept> memberships, add the new department group,
               move the account to the new department OU, update attributes.
      Leaver : record current groups, remove all groups, disable the account,
               move it to Disabled Users, stamp the description.

    Users are matched on the employeeID attribute, never on name, so two people
    with the same name cannot be confused.

    Every action is written to logs\jml_<timestamp>.log and a CSV summary.
    Supports -WhatIf for a dry run.

    LAB ONLY: temporary passwords are written to logs\temp_passwords_<timestamp>.csv
    so you can test first logon. In production these would go through a secure
    handoff (e.g. manager portal or sealed delivery), never a plain file.

.EXAMPLE
    .\Invoke-JML.ps1 -CsvPath ..\data\hr_changes.csv -WhatIf
    .\Invoke-JML.ps1 -CsvPath ..\data\hr_changes.csv
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$CsvPath,

    [string]$LogDir = (Join-Path $PSScriptRoot '..\logs')
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain     = Get-ADDomain
$domainDN   = $domain.DistinguishedName
$upnSuffix  = $domain.DNSRoot          # change if you add an alternate UPN suffix for Entra sync
$usersOU    = "OU=Users,OU=Lab,$domainDN"
$disabledOU = "OU=Disabled Users,OU=Lab,$domainDN"
$stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null }
$dryRun = [bool]$WhatIfPreference
$logFile     = Join-Path $LogDir "jml_$stamp.log"
$summaryFile = Join-Path $LogDir "jml_summary_$stamp.csv"
$pwFile      = Join-Path $LogDir "temp_passwords_$stamp.csv"

$summary = New-Object System.Collections.Generic.List[object]
$tempPw  = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $tag  = if ($dryRun) { '[DRY RUN] ' } else { '' }
    $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $tag, $Message
    Add-Content -Path $logFile -Value $line -WhatIf:$false
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Add-Result {
    param($Row, [string]$Result, [string]$Detail)
    $summary.Add([pscustomobject]@{
        Action     = $Row.Action
        EmployeeID = $Row.EmployeeID
        Name       = "$($Row.FirstName) $($Row.LastName)"
        Result     = if ($dryRun -and $Result -eq 'Success') { 'WouldSucceed' } else { $Result }
        Detail     = $Detail
    })
}

function New-TempPassword {
    param([int]$Length = 16)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%*-_?')
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 1
    $pick = {
        param($s)
        $rng.GetBytes($bytes)
        $s[$bytes[0] % $s.Length]
    }
    # one from each set guarantees complexity, the rest from the combined pool
    $chars = foreach ($s in $sets) { & $pick $s }
    $all = -join $sets
    $chars += for ($i = $chars.Count; $i -lt $Length; $i++) { & $pick $all }
    # shuffle
    -join ($chars | Sort-Object { $rng.GetBytes($bytes); $bytes[0] })
}

function Get-UniqueSam {
    param([string]$First, [string]$Last)
    $clean = { param($s) ($s -replace "[^a-zA-Z]", '').ToLower() }
    $base = '{0}.{1}' -f (& $clean $First), (& $clean $Last)
    if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }   # leave room for a suffix within the 20 char limit
    $sam = $base; $n = 1
    while (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        $n++; $sam = "$base$n"
    }
    return $sam
}

function Get-UserByEmployeeId {
    param([string]$EmployeeID)
    $u = @(Get-ADUser -Filter "employeeID -eq '$EmployeeID'" -Properties employeeID, Department, Title, MemberOf, Enabled)
    if ($u.Count -gt 1) { throw "Multiple accounts share employeeID $EmployeeID. Fix the directory before continuing." }
    return $u | Select-Object -First 1
}

function Test-DepartmentReady {
    param([string]$Dept)
    $ou = "OU=$Dept,$usersOU"
    $okOU = [bool](Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ou'" -ErrorAction SilentlyContinue)
    $okGG = [bool](Get-ADGroup -Filter "Name -eq 'GG_$Dept'" -ErrorAction SilentlyContinue)
    return ($okOU -and $okGG)
}

# --- Process the change file ----------------------------------------------
$rows = @(Import-Csv -Path $CsvPath)
Write-Log "Starting JML run: $($rows.Count) change(s) from $CsvPath. WhatIf=$($WhatIfPreference)"

foreach ($row in $rows) {
    try {
        switch ($row.Action.Trim()) {

            'Joiner' {
                if (Get-UserByEmployeeId $row.EmployeeID) {
                    Write-Log "Joiner $($row.EmployeeID): account already exists, skipped" WARN
                    Add-Result $row 'Skipped' 'Account already exists'
                    continue
                }
                if (-not (Test-DepartmentReady $row.Department)) {
                    throw "Department '$($row.Department)' has no OU or GG_ group. Run Setup-LabStructure.ps1."
                }
                $sam = Get-UniqueSam $row.FirstName $row.LastName
                $pw  = New-TempPassword
                $ou  = "OU=$($row.Department),$usersOU"

                if ($PSCmdlet.ShouldProcess($sam, "Create user in $ou")) {
                    New-ADUser -Name "$($row.FirstName) $($row.LastName)" `
                        -GivenName $row.FirstName -Surname $row.LastName `
                        -SamAccountName $sam -UserPrincipalName "$sam@$upnSuffix" `
                        -DisplayName "$($row.FirstName) $($row.LastName)" `
                        -EmployeeID $row.EmployeeID -Department $row.Department -Title $row.Title `
                        -Path $ou -AccountPassword (ConvertTo-SecureString $pw -AsPlainText -Force) `
                        -ChangePasswordAtLogon $true -Enabled $true
                    Add-ADGroupMember -Identity "GG_$($row.Department)" -Members $sam
                    $tempPw.Add([pscustomobject]@{ SamAccountName = $sam; TempPassword = $pw })
                }
                Write-Log "Joiner $($row.EmployeeID): created $sam in $($row.Department), added to GG_$($row.Department)"
                Add-Result $row 'Success' "Created $sam"
            }

            'Mover' {
                $user = Get-UserByEmployeeId $row.EmployeeID
                if (-not $user) { throw "No account with employeeID $($row.EmployeeID)" }
                if (-not $user.Enabled) { throw "$($user.SamAccountName) is disabled; a mover should be an active account" }
                $newDept = $row.NewDepartment.Trim()
                if (-not $newDept) { throw 'Mover row has no NewDepartment' }
                if (-not (Test-DepartmentReady $newDept)) {
                    throw "Department '$newDept' has no OU or GG_ group. Run Setup-LabStructure.ps1."
                }

                # Remove every department group, not just the one HR says they came from.
                # This catches access left over from earlier moves (privilege creep).
                $deptGroups = $user.MemberOf | Where-Object { $_ -match '^CN=GG_[^,]+,' } |
                    Where-Object { $_ -notmatch '^CN=GG_IT_ServiceDesk_Admins,' }

                if ($PSCmdlet.ShouldProcess($user.SamAccountName, "Move to $newDept")) {
                    foreach ($g in $deptGroups) {
                        Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false
                        Write-Log "Mover $($row.EmployeeID): removed from $(($g -split ',')[0] -replace 'CN=')"
                    }
                    Add-ADGroupMember -Identity "GG_$newDept" -Members $user
                    Set-ADUser -Identity $user -Department $newDept -Title $row.Title
                    Move-ADObject -Identity $user.DistinguishedName -TargetPath "OU=$newDept,$usersOU"
                }
                Write-Log "Mover $($row.EmployeeID): $($user.SamAccountName) now in $newDept"
                Add-Result $row 'Success' "$($row.Department) -> $newDept; removed $(@($deptGroups).Count) dept group(s)"
            }

            'Leaver' {
                $user = Get-UserByEmployeeId $row.EmployeeID
                if (-not $user) { throw "No account with employeeID $($row.EmployeeID)" }

                $groups = @($user.MemberOf)
                $groupNames = ($groups | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }) -join '; '

                if ($PSCmdlet.ShouldProcess($user.SamAccountName, 'Disable and remove access')) {
                    # Record before removing, so access can be audited or restored
                    Write-Log "Leaver $($row.EmployeeID): groups before removal: $groupNames"
                    foreach ($g in $groups) {
                        Remove-ADGroupMember -Identity $g -Members $user -Confirm:$false
                    }
                    Disable-ADAccount -Identity $user
                    Set-ADUser -Identity $user -Description ("Disabled {0} by JML ({1}). Prior groups: {2}" -f (Get-Date -Format 'yyyy-MM-dd'), $row.EmployeeID, $groupNames)
                    Move-ADObject -Identity $user.DistinguishedName -TargetPath $disabledOU
                }
                Write-Log "Leaver $($row.EmployeeID): $($user.SamAccountName) disabled, $($groups.Count) group(s) removed, moved to Disabled Users"
                Add-Result $row 'Success' "Disabled; removed $($groups.Count) group(s)"
            }

            default {
                throw "Unknown action '$($row.Action)'"
            }
        }
    }
    catch {
        Write-Log "$($row.Action) $($row.EmployeeID): $($_.Exception.Message)" ERROR
        Add-Result $row 'Failed' $_.Exception.Message
    }
}

$summary | Export-Csv -Path $summaryFile -NoTypeInformation -WhatIf:$false
if ($tempPw.Count -gt 0) { $tempPw | Export-Csv -Path $pwFile -NoTypeInformation -WhatIf:$false }

$ok   = @($summary | Where-Object { $_.Result -in 'Success','WouldSucceed' }).Count
$fail = @($summary | Where-Object Result -eq 'Failed').Count
Write-Log "Finished: $ok succeeded, $fail failed, $($summary.Count - $ok - $fail) skipped. Summary: $summaryFile"
