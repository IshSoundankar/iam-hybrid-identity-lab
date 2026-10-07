<#
.SYNOPSIS
    Builds the lab's directory structure: OUs, AGDLP groups and department file shares.

.DESCRIPTION
    Run once on the domain controller after AD DS is installed and the domain is up.
    Safe to re-run: existing objects are skipped, not duplicated.

    Access model (AGDLP):
      Accounts -> Global groups (GG_<Dept>) -> Domain Local groups (DL_Share_<Dept>_RW)
      -> NTFS permissions on \\<server>\<Dept>$
    Users never receive permissions directly.

.EXAMPLE
    .\Setup-LabStructure.ps1 -WhatIf
    .\Setup-LabStructure.ps1 -ShareRoot 'C:\Shares'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Departments = @('IT', 'HR', 'Finance', 'Claims'),
    [string]$ShareRoot = 'C:\Shares'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
$netbios  = $domain.NetBIOSName
$labRoot  = "OU=Lab,$domainDN"

function New-LabOU {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-Verbose "OU exists: $dn"
    }
    elseif ($PSCmdlet.ShouldProcess($dn, 'Create OU')) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Host "Created OU $dn"
    }
    return $dn
}

function New-LabGroup {
    param([string]$Name, [string]$Scope, [string]$Path, [string]$Description)
    if (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) {
        Write-Verbose "Group exists: $Name"
    }
    elseif ($PSCmdlet.ShouldProcess($Name, "Create $Scope security group")) {
        New-ADGroup -Name $Name -GroupScope $Scope -GroupCategory Security -Path $Path -Description $Description
        Write-Host "Created group $Name ($Scope)"
    }
}

# --- OU structure ---------------------------------------------------------
New-LabOU -Name 'Lab' -Path $domainDN | Out-Null
$usersOU    = New-LabOU -Name 'Users'            -Path $labRoot
$groupsOU   = New-LabOU -Name 'Groups'           -Path $labRoot
$adminsOU   = New-LabOU -Name 'Admins'           -Path $labRoot
$svcOU      = New-LabOU -Name 'Service Accounts' -Path $labRoot
$disabledOU = New-LabOU -Name 'Disabled Users'   -Path $labRoot
$null = New-LabOU -Name 'Workstations' -Path $labRoot

foreach ($dept in $Departments) {
    New-LabOU -Name $dept -Path $usersOU | Out-Null
}

# --- Groups and nesting (AGDLP) -------------------------------------------
foreach ($dept in $Departments) {
    $gg   = "GG_$dept"
    $dlRW = "DL_Share_${dept}_RW"
    $dlRO = "DL_Share_${dept}_RO"

    New-LabGroup -Name $gg   -Scope Global      -Path $groupsOU -Description "All staff in $dept"
    New-LabGroup -Name $dlRW -Scope DomainLocal -Path $groupsOU -Description "Modify access to $dept share"
    New-LabGroup -Name $dlRO -Scope DomainLocal -Path $groupsOU -Description "Read access to $dept share"

    if ($PSCmdlet.ShouldProcess("$gg -> $dlRW", 'Nest global group into domain local group')) {
        $members = Get-ADGroupMember -Identity $dlRW -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
        if ($members -notcontains $gg) { Add-ADGroupMember -Identity $dlRW -Members $gg }
    }
}

# Admin tier group, kept separate from Domain Admins
New-LabGroup -Name 'GG_IT_ServiceDesk_Admins' -Scope Global -Path $groupsOU -Description 'Delegated password reset / unlock rights'

# --- Department shares ----------------------------------------------------
foreach ($dept in $Departments) {
    $path      = Join-Path $ShareRoot $dept
    $shareName = "$dept`$"   # hidden share
    $dlRW      = "$netbios\DL_Share_${dept}_RW"
    $dlRO      = "$netbios\DL_Share_${dept}_RO"

    if (-not (Test-Path $path) -and $PSCmdlet.ShouldProcess($path, 'Create folder')) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue) -and
        $PSCmdlet.ShouldProcess($shareName, 'Create SMB share')) {
        # Share-level: authenticated users change; real control is NTFS
        New-SmbShare -Name $shareName -Path $path -ChangeAccess 'Authenticated Users' -FullAccess 'Administrators' | Out-Null
        Write-Host "Created share \\$env:COMPUTERNAME\$shareName"
    }

    if ($PSCmdlet.ShouldProcess($path, 'Set NTFS permissions')) {
        $acl = Get-Acl $path
        $acl.SetAccessRuleProtection($true, $false)   # break inheritance, drop inherited ACEs
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        $prop    = [System.Security.AccessControl.PropagationFlags]::None
        $rules = @(
            New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators', 'FullControl', $inherit, $prop, 'Allow')
            New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM',    'FullControl', $inherit, $prop, 'Allow')
            New-Object System.Security.AccessControl.FileSystemAccessRule($dlRW, 'Modify',         $inherit, $prop, 'Allow')
            New-Object System.Security.AccessControl.FileSystemAccessRule($dlRO, 'ReadAndExecute', $inherit, $prop, 'Allow')
        )
        foreach ($r in $rules) { $acl.AddAccessRule($r) }
        Set-Acl -Path $path -AclObject $acl
        Write-Host "NTFS set on $path"
    }
}

Write-Host "`nDone. Users go in: $usersOU\<Dept>. Leavers go in: $disabledOU"
