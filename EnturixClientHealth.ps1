#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Enturix SCCM Client Health — Detect and Remediate

.DESCRIPTION
    Runs ConfigMgr Client Health checks (based on ConfigMgrClientHealth by Anders Rødland)
    to determine whether the SCCM agent is broken. If broken, applies repair steps
    (based on SCCMagentRepair by Biju George) and then reinstalls the SCCM client via
    ccmsetup.exe instead of CCMRepair.exe.

    Health checks performed:
        * CcmExec service running
        * CCM local database files present (*.sdf count >= 7)
        * CCM database not corrupt (CcmSQLCE.log)
        * WMI repository consistent and SMS_Client class accessible
        * Client not stuck in Provisioning Mode

    Remediation steps (if any check fails):
        1. Repair WMI repository
        2. Reset SCCM policy cache (registry)
        3. Clear CCM cache directories
        4. Reinstall SCCM client via ccmsetup.exe (uninstall + install)

.PARAMETER ClientShare
    UNC or local path to the folder containing ccmsetup.exe.
    Example: \\sccm.contoso.com\Client$

.PARAMETER ClientInstallProperties
    ccmsetup.exe install properties passed to the installer.
    Example: SMSSITECODE=P01 SMSMP=sccm.contoso.com

.PARAMETER LogPath
    Directory where the log file is written. Defaults to C:\EnturixClientHealth.

.EXAMPLE
    .\EnturixClientHealth.ps1 -ClientShare "\\sccm.contoso.com\Client$" -ClientInstallProperties "SMSSITECODE=P01 SMSMP=sccm.contoso.com"

.NOTES
    Author: Enturix — sebastian.linn@enturix.de
    Health check logic: ConfigMgrClientHealth (Anders Rødland, https://www.andersrodland.com)
    Repair step logic: SCCMagentRepair (Biju George)
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = 'UNC path to folder containing ccmsetup.exe')]
    [string]$ClientShare,

    [Parameter(Mandatory = $false, HelpMessage = 'ccmsetup.exe install properties')]
    [string]$ClientInstallProperties = '',

    [Parameter(Mandatory = $false)]
    [string]$LogPath = 'C:\EnturixClientHealth'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$PowerShellVersion = [int]$PSVersionTable.PSVersion.Major

#region --- Logging ---

$Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile   = Join-Path $LogPath "EnturixClientHealth.$Timestamp.log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}

#endregion

#region --- Health Check Functions (logic from ConfigMgrClientHealth by Anders Rødland) ---

function Get-CCMDirectory {
    $path = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Client\Configuration\Client Properties' `
                              -Name 'Local SMS Path' -ErrorAction SilentlyContinue).'Local SMS Path'
    if (-not $path) { $path = 'C:\Windows\CCM' }
    return $path.TrimEnd('\')
}

function Get-CCMLogDirectory {
    $ccmDir = Get-CCMDirectory
    $logDir = "$ccmDir\Logs"
    if (Test-Path $logDir) { return $logDir }
    return $ccmDir
}

# Returns $false if fewer than 7 .sdf files exist (client DB missing/broken).
function Test-CcmSDF {
    $ccmDir = Get-CCMDirectory
    $files  = @(Get-ChildItem "$ccmDir\*.sdf" -ErrorAction SilentlyContinue)
    if ($files.Count -lt 7) {
        Write-Log "CcmSDF check: FAIL — only $($files.Count) SDF files found (expected >= 7)." 'WARN'
        return $false
    }
    Write-Log "CcmSDF check: OK ($($files.Count) SDF files present)."
    return $true
}

# Returns $true if CcmSQLCE.log is present and recently written (DB corruption indicator).
function Test-CcmSQLCELog {
    $logDir  = Get-CCMLogDirectory
    $logFile = "$logDir\CcmSQLCE.log"

    if (-not (Test-Path $logFile)) {
        Write-Log "CcmSQLCELog check: OK (log not present)."
        return $false
    }

    $logLevel = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@Global' `
                                  -ErrorAction SilentlyContinue).logLevel
    if ($logLevel -eq 0) {
        Write-Log "CcmSQLCELog check: skipped (client in debug mode)."
        return $false
    }

    $lastWrite = (Get-Item $logFile).LastWriteTime
    $created   = (Get-Item $logFile).CreationTime
    $now       = Get-Date

    # Bad: log was written recently but is not newly created (ongoing corruption)
    if ( (($now - $lastWrite).Days -lt 7) -and (($now - $created).Days -gt 7) ) {
        Write-Log "CcmSQLCELog check: FAIL — CcmSQLCE.log exists and was recently updated. DB corrupt." 'WARN'
        return $true
    }

    Write-Log "CcmSQLCELog check: OK."
    return $false
}

