# TKT-001: Account keeps locking out

| Field | Value |
|---|---|
| Reported by | aoife.byrne (Claims) |
| Category | Authentication |
| Date | 2026-10-07 |
| Status | Resolved |
| Resolved by | sean.murphy (Service Desk, delegated rights) |
| Skills shown | Lockout tracing, Kerberos failure codes, event log analysis, least-privilege resolution |

## Scenario
A device on the network kept trying Aoife's account with an old password, as happens when a mapped drive, phone mail profile, scheduled task or service still holds a credential from before a password change. This was simulated from WS01 by repeatedly connecting to `\\DC01\Claims$` as `LAB\aoife.byrne` with a wrong password (`net use` returned System error 86, "the specified network password is not correct").

## Symptom
Aoife's account is locked and she cannot sign in.

## Investigation

**1. Confirm the lockout**
```
SamAccountName LockedOut badPwdCount
-------------- --------- -----------
aoife.byrne         True           5
```
Five bad passwords matches the domain lockout threshold set in Phase 3.

**2. Find the source with `Find-LockoutSource.ps1`**

Lockouts are recorded as event 4740 on the PDC emulator, whose "Caller Computer Name" identifies the machine that sent the bad passwords. The script also pulls the failed Kerberos (4771) and NTLM (4776) authentications that led up to it.

```
Lockout events (4740):
Time                 Account     CallerComputer
10/7/2026 1:39:44 AM aoife.byrne WS01

Failed authentications (4771 Kerberos / 4776 NTLM) on the PDC:
Time                 EventID Source        Status
10/7/2026 1:37:21 AM    4771 192.168.50.20 0x18
10/7/2026 1:37:59 AM    4771 192.168.50.20 0x18
10/7/2026 1:38:23 AM    4771 192.168.50.20 0x18
10/7/2026 1:38:49 AM    4771 192.168.50.20 0x18
10/7/2026 1:39:44 AM    4771 192.168.50.20 0x18
10/7/2026 1:40:59 AM    4771 192.168.50.20 0x12
10/7/2026 1:40:59 AM    4771 192.168.50.20 0x12
```

![Lockout traced](../docs/screenshots/23-lockout-traced.png)

**3. Read the evidence**
| Evidence | Meaning |
|---|---|
| Caller computer `WS01`, source IP `192.168.50.20` | Every failure came from one machine, so this is a stale credential on a device, not someone guessing from many places |
| Five `0x18` failures, the fifth at the same second as the lockout | `0x18` is Kerberos "pre-authentication failed" (bad password). Five failures crossed the threshold |
| Two `0x12` failures after the lockout | `0x12` is "client credentials revoked" (account locked). The device carried on retrying after the account locked, which is typical of an automated source rather than a person |

## Root cause
A process on WS01 was authenticating as Aoife with an out-of-date password and retrying automatically.

## Resolution
1. **Remove the source first**, otherwise the account locks again as soon as it is unlocked. Here the source was the test loop, which had already stopped; a failed `net use` stores no connection or credential, so there was nothing left on WS01 to clear. On a real device: check `net use`, `cmdkey /list` (Credential Manager), services and scheduled tasks running as the user, and mobile mail profiles.
2. **Unlock using the delegated service desk account**, not Domain Admin:
   ```powershell
   Unlock-ADAccount aoife.byrne -Credential $seanCred
   ```
3. **Verify** and confirm the audit trail:
   ```
   SamAccountName LockedOut badPwdCount
   aoife.byrne        False           0

   TimeCreated          Unlocked    UnlockedBy
   10/7/2026 1:52:49 AM aoife.byrne sean.murphy
   ```
   Event 4767 records the unlock against the named service desk analyst.

## Prevention
- Users should update saved credentials on all devices (phone mail, mapped drives) immediately after a password change.
- Alert on repeated lockouts of the same account from the same caller computer; this is covered by Wazuh rules 100103 and 100110 in Phase 5.
- Avoid running services or scheduled tasks as personal user accounts; use managed service accounts instead.

## Note
The first query for the unlock event (4767) returned nothing because it ran within a second of the unlock, before the event was written. Re-running it a moment later returned the event. Audit policy for User Account Management was confirmed as Success and Failure.
