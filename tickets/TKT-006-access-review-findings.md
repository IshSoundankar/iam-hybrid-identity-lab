# TKT-006: Access review findings and remediation

| Field | Value |
|---|---|
| Category | Governance |
| Date | 2026-10-07 |
| Status | Resolved |
| Skills shown | Access review, privilege creep, leaver process gaps, risk prioritisation |

## Scenario
A periodic access review of `lab.local`. Four common real-world problems were introduced first to test whether the review catches them:

| Change made | What it simulates |
|---|---|
| `aoife.byrne` set to password never expires | A policy exemption granted to stop a user complaining |
| `sean.murphy` added to Backup Operators | Privileged access granted for a one-off job and never removed |
| `aoife.byrne` added to `GG_Finance` while in Claims | Privilege creep from another team |
| `roisin.doyle` disabled by hand | A leaver handled manually, bypassing the JML process |

## Review run
```
PS C:\IAMLab\scripts> .\Get-AccessReview.ps1 -NewAccountGraceDays 0

stale_accounts                        2
password_never_expires                2
privileged_members (flagged)          1
disabled_with_groups                  1
department_mismatch                   1
admin_delegatable                     0
```
`-NewAccountGraceDays 0` disables the normal 14-day grace period for never-used accounts, so the lab's new accounts are included.

![Access review findings](../docs/screenshots/20-access-review-findings.png)

## Findings
| Check | Account(s) | Planted? | Risk | Action taken |
|---|---|---|---|---|
| Privileged (flagged) | `sean.murphy` in Backup Operators | Yes | High: can back up and read any file on the DC, including the AD database | Removed from Backup Operators |
| Disabled with groups | `roisin.doyle` still in `GG_Claims` | Yes | Medium: access returns if the account is re-enabled | Processed through the JML leaver (prior groups recorded, groups removed, moved to Disabled Users) |
| Department mismatch | `aoife.byrne` in Claims holding `GG_Finance` | Yes | Medium: access beyond role | Removed from `GG_Finance` |
| Password never expires | `aoife.byrne` | Yes | Medium | Flag removed |
| Password never expires | `Administrator` (built-in) | **No** | Medium | Flag removed (see note) |
| Stale accounts | `aoife.byrne`, `adm-ish` | No | Low: both created within the last day | No action; flagged only because the grace period was set to 0 |

**Note on the built-in Administrator:** this was a genuine finding the review surfaced without it being planted. In production the built-in Administrator is usually kept as a break-glass account, with its password held in a vault and "never expires" left on as a documented, approved exception. For the lab the flag was removed.

## Remediation
```powershell
Remove-ADGroupMember 'Backup Operators' -Members sean.murphy -Confirm:$false
Remove-ADGroupMember GG_Finance -Members aoife.byrne -Confirm:$false
Set-ADUser aoife.byrne -PasswordNeverExpires $false
Set-ADUser Administrator -PasswordNeverExpires $false
.\Invoke-JML.ps1 -CsvPath ..\data\batch3_roisin_leaver.csv
```

## Re-run after remediation
All six checks returned 0 with the normal 14-day grace period.

![Clean access review](../docs/screenshots/21-access-review-clean.png)

## Lessons
- The JML process would have prevented two of the four planted problems (Roisin's leftover group, and Aoife's extra department group would be removed on any later move). The other two (a policy exemption and an ad hoc privileged group addition) bypass JML entirely, so only a periodic review catches them.
- Fixing a manual leaver by running it back through JML is better than just deleting the leftover group: it also records the prior access and moves the account, giving a consistent audit trail.
- The review found a real issue that was not planted, which is the reason to run reviews on a schedule rather than only when something is suspected.
