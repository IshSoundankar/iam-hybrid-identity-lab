# TKT-003: Correct password refused

| Field | Value |
|---|---|
| Reported by | aoife.byrne (Claims) |
| Category | Authentication |
| Date | 2026-10-07 |
| Status | Resolved |
| Skills shown | Account state analysis, password policy, distinguishing look-alike authentication failures |

## Scenario
Earlier, the service desk reset Aoife's password and set "user must change password at next logon". AD treats that flag (`pwdLastSet` = 0) exactly like an expired password. Aoife then tried to reach a network resource from a session where the change-password prompt cannot appear (simulated on DC01 by authenticating to AD with her credential).

## Symptom
Aoife is certain her password is right, but she is refused:
```
PS> Get-ADUser aoife.byrne -Credential $aoife
Get-ADUser : Either the target name is incorrect or the server has rejected the client credentials.
```

## Investigation
The error is the **same generic message** returned for a wrong password, so it does not distinguish a typo from an expired password. Resetting the password on the strength of it would treat the symptom, not the cause. The account itself gives the real answer:

```
SamAccountName  : aoife.byrne
Enabled         : True
LockedOut       : False
PasswordExpired : True
PasswordLastSet :
```

| Check | Result | Rules out / confirms |
|---|---|---|
| Enabled | True | Not a disabled (leaver) account |
| LockedOut | False | Not a lockout (TKT-001) |
| PasswordExpired | True | **Cause** |
| PasswordLastSet | blank | The "must change at next logon" flag, not age-based expiry |
| `Get-ADUserResultantPasswordPolicy` | no PSO returned | Aoife is on the domain policy, not an admin PSO |

## Root cause
The account carried "must change password at next logon" from the earlier service desk reset, and Aoife's access route could not show the change prompt.

## Resolution
Aoife changed her own password using her current one (in practice via Ctrl+Alt+Del > Change a password on a domain PC, or a self-service portal). Simulated with a change operation, not an admin reset:
```powershell
Set-ADAccountPassword aoife.byrne -OldPassword <current> -NewPassword <new>
```
Verified:
```
PS> Get-ADUser aoife.byrne -Credential $aoife   (new password)
aoife.byrne

SamAccountName PasswordExpired PasswordLastSet
aoife.byrne              False 10/7/2026 1:56:05 AM
```

![Password expired investigation and fix](../docs/screenshots/25-password-expired.png)

A user change was used rather than another admin reset because a reset would set the flag again, and the user would hit the same problem.

## Prevention
- When resetting a password for someone who is remote or using RDP/VPN, tell them to complete the change on a domain-joined PC (or through self-service) before connecting remotely.
- Remind users before expiry (90 days under the domain policy) so the expiry does not catch them on a remote session.
- Service desk script: for "my password is right but it won't work", check Enabled, LockedOut and PasswordExpired before resetting anything.
