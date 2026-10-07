<#
.SYNOPSIS
    Periodic access review: finds the account hygiene problems an IAM team is asked about in audits.

.DESCRIPTION
    Checks:
      1. Stale accounts       : enabled, no logon in -StaleDays (or never logged on and older than -NewAccountGraceDays)
      2. Password never expires on enabled user accounts
      3. Privileged group membership (recursive), flagging any non admin-named account
      4. Disabled accounts that still hold group memberships (incomplete leaver process)
      5. Department mismatch  : Department attribute does not match GG_<Dept> membership
      6. Admin accounts without "Account is sensitive and cannot be delegated"

    Output: one CSV per check in reports\<date>\ plus a console summary.

    Note: LastLogonDate comes from lastLogonTimestamp, which replicates only every
    9 to 14 days. Good enough for a 90 day stale check, not for "last logon yesterday".

.EXAMPLE
    .\Get-AccessReview.ps1
    .\Get-AccessReview.ps1 -StaleDays 60
    .\Get-AccessReview.ps1 -NewAccountGraceDays 0     (lab: flag every never-used account)
#>
[CmdletBinding()]
param(
    [int]$StaleDays = 90,
    [int]$NewAccountGraceDays = 14,
    [string]$ReportDir = (Join-Path $PSScriptRoot '..\reports'),
    [string]$AdminPrefix = 'adm-'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$outDir = Join-Path $ReportDir (Get-Date -Format 'yyyy-MM-dd')
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$now     = Get-Date
$cutoff  = $now.AddDays(-$StaleDays)
$newGrace = $now.AddDays(-$NewAccountGraceDays)

$props = 'SamAccountName', 'Enabled', 'LastLogonDate', 'whenCreated', 'PasswordNeverExpires',
         'PasswordLastSet', 'Department', 'MemberOf', 'DistinguishedName', 'AccountNotDelegated', 'employeeID'
$users = Get-ADUser -Filter * -Properties $props |
    Where-Object { $_.SamAccountName -notin @('krbtgt', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount') }

$results = [ordered]@{}

# 1. Stale accounts
$results['stale_accounts'] = $users | Where-Object {
    $_.Enabled -and (
        ($_.LastLogonDate -and $_.LastLogonDate -lt $cutoff) -or
        (-not $_.LastLogonDate -and $_.whenCreated -lt $newGrace)
    )
} | Select-Object SamAccountName, Department, LastLogonDate, whenCreated,
    @{ n = 'DaysSinceLogon'; e = { if ($_.LastLogonDate) { [int]($now - $_.LastLogonDate).TotalDays } else { 'Never' } } },
    DistinguishedName

# 2. Password never expires
$results['password_never_expires'] = $users | Where-Object { $_.Enabled -and $_.PasswordNeverExpires } |
    Select-Object SamAccountName, Department, PasswordLastSet, DistinguishedName

# 3. Privileged group membership (recursive)
$privGroups = 'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
              'Account Operators', 'Backup Operators', 'Server Operators', 'Group Policy Creator Owners'
$priv = foreach ($g in $privGroups) {
    $grp = Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue
    if (-not $grp) { continue }
    Get-ADGroupMember -Identity $grp -Recursive | Where-Object objectClass -eq 'user' | ForEach-Object {
        [pscustomobject]@{
            Group          = $g
            SamAccountName = $_.SamAccountName
            Flag           = if ($_.SamAccountName -like "$AdminPrefix*" -or $_.SamAccountName -eq 'Administrator') { '' } else { 'Non-admin account holds privilege' }
        }
    }
}
$results['privileged_members'] = $priv

# 4. Disabled accounts still in groups
$results['disabled_with_groups'] = $users | Where-Object { -not $_.Enabled -and $_.MemberOf.Count -gt 0 } |
    Select-Object SamAccountName, @{ n = 'GroupCount'; e = { $_.MemberOf.Count } },
        @{ n = 'Groups'; e = { ($_.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }) -join '; ' } },
        DistinguishedName

# 5. Department attribute vs department group membership
$results['department_mismatch'] = $users | Where-Object { $_.Enabled -and $_.Department } | ForEach-Object {
    $deptGroups = @($_.MemberOf | Where-Object { $_ -match '^CN=GG_[^,]+,' -and $_ -notmatch 'ServiceDesk_Admins' } |
        ForEach-Object { (($_ -split ',')[0] -replace 'CN=GG_') })
    $expected = $_.Department
    if ($deptGroups -notcontains $expected -or $deptGroups.Count -gt 1) {
        [pscustomobject]@{
            SamAccountName   = $_.SamAccountName
            Department       = $expected
            DeptGroupsHeld   = $deptGroups -join '; '
            Issue            = if ($deptGroups -notcontains $expected) { 'Missing own department group' } else { 'Holds extra department group(s)' }
        }
    }
}

# 6. Admin accounts that can be delegated
$results['admin_delegatable'] = $users | Where-Object {
    $_.Enabled -and $_.SamAccountName -like "$AdminPrefix*" -and -not $_.AccountNotDelegated
} | Select-Object SamAccountName, DistinguishedName

# --- Output ----------------------------------------------------------------
Write-Host "`nAccess review $(Get-Date -Format 'yyyy-MM-dd HH:mm')  (stale threshold: $StaleDays days)`n"
foreach ($key in $results.Keys) {
    $data  = @($results[$key])
    $file  = Join-Path $outDir "$key.csv"
    if ($data.Count -gt 0) { $data | Export-Csv -Path $file -NoTypeInformation }
    $count = if ($key -eq 'privileged_members') { @($data | Where-Object Flag).Count } else { $data.Count }
    $label = if ($key -eq 'privileged_members') { "$key (flagged)" } else { $key }
    $color = if ($count -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ('{0,-34} {1,4}' -f $label, $count) -ForegroundColor $color
}
Write-Host "`nReports written to $outDir"
