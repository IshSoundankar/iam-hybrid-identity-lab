# TKT-002: Group membership changed but access did not follow

| Field | Value |
|---|---|
| Reported by | ciaran.walsh (moved Finance to Claims) |
| Category | Access |
| Date | 2026-10-06 |
| Status | Resolved |
| Skills shown | Access tokens, Kerberos, mover risk, AGDLP troubleshooting |

## Scenario
This came up live during the Phase 2 mover test, not as a planted fault. Ciaran was moved from Finance to Claims by the JML script while he was still signed in on WS01.

## Symptom
After the mover change in AD, Ciaran's existing session:
- still had access to `\\DC01\Finance$`, which should have been removed
- was still denied `\\DC01\Claims$`, which should have been granted

## Investigation

**1. What AD says** (DC01):
```
SamAccountName : ciaran.walsh
Department     : Claims
Groups         : GG_Claims
```
The change was applied correctly.

**2. What Ciaran's session says** (WS01, same session, no logoff):
```
PS C:\Users\ciaran.walsh> whoami /groups | findstr /i "GG_ DL_"
LAB\GG_Finance            Group   ...
LAB\DL_Share_Finance_RW   Alias   ...
PS C:\Users\ciaran.walsh> Get-ChildItem '\\DC01\Finance$'
ciaran-test.txt
PS C:\Users\ciaran.walsh> Get-ChildItem '\\DC01\Claims$'
Get-ChildItem : Access to the path '\\DC01\Claims$' is denied.
```
AD and the session disagree.

## Root cause
Windows reads a user's group memberships once, at logon, into an access token (and into the Kerberos ticket from the DC). Changes made in AD afterwards do not alter a token that already exists. Ciaran's open SMB connection to DC01 also kept using that token, so the file server kept making decisions on his old groups.

## Resolution
Ciaran signed out and back in. The new logon built a fresh token from current AD membership:
```
PS C:\Users\ciaran.walsh> whoami /groups | findstr /i "GG_ DL_"
LAB\GG_Claims              Group   ...
LAB\DL_Share_Claims_RW     Alias   ...
PS C:\Users\ciaran.walsh> Get-ChildItem '\\DC01\Claims$'
PS C:\Users\ciaran.walsh> Get-ChildItem '\\DC01\Finance$'
Get-ChildItem : Access to the path '\\DC01\Finance$' is denied.
```

![Ciaran after move](../docs/screenshots/12-ciaran-after-move.png)

Alternatives to a full logoff: `klist purge` followed by reconnecting to the share, or simply waiting for the Kerberos ticket to expire (10 hours by default).

## Why it matters
This works in both directions:
- **New access** (a joiner or mover gaining a group) does not appear until the user re-authenticates, which generates "I was added but still get access denied" tickets.
- **Removed access** (a mover losing a group, or a leaver) is not cut off for a session that is already open. A leaver who is still signed in keeps their access until their session ends.

## Prevention
- Tell movers to sign out and back in after a change, and include this step in the service desk script for "added but still denied" calls.
- For leavers, especially urgent ones, disable the account **and** force sign-out of active sessions (and, in Entra ID, revoke sessions and refresh tokens), rather than relying on disabling alone.

## Related
Build log, Phase 2, Findings 1 and 2. Finding 2 records a separate anomaly: a new logon shortly after DC01 recovered from an unclean shutdown still carried the old groups; a later fresh logon was correct.
