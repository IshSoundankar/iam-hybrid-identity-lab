<#
.SYNOPSIS
    Finds which machine is locking out an account.

.DESCRIPTION
    Account lockouts are recorded as event 4740 on the PDC emulator. The event's
    "Caller Computer Name" is the machine that sent the bad passwords, which is
    usually a device with a stale saved credential (mapped drive, phone mail
    profile, scheduled task, service running as the user).

    Also pulls recent 4771 / 4776 (failed Kerberos / NTLM authentication) events
    for the user from the PDC to show the failure pattern leading up to the lockout.
    Requires "Audit Kerberos Authentication Service" and "Audit Credential Validation"
    failure auditing on the domain controllers (see docs/SETUP.md, Phase 3).

.EXAMPLE
    .\Find-LockoutSource.ps1 -User aoife.byrne
    .\Find-LockoutSource.ps1 -User aoife.byrne -Hours 72
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$User,
    [int]$Hours = 24
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$pdc   = (Get-ADDomain).PDCEmulator
$since = (Get-Date).AddHours(-$Hours)

$acct = Get-ADUser -Identity $User -Properties LockedOut, badPwdCount, LastBadPasswordAttempt, AccountLockoutTime
Write-Host "`nAccount : $($acct.SamAccountName)"
Write-Host "Locked  : $($acct.LockedOut)   badPwdCount: $($acct.badPwdCount)   Last bad pwd: $($acct.LastBadPasswordAttempt)"
Write-Host "PDC     : $pdc`n"

function Get-EventData {
    param($Event)
    $xml = [xml]$Event.ToXml()
    $data = @{}
    foreach ($d in $xml.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    return $data
}

# 4740: account locked out
$lockouts = Get-WinEvent -ComputerName $pdc -FilterHashtable @{ LogName = 'Security'; Id = 4740; StartTime = $since } -ErrorAction SilentlyContinue |
    ForEach-Object {
        $d = Get-EventData $_
        if ($d.TargetUserName -eq $acct.SamAccountName) {
            [pscustomobject]@{
                Time           = $_.TimeCreated
                Account        = $d.TargetUserName
                CallerComputer = $d.TargetDomainName   # field name is misleading; this holds the caller computer
            }
        }
    }

if ($lockouts) {
    Write-Host "Lockout events (4740):" -ForegroundColor Yellow
    $lockouts | Format-Table -AutoSize
    $top = $lockouts | Group-Object CallerComputer | Sort-Object Count -Descending | Select-Object -First 1
    Write-Host "Most likely source: $($top.Name) ($($top.Count) lockout(s))" -ForegroundColor Yellow
}
else {
    Write-Host "No 4740 events for $User in the last $Hours hours on $pdc." -ForegroundColor Green
}

# Failed authentications seen by the DC. A bad password typed on a workstation shows
# up on the DC as 4771 (Kerberos pre-auth failed) or 4776 (NTLM), not 4625.
# 4625 on the DC only covers logons to the DC itself.
$failures = Get-WinEvent -ComputerName $pdc -FilterHashtable @{ LogName = 'Security'; Id = 4771, 4776; StartTime = $since } -ErrorAction SilentlyContinue |
    ForEach-Object {
        $d = Get-EventData $_
        if ($d.TargetUserName -eq $acct.SamAccountName -or $d.TargetUserName -like "$($acct.SamAccountName)@*") {
            [pscustomobject]@{
                Time     = $_.TimeCreated
                EventID  = $_.Id
                Source   = if ($_.Id -eq 4771) { ($d.IpAddress -replace '^::ffff:') } else { $d.Workstation }
                Status   = $d.Status   # 4771: 0x18 = bad password.  4776: 0xC000006A = bad password, 0xC0000234 = locked
            }
        }
    } | Where-Object { $_.Status -notin @('0x0', '0x00000000') }

if ($failures) {
    Write-Host "`nFailed authentications (4771 Kerberos / 4776 NTLM) on the PDC:" -ForegroundColor Yellow
    $failures | Sort-Object Time | Format-Table -AutoSize
}

Write-Host "`nNext steps: check the source machine for saved credentials (Credential Manager,"
Write-Host "mapped drives, services, scheduled tasks), fix it, then unlock with:"
Write-Host "  Unlock-ADAccount -Identity $($acct.SamAccountName)"
