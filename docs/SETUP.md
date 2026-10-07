# Setup Guide

Build order matters: each phase depends on the one before it. Take screenshots as you go (save them in `docs/screenshots/`), because the evidence is what makes the repo credible.

## Requirements

| Item | Detail |
|---|---|
| Host | 16 GB RAM recommended (DC 4 GB, client 4 GB, existing Wazuh VM) |
| Hypervisor | VirtualBox or Hyper-V |
| DC | Windows Server 2022 Evaluation ISO (free, 180 days) |
| Client | Windows 10/11 Enterprise Evaluation ISO (free, 90 days). Home edition cannot join a domain. |
| Cloud | Okta Integrator Free Plan (Phase 4) |
| SIEM | Your existing Wazuh manager |

## Network

Put the DC, client and Wazuh manager on one VirtualBox NAT Network (`IAMLab`, 192.168.50.0/24, DHCP off) so they reach each other and the internet.

| Host | IP | Notes |
|---|---|---|
| DC01 | 192.168.50.10 | Static IP, DNS = 127.0.0.1 |
| WS01 | 192.168.50.20 | DNS = 192.168.50.10 (must point at the DC or the domain join fails) |
| Wazuh | 192.168.50.30 | Existing lab |

---

## Phase 1: Domain and directory structure

1. Install Windows Server 2022 (Desktop Experience). Rename to `DC01`, set the static IP, reboot.
2. Install AD DS and promote:
   ```powershell
   Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
   Install-ADDSForest -DomainName 'lab.local' -DomainNetbiosName 'LAB' -InstallDns
   ```
3. After reboot, copy this repo to the DC and run:
   ```powershell
   cd .\scripts
   .\Setup-LabStructure.ps1 -WhatIf     # review first
   .\Setup-LabStructure.ps1
   ```
4. Join WS01 to `lab.local` and move its computer object to `OU=Workstations,OU=Lab`.

**Evidence to capture:** ADUC showing the OU tree; group nesting (`GG_Finance` member of `DL_Share_Finance_RW`); NTFS permissions on one share.

## Phase 2: Joiner / Mover / Leaver

```powershell
.\Invoke-JML.ps1 -CsvPath ..\data\hr_changes.csv -WhatIf    # dry run
.\Invoke-JML.ps1 -CsvPath ..\data\hr_changes.csv
```

Then verify the outcomes yourself rather than trusting the log:

- Log on to WS01 as a joiner with the temp password: forced password change, can open their department share, cannot open others.
- The mover (`ciaran.walsh`) can open `\\DC01\Claims$` and is denied `\\DC01\Finance$` after logging off and on again.
- The leaver (`niamh.kelly`) cannot log on, sits in `Disabled Users`, and the description holds her prior groups.

Edit the CSV and run it again with your own scenarios (a duplicate name, a department that does not exist, a mover with no account) to show the error handling works.

**Evidence:** the `logs/jml_*.log` file, before/after group membership, the denied-access message.

## Phase 3: Policy and privileged access

1. **Password and lockout policy** (Default Domain Policy, Computer Config > Policies > Windows Settings > Security Settings > Account Policies):
   - Minimum length 12, complexity on, history 24
   - Lockout threshold 5, duration 15 min, reset counter after 15 min
2. **Fine-grained password policy** for admins (stricter than users):
   ```powershell
   New-ADGroup -Name 'GG_Tier0_Admins' -GroupScope Global -Path 'OU=Groups,OU=Lab,DC=lab,DC=local'
   New-ADFineGrainedPasswordPolicy -Name 'PSO_Admins' -Precedence 10 -MinPasswordLength 16 `
     -ComplexityEnabled $true -LockoutThreshold 3 -LockoutDuration '00:30:00' `
     -LockoutObservationWindow '00:30:00' -MaxPasswordAge '90.00:00:00' -PasswordHistoryCount 24
   Add-ADFineGrainedPasswordPolicySubject -Identity 'PSO_Admins' -Subjects 'GG_Tier0_Admins'
   ```
