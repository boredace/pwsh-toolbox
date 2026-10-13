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
    CSV audit log location.

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
    [string]$LogPath = "$env:ProgramData\BtUnpair\unpair-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

$ErrorActionPreference = 'Stop'

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

# Audit log (skipped automatically under -WhatIf)
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
if (Test-Path $LogPath) { Write-Host "Log: $LogPath" }

$ok = 'Unpaired', 'AlreadyUnpaired', 'Excluded', 'Skipped'
if ($results | Where-Object { $_.Status -notin $ok }) { exit 1 } else { exit 0 }