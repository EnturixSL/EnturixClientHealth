# Enturix Client Health

PowerShell script to detect and remediate broken SCCM / ConfigMgr clients on Windows endpoints.

## Overview

`EnturixClientHealth.ps1` runs a series of health checks against the SCCM client on the local machine. If any check fails it applies a staged repair sequence — WMI repair, policy cache reset, CCM cache clear, and a full ccmsetup.exe reinstall — then validates the result. All settings are read from an XML configuration file.

Health check logic is based on [ConfigMgrClientHealth](https://www.andersrodland.com) by Anders Rødland. Repair step logic is based on SCCMagentRepair by Biju George.

## Requirements

- Windows 10 / 11 (PowerShell 5.1)
- Must be run as **Administrator**
- `ccmsetup.exe` available at the path configured in `<ClientShare>`

## Configuration

Copy `config.xml` next to the script (or pass a custom path via `-ConfigFile`) and edit the values:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
    <ClientShare>C:\ProgramData\ClientHealth</ClientShare>
    <ClientInstallProperties>SMSSITECODE=P01 SMSMP=sccm.contoso.com</ClientInstallProperties>
    <LogPath>C:\Windows\Logs\SCCMClientHealth</LogPath>
</Configuration>
```

| Element | Required | Description |
|---|---|---|
| `<ClientShare>` | Yes | Local or UNC path to the folder containing `ccmsetup.exe` |
| `<ClientInstallProperties>` | No | Space-separated ccmsetup.exe install arguments |
| `<LogPath>` | No | Directory where the timestamped log file is written (default: `C:\EnturixClientHealth`) |

## Usage

```powershell
# Default — reads config.xml from the script directory
.\EnturixClientHealth.ps1

# Custom config file
.\EnturixClientHealth.ps1 -ConfigFile "\\server\share\EnturixClientHealth\config.xml"
```

### Exit Codes

| Code | Meaning |
|---|---|
| 0 | All checks passed, or repair completed successfully, or Task Sequence in progress (skipped) |
| 1 | Repair ran but post-repair validation found issues |
| 2 | ccmsetup.exe reinstall failed — manual intervention required |
| 3 | Configuration file missing or invalid |

## Health Checks

1. **Task Sequence guard** — exits immediately (exit 0) if a Task Sequence is running, to avoid disrupting OSD or software deployments
2. **CcmExec service** — attempts auto-start if stopped; flags for repair if it cannot start
3. **CCM SDF files** — verifies at least 7 `.sdf` database files are present in the CCM directory
4. **CcmSQLCE log** — detects ongoing database corruption via the `CcmSQLCE.log` file
5. **WMI health** — checks repository consistency (`winmgmt /verifyrepository`) and queries `Win32_ComputerSystem`
6. **SMS_Client WMI class** — verifies the `root\ccm` namespace and `SMS_Client` class are accessible
7. **Provisioning Mode** — self-remediating; clears the flag via WMI if the client is stuck

## Repair Steps

Applied in order when one or more checks fail:

1. **WMI repair** — stops WinMgmt (with force-kill fallback for stuck services), renames the corrupt repository so WinMgmt rebuilds it on restart, re-registers wbem binaries
2. **Policy cache reset** — stops CcmExec, removes SCCM policy registry keys under `HKLM:\SOFTWARE\Microsoft\CCM\CcmEval`
3. **CCM cache clear** — removes contents of `CCM\Cache`, `CCM\SystemTemp`, and `CCM\Temp`
4. **SCCM client reinstall** — re-registers system DLLs, uninstalls the existing client via `ccmsetup.exe /uninstall`, reinstalls with the properties from `<ClientInstallProperties>`

## ccmsetup.exe Caching

When all health checks pass the script copies `C:\Windows\CCMSetup\ccmsetup.exe` to `<ClientShare>` for use in future repairs. The copy is skipped if the SHA-256 hash of the source and destination match.

## Pester Tests

Unit tests are located in [`Tests\EnturixClientHealth.Tests.ps1`](Tests/EnturixClientHealth.Tests.ps1). Requires Pester 5.x.

```powershell
Import-Module Pester
Invoke-Pester .\Tests\EnturixClientHealth.Tests.ps1 -Output Detailed
```

## Contributing

Internal Enturix project. For contributions, please follow the internal development guidelines.

## Contact

For support or inquiries: [sebastian.linn@enturix.de](mailto:sebastian.linn@enturix.de)

---

&copy; Enturix — All rights reserved.

Last updated: 2026-03-12