# Returns $true if WMI is broken (inconsistent repo or cannot query Win32_ComputerSystem).
function Test-WMIHealth {
    $vote   = 0
    $result = & winmgmt /verifyrepository 2>&1
    switch -Wildcard ($result) {
        '*inconsistent*'    { $vote = 100 }
        '*not consistent*'  { $vote = 100 }
        '*inkonsekvent*'    { $vote = 100 }
        '*inkonsistent*'    { $vote = 100 }
        '*epäyhtenäinen*'   { $vote = 100 }
    }

    try {
        if ($PowerShellVersion -ge 6) { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Out-Null }
        else                          { Get-WmiObject  Win32_ComputerSystem -ErrorAction Stop  | Out-Null }
    }
    catch { $vote++ }

    if ($vote -gt 0) {
        Write-Log "WMI health check: FAIL — repository inconsistent or Win32_ComputerSystem unreachable." 'WARN'
        return $true
    }
    Write-Log "WMI health check: OK."
    return $false
}

# Returns $true if CcmExec service is missing or cannot be started.
function Test-CcmExecService {
    $svc = Get-Service -Name ccmexec -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "CcmExec service check: FAIL — service not found." 'WARN'
        return $true
    }

    if ($svc.Status -ne 'Running') {
        try {
            if ($svc.StartType -ne 'Automatic') { Set-Service -Name ccmexec -StartupType Automatic }
            Start-Service -Name ccmexec -ErrorAction Stop
            Write-Log "CcmExec service check: Started service (was stopped)." 'WARN'
            return $false
        }
        catch {
            Write-Log "CcmExec service check: FAIL — service stopped and could not be started." 'WARN'
            return $true
        }
    }

    Write-Log "CcmExec service check: OK."
    return $false
}

# Returns $true if the SMS_Client WMI class is inaccessible.
function Test-CcmWMIClass {
    try {
        if ($PowerShellVersion -ge 6) { Get-CimInstance -Namespace root/ccm -ClassName SMS_Client -ErrorAction Stop | Out-Null }
        else                          { Get-WmiObject   -Namespace root/ccm -Class SMS_Client      -ErrorAction Stop | Out-Null }
        Write-Log "SMS_Client WMI class check: OK."
        return $false
    }
    catch {
        Write-Log "SMS_Client WMI class check: FAIL — cannot access root/ccm SMS_Client." 'WARN'
        # Clear CCM WMI namespace to avoid needing a full uninstall
        try { Get-WmiObject -Query "Select * from __Namespace WHERE Name='CCM'" -Namespace root -ErrorAction SilentlyContinue | Remove-WmiObject }
        catch {}
        return $true
    }
}

# Returns $true if client is stuck in Provisioning Mode.
function Test-ProvisioningMode {
    $key   = 'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec'
    $mode  = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).ProvisioningMode
    if ($mode -eq 'true') {
        Write-Log "Provisioning Mode check: FAIL — client is stuck in provisioning mode. Remediating..." 'WARN'
        Set-ItemProperty -Path $key -Name ProvisioningMode -Value 'false' -ErrorAction SilentlyContinue
        try {
            if ($PowerShellVersion -ge 6) {
                Invoke-CimMethod -Namespace 'root\ccm' -ClassName 'SMS_Client' -MethodName 'SetClientProvisioningMode' -Arguments @{bEnable=$false} | Out-Null
            }
            else {
                Invoke-WmiMethod -Namespace 'root\ccm' -Class 'SMS_Client' -Name 'SetClientProvisioningMode' -ArgumentList @($false) | Out-Null
            }
        }
        catch {}
        return $true
    }
    Write-Log "Provisioning Mode check: OK."
    return $false
}

#endregion

#region --- Repair Functions (logic from SCCMagentRepair by Biju George) ---

