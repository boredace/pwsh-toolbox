<#
.SYNOPSIS
    Creates (and maintains) outbound BLOCK firewall rules for every .exe in a folder.

.DESCRIPTION
    Windows Firewall program conditions match an exact executable path (no wildcards,
    no directory matching), so this script creates one rule per .exe and manages them
    together as a single rule Group.

    - All rules: Direction=Outbound, Action=Block, Profile=Any (Domain/Private/Public).
    - Idempotent: safe to re-run; existing correct rules are left alone.
    - Self-healing: a managed rule that was disabled or modified (action, direction,
      profile, program, remote address, protocol) is removed and recreated.
    - -Prune removes managed rules whose .exe no longer exists in the folder.
    - -Remove deletes every rule in the group (rollback).
    - Supports -WhatIf / -Confirm. Every real change is logged to a CSV that is
      ACL-restricted to Administrators and SYSTEM.
    - Exit code: 0 = OK, 1 = one or more errors, 2 = firewall/GPO warning detected.

    Rule names are deterministic (SHA-256 of the lowercased full path), so the same
    .exe always maps to the same rule name across runs and machines.

.PARAMETER Path
    Folder containing the .exe files.

.PARAMETER Recurse
    Include .exe files in subfolders.

.PARAMETER Group
    Rule group name. Defaults to "BlockOut: <full folder path>".

.PARAMETER Prune
    Remove managed rules in the group for .exe files that no longer exist.

.PARAMETER Remove
    Remove all rules in the group and exit (rollback).

.PARAMETER LogPath
    CSV audit log path. Default: $env:ProgramData\FirewallBlockFolder\changes.csv

.EXAMPLE
    .\Block-FolderOutboundTraffic.ps1 -Path 'C:\Program Files\SomeApp' -Recurse -WhatIf

.EXAMPLE
    .\Block-FolderOutboundTraffic.ps1 -Path 'C:\Program Files\SomeApp' -Recurse -Prune -Verbose

.EXAMPLE
    .\Block-FolderOutboundTraffic.ps1 -Path 'C:\Program Files\SomeApp' -Remove

.EXAMPLE
    # Audit what's in place
    Get-NetFirewallRule -Group 'BlockOut: C:\Program Files\SomeApp' |
        Get-NetFirewallApplicationFilter | Select-Object Program
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Add')]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Path,

    [switch]$Recurse,

    [string]$Group,

    [Parameter(ParameterSetName = 'Add')]
    [switch]$Prune,

    [Parameter(ParameterSetName = 'Remove')]
    [switch]$Remove,

    [string]$LogPath = (Join-Path $env:ProgramData 'FirewallBlockFolder\changes.csv')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ---

function Get-RuleName {
    param([Parameter(Mandatory)][string]$FullPath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($FullPath.ToLowerInvariant()))
    } finally {
        $sha.Dispose()
    }
    'BlockOut-' + (($bytes[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Initialize-Log {
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
        # Lock down: Administrators + SYSTEM only, no inheritance (ProgramData lets Users write by default)
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $prop    = [System.Security.AccessControl.PropagationFlags]::None
        foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {   # BUILTIN\Administrators, NT AUTHORITY\SYSTEM
            $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $id, 'FullControl', $inherit, $prop, 'Allow')))
        }
        Set-Acl -LiteralPath $dir -AclObject $acl -WhatIf:$false
    }
}

function Write-ChangeLog {
    param([string]$Action, [string]$Rule, [string]$Program, [string]$Detail = '')
    [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        Computer  = $env:COMPUTERNAME
        User      = "$env:USERDOMAIN\$env:USERNAME"
        Action    = $Action
        Group     = $Group
        Rule      = $Rule
        Program   = $Program
        Detail    = $Detail
    } | Export-Csv -LiteralPath $LogPath -Append -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Verbose ("{0,-8} {1} {2} {3}" -f $Action, $Rule, $Program, $Detail)
}

