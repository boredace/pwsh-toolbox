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
- Scripts are standalone: there are no shared modules, so every script works as a single-file download.

### Logging

Scripts that write logs share a standard block (`pwsh-toolbox standard logging v1`). Copy it unchanged into each new script.

| | |
|---|---|
| Location (elevated) | `%ProgramData%\pwsh-toolbox\Logs\<ScriptName>\` |
| Location (not elevated) | `%LOCALAPPDATA%\pwsh-toolbox\Logs\<ScriptName>\` |
| File name | `<ScriptName>_<yyyyMMdd-HHmmss>.csv`, one file per run |
| Access | `%ProgramData%\pwsh-toolbox` is owned by Administrators and accessible only to Administrators and SYSTEM. Subfolders inherit this. |
| Retention | Each script deletes its own logs older than 90 days (`-LogRetentionDays`, `0` = keep all) |
| Override | `-LogPath <file.csv>` |

The script name is hardcoded in each script, so a renamed copy still logs to the same folder.

## Usage

Downloaded scripts may be blocked by your execution policy. Review the script first, then unblock it:

```powershell
Unblock-File .\Network\Block-FolderOutboundTraffic.ps1
```

## License

[MIT](LICENSE)