function Repair-WMIRepository {
    Write-Log "Repairing WMI repository..."

    Stop-Service -Name ccmexec -Force -ErrorAction SilentlyContinue
    Stop-Service -Name winmgmt -Force -ErrorAction SilentlyContinue

    # Re-register WMI binaries
    foreach ($wbemPath in @("$env:SystemRoot\System32\wbem", "$env:SystemRoot\SysWOW64\wbem")) {
        if (Test-Path $wbemPath) {
            Push-Location $wbemPath
            foreach ($bin in @('unsecapp.exe','wmiadap.exe','wmiapsrv.exe','wmiprvse.exe','scrcons.exe')) {
                if (Test-Path $bin) { & ".\$bin" /RegServer 2>&1 | Out-Null }
            }
            Pop-Location
        }
    }

    & "$env:SystemRoot\system32\wbem\winmgmt.exe" /resetrepository  | Out-Null
    & "$env:SystemRoot\system32\wbem\winmgmt.exe" /salvagerepository | Out-Null

    Start-Service -Name winmgmt -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    Write-Log "WMI repository repair complete."
}

function Reset-SCCMPolicyCache {
    Write-Log "Resetting SCCM policy cache..."

    Stop-Service -Name ccmexec -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\CCM\CcmEval\Policy',
        'HKLM:\SOFTWARE\Microsoft\CCM\CcmEval\Policy\Machine',
        'HKLM:\SOFTWARE\Microsoft\CCM\CcmEval\Policy\User',
        'HKLM:\SOFTWARE\Microsoft\CCM\CcmEval\Policy\Machine\ActualConfig',
        'HKLM:\SOFTWARE\Microsoft\CCM\CcmEval\Policy\User\ActualConfig'
    )
    foreach ($path in $registryPaths) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared registry path: $path"
        }
    }

    Write-Log "Policy cache reset complete."
}

function Clear-CCMCache {
    Write-Log "Clearing CCM cache directories..."

    Stop-Service -Name ccmexec -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    foreach ($dir in @('C:\Windows\CCM\Cache', 'C:\Windows\CCM\SystemTemp', 'C:\Windows\CCM\Temp')) {
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Log "Cleared: $dir"
        }
    }

    Write-Log "CCM cache cleared."
}

#endregion

#region --- Reinstall Function (logic from ConfigMgrClientHealth Resolve-Client by Anders Rødland) ---