function New-BlockRule {
    param([string]$Name, [string]$Program, [string]$Relative)
    New-NetFirewallRule -Name $Name `
        -DisplayName "Block Out - $Relative" `
        -Description "Managed by Block-FolderOutboundTraffic.ps1. Program: $Program" `
        -Group $Group `
        -Direction Outbound -Action Block -Profile Any -Enabled True `
        -Program $Program | Out-Null
}

function Get-RuleDrift {
    # Returns a list of reasons the rule no longer matches the desired state (empty = OK)
    param($Rule, [string]$ExpectedProgram)
    $reasons = @()
    if ("$($Rule.Enabled)"   -ne 'True')     { $reasons += "Enabled=$($Rule.Enabled)" }
    if ("$($Rule.Direction)" -ne 'Outbound') { $reasons += "Direction=$($Rule.Direction)" }
    if ("$($Rule.Action)"    -ne 'Block')    { $reasons += "Action=$($Rule.Action)" }
    if ("$($Rule.Profile)"   -ne 'Any')      { $reasons += "Profile=$($Rule.Profile)" }

    $app = $Rule | Get-NetFirewallApplicationFilter
    if ($app.Program -ne $ExpectedProgram)   { $reasons += "Program=$($app.Program)" }

    # Narrowing the scope (address/protocol) would make the block ineffective
    $addr = $Rule | Get-NetFirewallAddressFilter
    if (@($addr.RemoteAddress) -join ',' -ne 'Any') { $reasons += "RemoteAddress=$(@($addr.RemoteAddress) -join ',')" }
    $port = $Rule | Get-NetFirewallPortFilter
    if ("$($port.Protocol)" -ne 'Any')       { $reasons += "Protocol=$($port.Protocol)" }

    , $reasons
}

# ------------------------------------------------------------------- main ---

$root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
if ($root -like '\\*') {
    Write-Warning "Path is a UNC share. Firewall program conditions apply to local paths; rules may not match as expected."
}
if (-not $Group) { $Group = "BlockOut: $root" }

Initialize-Log

$exitCode = 0
$stats = [ordered]@{ Found = 0; Created = 0; Repaired = 0; Unchanged = 0; Pruned = 0; Removed = 0; Errors = 0 }

# Sanity check: rules are useless if the firewall is off or GPO ignores local rules
$activeProfiles = Get-NetFirewallProfile -PolicyStore ActiveStore
foreach ($p in $activeProfiles) {
    if ("$($p.Enabled)" -ne 'True') {
        Write-Warning "Firewall profile '$($p.Name)' is DISABLED; rules will have no effect on that profile."
        $exitCode = 2
    }
    if ("$($p.AllowLocalFirewallRules)" -eq 'False') {
        Write-Warning "Profile '$($p.Name)': GPO sets AllowLocalFirewallRules=False; local rules are IGNORED. Deploy via GPO instead."
        $exitCode = 2
    }
}

$existing = @{}
Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue | ForEach-Object { $existing[$_.Name] = $_ }

# ---- Remove (rollback) mode ----
if ($Remove) {
    foreach ($r in $existing.Values) {
        $prog = ($r | Get-NetFirewallApplicationFilter).Program
        if ($PSCmdlet.ShouldProcess("$($r.Name) ($prog)", 'Remove firewall rule')) {
            try {
                $r | Remove-NetFirewallRule
                Write-ChangeLog -Action 'Removed' -Rule $r.Name -Program $prog
                $stats.Removed++
            } catch {
                Write-Error "Failed to remove $($r.Name): $_" -ErrorAction Continue
                $stats.Errors++
            }
        }
    }
    [pscustomobject]$stats
    if ($stats.Errors) { exit 1 } else { exit $exitCode }
}

# ---- Add / maintain mode ----
$exes = @(Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -Recurse:$Recurse -Force -ErrorAction SilentlyContinue)
$stats.Found = $exes.Count
if ($exes.Count -eq 0) { Write-Warning "No .exe files found under '$root'." }

$desired = @{}
foreach ($exe in $exes) {
    $full = $exe.FullName
    $name = Get-RuleName -FullPath $full
    $rel  = $full.Substring($root.Length).TrimStart('\')
    if (-not $rel) { $rel = $exe.Name }
    $rel  = (Split-Path -Leaf $root) + '\' + $rel
    $desired[$name] = $full

    try {
        if ($existing.ContainsKey($name)) {
            $drift = Get-RuleDrift -Rule $existing[$name] -ExpectedProgram $full
            if ($drift.Count -eq 0) {
                $stats.Unchanged++
                continue
            }
            if ($PSCmdlet.ShouldProcess("$name ($full)", "Repair drifted rule [$($drift -join '; ')]")) {
                Remove-NetFirewallRule -Name $name
                New-BlockRule -Name $name -Program $full -Relative $rel
                Write-ChangeLog -Action 'Repaired' -Rule $name -Program $full -Detail ($drift -join '; ')
                $stats.Repaired++
            }
        } else {
            if ($PSCmdlet.ShouldProcess("$name ($full)", 'Create outbound block rule (all profiles)')) {
                New-BlockRule -Name $name -Program $full -Relative $rel
                Write-ChangeLog -Action 'Created' -Rule $name -Program $full
                $stats.Created++
            }
        }
    } catch {
        Write-Error "Failed for '$full': $_" -ErrorAction Continue
        $stats.Errors++
    }
}

if ($Prune) {
    foreach ($name in @($existing.Keys)) {
        if ($desired.ContainsKey($name)) { continue }
        $prog = ($existing[$name] | Get-NetFirewallApplicationFilter).Program
        if ($PSCmdlet.ShouldProcess("$name ($prog)", 'Prune rule for missing executable')) {
            try {
                Remove-NetFirewallRule -Name $name
                Write-ChangeLog -Action 'Pruned' -Rule $name -Program $prog
                $stats.Pruned++
            } catch {
                Write-Error "Failed to prune $name : $_" -ErrorAction Continue
                $stats.Errors++
            }
        }
    }
}

[pscustomobject]$stats
if ($stats.Errors) { exit 1 } else { exit $exitCode }
