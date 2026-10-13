#Requires -Version 5.1
<#
.SYNOPSIS
    Unpairs all paired Bluetooth devices (Classic and LE) using the built-in Windows pairing API.

.DESCRIPTION
    Enumerates paired devices via Windows.Devices.Enumeration (WinRT), unpairs each through
    DeviceInformationPairing.UnpairAsync(), and writes a CSV audit log. No third-party modules,
    no downloads. Pairing keys are removed cleanly, the same as "Remove device" in Settings.

.PARAMETER ExcludeName
    Wildcard name patterns to keep paired (e.g. your keyboard/mouse).

.PARAMETER LogPath
    CSV audit log path for this run. Not written under -WhatIf.
    Default (elevated):     $env:ProgramData\pwsh-toolbox\Logs\Remove-BluetoothPairing\Remove-BluetoothPairing_<timestamp>.csv
    Default (not elevated): $env:LOCALAPPDATA\pwsh-toolbox\Logs\Remove-BluetoothPairing\Remove-BluetoothPairing_<timestamp>.csv

.PARAMETER LogRetentionDays
    Delete this script's logs older than this many days from the log folder. 0 = keep all. Default: 90.

.EXAMPLE
    .\Remove-BluetoothPairing.ps1 -WhatIf
    .\Remove-BluetoothPairing.ps1 -ExcludeName 'MX Keys*','MX Master*' -Confirm:$false

.NOTES
    Must run in Windows PowerShell 5.1 (powershell.exe). PowerShell 7 does not include the WinRT projection.
    Exit code 0 = all succeeded, 1 = one or more failures.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$ExcludeName = @(),
    [string]$LogPath,

    [ValidateRange(0, 3650)]
    [int]$LogRetentionDays = 90
)

$ErrorActionPreference = 'Stop'

# ---- pwsh-toolbox standard logging v1: keep this block identical in every script ----

function Protect-ToolboxFolder {
    # Owner = Administrators; access = Administrators + SYSTEM only; children inherit.
    # (ProgramData lets standard users create and modify files by default.)
    param([Parameter(Mandatory)][string]$Path)
    $allowed = 'S-1-5-32-544', 'S-1-5-18'   # BUILTIN\Administrators, NT AUTHORITY\SYSTEM
    if (Test-Path -LiteralPath $Path) {
        $acl   = Get-Acl -LiteralPath $Path
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        $other = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
            Where-Object { $_.IdentityReference.Value -notin $allowed })
        if ($acl.AreAccessRulesProtected -and $owner -in $allowed -and $other.Count -eq 0) { return }
    } else {
        New-Item -ItemType Directory -Path $Path -Force -WhatIf:$false | Out-Null
    }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($allowed[0])))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $allowed) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sid)),
            'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -WhatIf:$false
}

function Initialize-ToolboxLog {
    # Returns the CSV log path for this run and makes sure its folder exists.
    # Default: <ProgramData|LocalAppData>\pwsh-toolbox\Logs\<ScriptName>\<ScriptName>_<timestamp>.csv
    # (ProgramData when elevated, locked down; LocalAppData otherwise).
    # Deletes this script's logs in that folder older than RetentionDays (0 = keep all).
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$LogPath,
        [int]$RetentionDays = 90
    )
    if (-not $LogPath) {
        $isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $base = if ($isAdmin) { $env:ProgramData } else { $env:LOCALAPPDATA }
        $root = Join-Path $base 'pwsh-toolbox'
        if ($isAdmin) { Protect-ToolboxFolder -Path $root }
        $LogPath = Join-Path $root "Logs\$ScriptName\${ScriptName}_$(Get-Date -Format yyyyMMdd-HHmmss).csv"
    }
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }
    if ($RetentionDays -gt 0 -and -not $WhatIfPreference) {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $dir -Filter "${ScriptName}_*.csv" -File |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force
    }
    $LogPath
}

# ---- end pwsh-toolbox standard logging v1 ----

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this in Windows PowerShell 5.1 (powershell.exe). PowerShell 7 has no WinRT projection.'
}

# Load WinRT types
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothDevice,     Windows.Devices.Bluetooth,   ContentType = WindowsRuntime]
$null = [Windows.Devices.Bluetooth.BluetoothLEDevice,   Windows.Devices.Bluetooth,   ContentType = WindowsRuntime]

# Bridge IAsyncOperation<T> -> Task<T>
$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-WinRT {
    param($Operation, [Type]$ResultType, [int]$TimeoutMs = 30000)
    $task = $asTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait($TimeoutMs)) { throw "WinRT operation timed out after $TimeoutMs ms" }
    $task.Result
}

# Enumerate paired Classic + LE devices
$selectors = @(
    [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($true)
    [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($true)
)

$devices = foreach ($sel in $selectors) {
    Wait-WinRT ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) `
               ([Windows.Devices.Enumeration.DeviceInformationCollection])
}
$devices = @($devices | Sort-Object -Property Id -Unique)

if ($devices.Count -eq 0) {
    Write-Host 'No paired Bluetooth devices found.'
    exit 0
}

# Unpair
$results = foreach ($d in $devices) {
    $type   = if ($d.Id -like 'BluetoothLE#*') { 'LE' } else { 'Classic' }
    $status = 'Skipped'
    $detail = ''

    if ($ExcludeName | Where-Object { $d.Name -like $_ }) {
        $status = 'Excluded'
    }
    elseif ($PSCmdlet.ShouldProcess("$($d.Name) [$type]", 'Unpair Bluetooth device')) {
        try {
            $r = Wait-WinRT ($d.Pairing.UnpairAsync()) ([Windows.Devices.Enumeration.DeviceUnpairingResult])
            $status = $r.Status.ToString()   # Unpaired | AlreadyUnpaired | Failed | AccessDenied | OperationAlreadyInProgress
        }
        catch {
            $status = 'Error'
            $detail = $_.Exception.Message
        }
    }

    [pscustomobject]@{
        Time     = (Get-Date).ToString('o')
        Computer = $env:COMPUTERNAME
        User     = "$env:USERDOMAIN\$env:USERNAME"
        Name     = $d.Name
        Type     = $type
        Status   = $status
        Detail   = $detail
        Id       = $d.Id
    }
}

$results | Format-Table Name, Type, Status, Detail -AutoSize

# Audit log (skipped under -WhatIf)
if (-not $WhatIfPreference) {
    $LogPath = Initialize-ToolboxLog -ScriptName 'Remove-BluetoothPairing' -LogPath $LogPath -RetentionDays $LogRetentionDays
    $results | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
    Write-Host "Log: $LogPath"
}

$ok = 'Unpaired', 'AlreadyUnpaired', 'Excluded', 'Skipped'
if ($results | Where-Object { $_.Status -notin $ok }) { exit 1 } else { exit 0 }