function Register-DLLFiles {
    Write-Log "Re-registering system DLL files..."
    $dlls = @(
        'actxprxy.dll','atl.dll','Bitsprx2.dll','Bitsprx3.dll','browseui.dll','cryptdlg.dll',
        'dssenh.dll','gpkcsp.dll','initpki.dll','jscript.dll','mshtml.dll','msi.dll',
        'mssip32.dll','msxml.dll','msxml3.dll','msxml3a.dll','msxml3r.dll','msxml4.dll',
        'msxml4a.dll','msxml4r.dll','msxml6.dll','msxml6r.dll','muweb.dll','ole32.dll',
        'oleaut32.dll','Qmgr.dll','Qmgrprxy.dll','rsaenh.dll','sccbase.dll','scrrun.dll',
        'shdocvw.dll','shell32.dll','slbcsp.dll','softpub.dll','rlmon.dll','userenv.dll',
        'vbscript.dll','Winhttp.dll','wintrust.dll','wuapi.dll','wuaueng.dll','wuaueng1.dll',
        'wucltui.dll','wucltux.dll','wups.dll','wups2.dll','wuweb.dll','wuwebv.dll',
        'Xpob2res.dll','WBEM\wmisvc.dll'
    )
    foreach ($dll in $dlls) {
        $file = "$env:windir\System32\$dll"
        if (Test-Path $file) {
            Start-Process -FilePath 'regsvr32.exe' -ArgumentList "/s `"$file`"" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        }
    }
    Write-Log "DLL re-registration complete."
}

function Invoke-CCMSetupReinstall {
    param(
        [string]$Share,
        [string]$InstallProperties,
        [bool]$NeedsUninstall = $true
    )

    $ccmSetup = Join-Path $Share 'ccmsetup.exe'

    if (-not (Test-Path $ccmSetup)) {
        Write-Log "ERROR: ccmsetup.exe not found at: $ccmSetup" 'ERROR'
        return $false
    }

    # Re-register DLLs before install
    Register-DLLFiles

    # Uninstall existing client if needed
    if ($NeedsUninstall) {
        Write-Log "Uninstalling existing SCCM client..."
        & $ccmSetup /uninstall
        do {
            Start-Sleep -Seconds 5
        } while (Get-Process -Name ccmsetup -ErrorAction SilentlyContinue)
        Write-Log "Uninstall complete."
    }

    # Install client
    Write-Log "Installing SCCM client: $ccmSetup $InstallProperties"
    if ($InstallProperties) { & $ccmSetup $InstallProperties }
    else                     { & $ccmSetup }

    do {
        Start-Sleep -Seconds 5
    } while (Get-Process -Name ccmsetup -ErrorAction SilentlyContinue)

    # Verify service appeared
    $svc = Get-Service -Name ccmexec -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "SCCM client reinstall complete — CcmExec service detected."
        return $true
    }
    else {
        Write-Log "SCCM client reinstall: CcmExec service not detected after install." 'ERROR'
        return $false
    }
}

#endregion

#region --- Validation ---

function Test-PostRepairHealth {
    Write-Log "Running post-repair validation..."
    $pass = 0; $total = 0

    $checks = @{
        'CcmExec service running' = { (Get-Service ccmexec -ErrorAction SilentlyContinue).Status -eq 'Running' }
        'CcmExec process active'  = { $null -ne (Get-Process ccmexec -ErrorAction SilentlyContinue) }
        'WMI Win32_ComputerSystem'= { try { Get-WmiObject Win32_ComputerSystem -ErrorAction Stop | Out-Null; $true } catch { $false } }
        'HKLM CCM registry key'   = { Test-Path 'HKLM:\SOFTWARE\Microsoft\CCM' }
    }

    foreach ($name in $checks.Keys) {
        $total++
        $result = & $checks[$name]
        if ($result) { Write-Log "  [PASS] $name"; $pass++ }
        else          { Write-Log "  [FAIL] $name" 'WARN' }
    }

    Write-Log "Validation: $pass / $total checks passed."
    return ($pass -eq $total)
}

#endregion

#region --- Main ---

# Ensure log directory exists
if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

Write-Log "=== Enturix Client Health started ==="
Write-Log "Computer  : $env:COMPUTERNAME"
Write-Log "User      : $env:USERNAME"
Write-Log "PSVersion : $($PSVersionTable.PSVersion)"
Write-Log "ClientShare: $ClientShare"

# --- Run health checks ---
Write-Log "--- Running health checks ---"

$needsRepair   = $false
$needsUninstall = $false

# 1. CcmExec service
if (Test-CcmExecService) { $needsRepair = $true }

# 2. Local DB files
if (-not (Test-CcmSDF)) { $needsRepair = $true; $needsUninstall = $true }

# 3. DB corruption log
if (Test-CcmSQLCELog)   { $needsRepair = $true; $needsUninstall = $true }

# 4. WMI health
if (Test-WMIHealth)     { $needsRepair = $true }

# 5. SMS_Client WMI class
if (Test-CcmWMIClass)   { $needsRepair = $true }

# 6. Provisioning mode (self-remediating, flag for awareness only)
Test-ProvisioningMode | Out-Null

if (-not $needsRepair) {
    Write-Log "=== All health checks passed. No repair needed. ==="
    exit 0
}

Write-Log "=== Health checks indicate client needs repair. Starting remediation... ==="

# --- Step 1: Repair WMI ---
Write-Log "--- Step 1: WMI repair ---"
Repair-WMIRepository

# --- Step 2: Reset policy cache ---
Write-Log "--- Step 2: Policy cache reset ---"
Reset-SCCMPolicyCache

# --- Step 3: Clear CCM cache ---
Write-Log "--- Step 3: CCM cache clear ---"
Clear-CCMCache

# --- Step 4: Reinstall SCCM client via ccmsetup.exe ---
Write-Log "--- Step 4: SCCM client reinstall ---"
$reinstallSuccess = Invoke-CCMSetupReinstall -Share $ClientShare -InstallProperties $ClientInstallProperties -NeedsUninstall $needsUninstall

if (-not $reinstallSuccess) {
    Write-Log "=== Reinstall failed. Manual intervention may be required. ===" 'ERROR'
    exit 2
}

# Wait briefly for agent to settle
Start-Sleep -Seconds 30

# --- Final validation ---
Write-Log "--- Final validation ---"
if (Test-PostRepairHealth) {
    Write-Log "=== Remediation completed successfully. ==="
    exit 0
}
else {
    Write-Log "=== Remediation completed but validation found issues. Review log: $LogFile ===" 'WARN'
    exit 1
}

#endregion