3. **Separate admin account**: create `adm-ish` in `OU=Admins`, add it to `Domain Admins` and `GG_Tier0_Admins`, tick "Account is sensitive and cannot be delegated". Your daily account (`ish`) stays a normal user.
4. **Delegated helpdesk rights**: in ADUC, right-click `OU=Users,OU=Lab` > Delegate Control > give `GG_IT_ServiceDesk_Admins` "Reset user passwords and force password change at next logon". Test that a member can reset a password but cannot add anyone to a group.
5. **Audit policy** (Default Domain Controllers Policy > Advanced Audit Policy Configuration), Success and Failure for:
   - Account Logon: Credential Validation, Kerberos Authentication Service
   - Account Management: User Account Management, Security Group Management
   - Logon/Logoff: Logon, Account Lockout

   Then `gpupdate /force` and confirm with `auditpol /get /category:*`.

**Evidence:** `Get-ADUserResultantPasswordPolicy adm-ish`; the delegation test (allowed reset, denied group change).

## Phase 4: Cloud identity (Okta)

1. Sign up for the **Okta Integrator Free Plan** at developer.okta.com/signup (up to 10 users, no expiry if used at least every 90 days; needs a non-free email domain).
2. On DC01, in the Okta admin console: **Directory > Directory Integrations > Add Active Directory**, download the agent and install it:
   - Domain `lab.local`, no SSL (no DC certificate in the lab)
   - **Create or use the OktaService account** (12+ character password; avoid the account name in it)
   - Activate with the device code at `https://<org>.okta.com/activate`
3. Scope the import: users from **only** `OU=Users,OU=Lab`, groups from `OU=Groups,OU=Lab`, username format **UPN**. Leave Okta-to-AD provisioning disabled.
4. **Import > Import Now > Full import**, select all, **Confirm Assignments**.
5. Test delegated authentication: sign in at `https://<org>.okta.com` as an AD user with their AD password; Okta Verify enrolment is required.
6. Sign-on policy: **Security > Networks** add IP zone `Corporate-Office`; **Security > Global Session Policy** add a policy for `GG_IT_ServiceDesk_Admins` with a rule: IP **not in** `Corporate-Office` > Access **Denied**. Test and investigate with **Reports > System Log** (TKT-005).

7. SAML SSO: **Applications > Browse App Catalog** > *RSA SAML Test Service Provider*. Assign it to `GG_Claims`. Check the app's **Sign On > User authentication** policy against the authenticators users actually have (TKT-007). Test from a Claims user's dashboard, then confirm a non-Claims user is refused.

**Evidence:** agent running, import review, users active, MFA enrolment prompt, System Log DENY event, SAML attributes received, unassigned user denied.

## Phase 5: Monitoring with Wazuh

1. Install the Wazuh agent on DC01 pointing at your manager. The default agent config already collects the Security event channel.
2. Copy `wazuh/iam_rules.xml` to `/var/ossec/etc/rules/` on the manager and restart `wazuh-manager`.
3. Generate each event and confirm the alert:

| Action | Event | Rule |
|---|---|---|
| Run JML joiner | 4720 | 100100 |
| Run JML leaver | 4725 | 100101 |
| Helpdesk password reset | 4724 | 100102 |
| 5 bad passwords on WS01 | 4771 x5, 4740 | 100104, 100110, 100103 |
| Add a user to Domain Admins | 4728 | 100120, 100121 |
| Same, after 7 pm | 4728 | 100122 |

If an alert does not fire, paste the raw event into `/var/ossec/bin/wazuh-logtest` and see which rule (if any) it matches. Writing up that debugging is a good ticket in itself.

**Evidence:** a Wazuh dashboard screenshot per rule.

## Phase 6: Break-fix tickets

Work through each file in `tickets/`. Break it, investigate as if you did not know the cause, fix it, then write up what you saw. Fill in the evidence sections with your own output and screenshots.

Finish by running the access review and fixing what it finds:
```powershell
.\Get-AccessReview.ps1
```
To give it something to find, first create a stale test account, set `PasswordNeverExpires` on another, and leave a disabled account in a group.
