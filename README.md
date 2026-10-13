# pwsh-toolbox

A collection of PowerShell scripts for managing Windows endpoints and networks.
They contain no environment-specific data, so you can download them and run them anywhere.

## Layout

Scripts are grouped by what they manage. When a script could fit in two folders, it goes in the folder for its main target.

| Folder | Scope |
|---|---|
| `Network/`  | Firewall, DNS, DHCP, Wi-Fi, VPN, connectivity |
| `Security/` | Defender, BitLocker, auditing, hardening, certificates |
| `Devices/`  | Bluetooth, printers, USB, drivers, peripherals |
| `System/`   | OS configuration, Windows Update, services, scheduled tasks, cleanup |
| `Identity/` | Active Directory, local users/groups, Entra ID |
| `Cloud/`    | Microsoft 365, Exchange Online, Intune, Azure |
| `Storage/`  | Disks, file shares, permissions, backup |

## Scripts

| Script | Description |
|---|---|
| [`Devices/Remove-BluetoothPairing.ps1`](Devices/Remove-BluetoothPairing.ps1) | Unpairs all paired Bluetooth devices (Classic and LE), with name exclusions and a CSV audit log. Requires Windows PowerShell 5.1. |
| [`Network/Block-FolderOutboundTraffic.ps1`](Network/Block-FolderOutboundTraffic.ps1) | Creates and maintains outbound block firewall rules for every .exe in a folder. Idempotent and self-healing, with prune/rollback and an audit log. |

## Conventions

- Script names follow `Verb-Noun.ps1` and use an [approved verb](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands) (`Get-Verb`) with a singular noun.
- Every script has comment-based help: `Get-Help .\Script.ps1 -Full`
- Scripts that change anything support `-WhatIf` / `-Confirm`.

## Usage

Downloaded scripts may be blocked by your execution policy. Review the script first, then unblock it:

```powershell
Unblock-File .\Network\Block-FolderOutboundTraffic.ps1
```

## License

[MIT](LICENSE)
