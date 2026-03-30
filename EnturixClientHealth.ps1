#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Enturix SCCM Client Health - Detect and Remediate

.DESCRIPTION
    Runs ConfigMgr Client Health checks (based on ConfigMgrClientHealth by Anders Rødland)
    to determine whether the SCCM agent is broken. If broken, applies repair steps
    (based on SCCMagentRepair by Biju George) and then reinstalls the SCCM client via
    ccmsetup.exe instead of CCMRepair.exe.

    All settings are read from an XML configuration file (default: config.xml in the
    same directory as this script). The following XML elements are supported:

        <CheckOnly>              - (optional) true = run checks only, never repair (default: false)
        <ClientShare>            - (required) UNC or local path to the folder containing ccmsetup.exe
        <ClientInstallProperties>- (optional) ccmsetup.exe install properties
        <LogPath>                - (optional) directory where the log file is written
        <RegistryHive>           - (optional) registry path for run state (default: HKLM:\SOFTWARE\EnturixClientHealth)
        <Checks>                 - (optional) per-check true/false toggles (all default to true):
            <TaskSequence>       - exit immediately if a Task Sequence is running (overrides after 5 consecutive detections)
            <CcmExecService>     - verify SMS Agent Host service is running
            <CcmSDF>             - verify >= 7 .sdf database files exist
            <CcmSQLCELog>        - detect ongoing CCM database corruption
            <WMIHealth>          - verify WMI repository consistency
            <CcmWMIClass>        - verify SMS_Client class is accessible
            <ProvisioningMode>   - detect/remediate clients stuck in Provisioning Mode
            <CCMClientSDK>       - verify root\ccm\ClientSDK is accessible (Software Center data layer)

    Health checks performed:
        * Task Sequence running (exits immediately if true — no repairs performed)
        * CcmExec service running
        * CCM local database files present (*.sdf count >= 7)
        * CCM database not corrupt (CcmSQLCE.log)
        * WMI repository consistent and SMS_Client class accessible
        * Client not stuck in Provisioning Mode

    Remediation steps (if any check fails):
        1. Repair WMI repository
        2. Reset SCCM policy cache (registry)
        3. Clean up CCM temp files
        4. Reinstall SCCM client via ccmsetup.exe (uninstall + install)

.PARAMETER ConfigFile
    Path to the XML configuration file.
    Defaults to config.xml in the same directory as this script.

.EXAMPLE
    .\EnturixClientHealth.ps1

.EXAMPLE
    .\EnturixClientHealth.ps1 -ConfigFile "\\server\share\EnturixClientHealth\config.xml"

.NOTES
    Author: Enturix - sebastian.linn@enturix.de
    Health check logic: ConfigMgrClientHealth (Anders Rødland, https://www.andersrodland.com)
    Repair step logic: SCCMagentRepair (Biju George)
#>

param(
    [Parameter(Mandatory = $false, HelpMessage = 'Path to the XML configuration file')]
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'config.xml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$PowerShellVersion = [int]$PSVersionTable.PSVersion.Major

#region --- Logging ---

$LogFile = $null   # set after LogPath is loaded from config

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $entry
    if ($LogFile) {
        # Rotate at 2 MB: rename to timestamped archive, delete any older archives
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -ge 2MB) {
            $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
            $logDir  = [System.IO.Path]::GetDirectoryName($LogFile)
            $logBase = [System.IO.Path]::GetFileNameWithoutExtension($LogFile)
            $logExt  = [System.IO.Path]::GetExtension($LogFile)
            Get-ChildItem -Path $logDir -Filter "${logBase}_*${logExt}" -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Rename-Item -Path $LogFile -NewName "${logBase}_${stamp}${logExt}" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LogFile -Value $entry -ErrorAction Continue
    }
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
        Write-Log "CcmSDF check: FAIL - only $($files.Count) SDF files found (expected >= 7)." 'WARN'
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
        Write-Log "CcmSQLCELog check: FAIL - CcmSQLCE.log exists and was recently updated. DB corrupt." 'WARN'
        return $true
    }

    Write-Log "CcmSQLCELog check: OK."
    return $false
}

# Returns $true if WMI is broken (inconsistent repo or cannot query Win32_ComputerSystem).
function Test-WMIHealth {
    $NeedRepair = $false
    $result     = & winmgmt /verifyrepository 2>&1
    switch -Wildcard ($result) {
        '*inconsistent*'    { $NeedRepair = $true }
        '*not consistent*'  { $NeedRepair = $true }
        '*inkonsekvent*'    { $NeedRepair = $true }
        '*inkonsistent*'    { $NeedRepair = $true }
        '*epäyhtenäinen*'   { $NeedRepair = $true }
    }

    try {
        if ($PowerShellVersion -ge 6) { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Out-Null }
        else                          { Get-WmiObject  Win32_ComputerSystem -ErrorAction Stop  | Out-Null }
    }
    catch { $NeedRepair = $true }

    if ($NeedRepair) {
        Write-Log "WMI health check: FAIL - repository inconsistent or Win32_ComputerSystem unreachable." 'WARN'
        return $true
    }
    Write-Log "WMI health check: OK."
    return $false
}

# Returns $true if CcmExec service is missing or cannot be started.
function Test-CcmExecService {
    $svc = Get-Service -Name ccmexec -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "CcmExec service check: FAIL - service not found." 'WARN'
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
            Write-Log "CcmExec service check: FAIL - service stopped and could not be started." 'WARN'
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
        Write-Log "SMS_Client WMI class check: FAIL - cannot access root/ccm SMS_Client." 'WARN'
        # Clear CCM WMI namespace to avoid needing a full uninstall
        try { Get-WmiObject -Query "Select * from __Namespace WHERE Name='CCM'" -Namespace root -ErrorAction SilentlyContinue | Remove-WmiObject }
        catch {}
        return $true
    }
}

# Returns $true if a Task Sequence is currently executing (OSD or software deployment).
# When a TS is running all repairs are skipped to avoid disrupting the deployment.
#
# Detection strategy (ordered by reliability, per autoitconsulting.com):
#   1. Microsoft.SMS.TSEnvironment COM object — definitive; only bindable while a TS is
#      actively executing. Avoids the false positives produced by process/registry checks.
#   2. TSManager.exe process with a 5-second recheck — filters out transient lingering
#      after TS completion (the main source of false positives in naive implementations).
function Test-RunningTaskSequence {
    # 1. COM object: only accessible while the TS engine is running
    try {
        $tsEnv  = New-Object -COMObject Microsoft.SMS.TSEnvironment -ErrorAction Stop
        $tsType = try { $tsEnv.Value('_SMSTSType') } catch { '' }
        Write-Log "Task Sequence check: ACTIVE - TS environment bound (type: '$tsType'). Skipping all repairs." 'WARN'
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tsEnv) | Out-Null } catch {}
        return $true
    }
    catch {
        # Expected when no TS is running — fall through to secondary checks
    }

    # 2. TSManager.exe with recheck to filter post-completion lingering
    if (Get-Process -Name TSManager -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 5
        if (Get-Process -Name TSManager -ErrorAction SilentlyContinue) {
            Write-Log "Task Sequence check: ACTIVE - TSManager.exe confirmed after recheck. Skipping all repairs." 'WARN'
            return $true
        }
    }

    Write-Log "Task Sequence check: OK - no running Task Sequence detected."
    return $false
}

# Returns $true if client is stuck in Provisioning Mode.
function Test-ProvisioningMode {
    $key   = 'HKLM:\SOFTWARE\Microsoft\CCM\CcmExec'
    $mode  = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).ProvisioningMode
    if ($mode -eq 'true') {
        Write-Log "Provisioning Mode check: FAIL - client is stuck in provisioning mode. Remediating..." 'WARN'
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

# Returns $true if the CCM_ClientSDK WMI namespace (used by Software Center) is inaccessible.
function Test-CCMClientSDK {
    try {
        if ($PowerShellVersion -ge 6) {
            Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_Application' -ErrorAction Stop | Out-Null
        }
        else {
            Get-WmiObject -Namespace 'root\ccm\ClientSDK' -Class 'CCM_Application' -ErrorAction Stop | Out-Null
        }
        Write-Log "CCM ClientSDK check: OK - root\ccm\ClientSDK is accessible."
        return $false
    }
    catch {
        Write-Log "CCM ClientSDK check: FAIL - root\ccm\ClientSDK unreachable (Software Center data layer broken)." 'WARN'
        return $true
    }
}

#endregion

#region --- Repair Functions (logic from SCCMagentRepair by Biju George) ---

function Get-WinMgmtState {
    (& "$env:SystemRoot\System32\sc.exe" query winmgmt) -join ' '
}

function Repair-WMIRepository {
    Write-Log "Repairing WMI repository..."

    # Disable auto-start so SCM cannot restart winmgmt after we force-kill it
    & "$env:SystemRoot\System32\sc.exe" config winmgmt start= demand 2>&1 | Out-Null

    # Use sc.exe stop (non-blocking) so we never hang on a corrupt WMI service
    & "$env:SystemRoot\System32\sc.exe" stop ccmexec 2>&1 | Out-Null
    & "$env:SystemRoot\System32\sc.exe" stop winmgmt 2>&1 | Out-Null

    # Wait up to 30 s for winmgmt to fully stop; force-kill if still pending
    for ($i = 0; $i -lt 15; $i++) {
        if ((Get-WinMgmtState) -match 'STOPPED') { break }
        Start-Sleep -Seconds 2
    }
    if ((Get-WinMgmtState) -notmatch 'STOPPED') {
        Write-Log "WinMgmt stuck in StopPending - force killing process..." 'WARN'
        $scOut  = (& "$env:SystemRoot\System32\sc.exe" queryex winmgmt) -join ' '
        $svcPid = ([regex]::Match($scOut, 'PID\s*:\s*(\d+)')).Groups[1].Value
        if ($svcPid) { cmd.exe /c "taskkill /PID $svcPid /F" 2>&1 | Out-Null }
        Start-Sleep -Seconds 5  # let SCM register the death before resetrepository runs
    }

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

    # Rename the corrupt repository so WinMgmt rebuilds it from scratch on next start.
    # This avoids winmgmt.exe /resetrepository which hangs while SCM is in STOP_PENDING.
    $repoPath    = "$env:SystemRoot\System32\wbem\Repository"
    $repoPathOld = "$env:SystemRoot\System32\wbem\Repository.old"
    if (Test-Path $repoPath) {
        if (Test-Path $repoPathOld) {
            Remove-Item -Path $repoPathOld -Recurse -Force -ErrorAction SilentlyContinue
        }
        Rename-Item -Path $repoPath -NewName 'Repository.old' -Force -ErrorAction SilentlyContinue
        Write-Log "Renamed WMI repository to Repository.old - WinMgmt will rebuild on start."
    }

    # Restore auto-start before restarting the service
    & "$env:SystemRoot\System32\sc.exe" config winmgmt start= auto 2>&1 | Out-Null
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

function Clear-CCMTempFiles {
    Write-Log "Cleaning up CCM temp files..."

    Stop-Service -Name ccmexec -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    foreach ($dir in @('C:\Windows\CCM\Cache', 'C:\Windows\CCM\SystemTemp', 'C:\Windows\CCM\Temp')) {
        if (Test-Path $dir) {
            Get-ChildItem -Path $dir -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Log "Cleared: $dir"
        }
    }

    Write-Log "CCM temp files cleaned up."
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

    # Install client - split properties into individual arguments
    Write-Log "Installing SCCM client: $ccmSetup $InstallProperties"
    if ($InstallProperties) { & $ccmSetup ($InstallProperties -split '\s+') }
    else                     { & $ccmSetup }

    do {
        Start-Sleep -Seconds 5
    } while (Get-Process -Name ccmsetup -ErrorAction SilentlyContinue)

    # Verify service appeared
    $svc = Get-Service -Name ccmexec -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "SCCM client reinstall complete - CcmExec service detected."
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

# --- Load XML configuration ---
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 3
}

try {
    [xml]$cfg = Get-Content $ConfigFile -Encoding UTF8 -ErrorAction Stop
}
catch {
    Write-Error "Failed to parse configuration file '$ConfigFile': $_"
    exit 3
}

$ClientShare             = ($cfg.Configuration.ClientShare             -as [string]).Trim()
$ClientInstallProperties = ($cfg.Configuration.ClientInstallProperties -as [string]).Trim()
$LogPath                 = ($cfg.Configuration.LogPath                 -as [string]).Trim()
$RegistryHive            = ($cfg.Configuration.RegistryHive            -as [string]).Trim()

if (-not $ClientShare) {
    Write-Error "Configuration error: <ClientShare> is missing or empty in '$ConfigFile'."
    exit 3
}
if (-not $LogPath)      { $LogPath      = 'C:\EnturixClientHealth' }
if (-not $RegistryHive) { $RegistryHive = 'HKLM:\SOFTWARE\EnturixClientHealth' }

# --- Load check toggles (default true when element is missing/empty) ---
function Read-CheckSwitch {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    return ($Value.Trim() -ne 'false')
}
$checkTaskSequence   = Read-CheckSwitch ($cfg.Configuration.Checks.TaskSequence   -as [string])
$checkCcmExecService = Read-CheckSwitch ($cfg.Configuration.Checks.CcmExecService -as [string])
$checkCcmSDF         = Read-CheckSwitch ($cfg.Configuration.Checks.CcmSDF         -as [string])
$checkCcmSQLCELog    = Read-CheckSwitch ($cfg.Configuration.Checks.CcmSQLCELog    -as [string])
$checkWMIHealth      = Read-CheckSwitch ($cfg.Configuration.Checks.WMIHealth       -as [string])
$checkCcmWMIClass    = Read-CheckSwitch ($cfg.Configuration.Checks.CcmWMIClass     -as [string])
$checkProvisioningMode = Read-CheckSwitch ($cfg.Configuration.Checks.ProvisioningMode -as [string])
$checkCCMClientSDK     = Read-CheckSwitch ($cfg.Configuration.Checks.CCMClientSDK      -as [string])

# --- Registry state helpers ---
function Initialize-RegistryHive {
    if (-not (Test-Path $RegistryHive)) {
        New-Item -Path $RegistryHive -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Set-HealthState {
    param([string]$Result)
    try {
        Initialize-RegistryHive
        Set-ItemProperty -Path $RegistryHive -Name 'LastRunTime'   -Value (Get-Date -Format 'o') -Type String -Force
        Set-ItemProperty -Path $RegistryHive -Name 'LastRunResult' -Value $Result                -Type String -Force
        Set-ItemProperty -Path $RegistryHive -Name 'LastRunUser'   -Value $env:USERNAME          -Type String -Force
    }
    catch { Write-Log "WARNING: Could not write state to registry ($RegistryHive): $_" 'WARN' }
}

# --- Check-only mode: intentionally defaults to false (unlike check toggles which default to true)
#     because silently skipping all repairs would be a surprising/unsafe default. ---
$checkOnlyRaw = ($cfg.Configuration.CheckOnly -as [string]).Trim()
$checkOnly    = (-not [string]::IsNullOrWhiteSpace($checkOnlyRaw)) -and ($checkOnlyRaw -eq 'true')

# Ensure log directory exists and set log file path
if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
$LogFile = Join-Path $LogPath "EnturixClientHealth.log"

Write-Log "=== Enturix Client Health started ==="
Write-Log "Computer   : $env:COMPUTERNAME"
Write-Log "User       : $env:USERNAME"
Write-Log "PSVersion  : $($PSVersionTable.PSVersion)"
Write-Log "ConfigFile : $ConfigFile"
Write-Log "ClientShare: $ClientShare"

# --- Task Sequence guard ---
# Tracks consecutive TS detections in the registry; overrides after 5 runs so
# repairs are not blocked indefinitely by a stuck/phantom task sequence.
if ($checkTaskSequence) {
    if (Test-RunningTaskSequence) {
        $hitCount = 0
        try { $hitCount = [int](Get-ItemProperty -Path $RegistryHive -Name 'TSConsecutiveCount' -ErrorAction SilentlyContinue).TSConsecutiveCount } catch {}
        $hitCount++
        try {
            Initialize-RegistryHive
            Set-ItemProperty -Path $RegistryHive -Name 'TSConsecutiveCount' -Value $hitCount              -Type DWord  -Force
            Set-ItemProperty -Path $RegistryHive -Name 'TSLastDetected'     -Value (Get-Date -Format 'o') -Type String -Force
        } catch {}

        if ($hitCount -ge 5) {
            Write-Log "Task Sequence guard: OVERRIDE - TS detected in $hitCount consecutive runs. Proceeding with health checks." 'WARN'
        } else {
            Write-Log "=== Task Sequence in progress - exiting without repair ($hitCount/5 runs before override). ==="
            Set-HealthState 'TSBlocked'
            exit 0
        }
    } else {
        # Clean run — reset the consecutive-detection counter
        try {
            Initialize-RegistryHive
            Set-ItemProperty -Path $RegistryHive -Name 'TSConsecutiveCount' -Value 0 -Type DWord -Force
        } catch {}
    }
}

# --- Run health checks ---
Write-Log "--- Running health checks ---"

$needsRepair    = $false
$needsWMIRepair = $false
$needsUninstall = $false

# 1. CcmExec service
if ($checkCcmExecService) {
    if (Test-CcmExecService) { $needsRepair = $true }
} else { Write-Log "CcmExec service check: skipped (disabled in config)." }

# 2. Local DB files
if ($checkCcmSDF) {
    if (-not (Test-CcmSDF)) { $needsRepair = $true; $needsUninstall = $true }
} else { Write-Log "CcmSDF check: skipped (disabled in config)." }

# 3. DB corruption log
if ($checkCcmSQLCELog) {
    if (Test-CcmSQLCELog) { $needsRepair = $true; $needsUninstall = $true }
} else { Write-Log "CcmSQLCELog check: skipped (disabled in config)." }

# 4. WMI health - only triggers WMI-specific repair
if ($checkWMIHealth) {
    if (Test-WMIHealth) { $needsRepair = $true; $needsWMIRepair = $true }
} else { Write-Log "WMI health check: skipped (disabled in config)." }

# 5. SMS_Client WMI class - SCCM reinstall only, not WMI repair
if ($checkCcmWMIClass) {
    if (Test-CcmWMIClass) { $needsRepair = $true }
} else { Write-Log "SMS_Client WMI class check: skipped (disabled in config)." }

# 6. Provisioning mode (self-remediating, flag for awareness only)
if ($checkProvisioningMode) {
    Test-ProvisioningMode | Out-Null
} else { Write-Log "Provisioning Mode check: skipped (disabled in config)." }

# 7. CCM ClientSDK namespace (Software Center data layer)
if ($checkCCMClientSDK) {
    if (Test-CCMClientSDK) { $needsRepair = $true }
} else { Write-Log "CCM ClientSDK check: skipped (disabled in config)." }

if (-not $needsRepair) {
    Write-Log "=== All health checks passed. No repair needed. ==="

    # --- Cache ccmsetup.exe locally for future repairs ---
    $ccmSetupSource = 'C:\Windows\CCMSetup\ccmsetup.exe'
    $ccmSetupCache  = $ClientShare

    if (Test-Path $ccmSetupSource) {
        try {
            New-Item -ItemType Directory -Path $ccmSetupCache -Force -ErrorAction Stop | Out-Null

            $ccmSetupDest = Join-Path $ccmSetupCache 'ccmsetup.exe'
            $sourceItem   = Get-Item -Path $ccmSetupSource -ErrorAction Stop
            $destItem     = Get-Item -Path $ccmSetupDest   -ErrorAction SilentlyContinue

            # Skip SHA-256 if sizes already differ (fast path); compute hashes only when sizes match
            $sourceHash = $null
            $destHash   = $null
            if ($destItem -and $destItem.Length -eq $sourceItem.Length) {
                $sourceHash = (Get-FileHash -Path $ccmSetupSource -Algorithm SHA256 -ErrorAction Stop).Hash
                $destHash   = (Get-FileHash -Path $ccmSetupDest   -Algorithm SHA256 -ErrorAction Stop).Hash
            }

            if ($sourceHash -and $sourceHash -eq $destHash) {
                Write-Log "ccmsetup.exe cache is up to date (SHA256: $sourceHash) - skipping copy."
            }
            else {
                Copy-Item -Path $ccmSetupSource -Destination $ccmSetupCache -Force -ErrorAction Stop
                if (-not $sourceHash) { $sourceHash = (Get-FileHash -Path $ccmSetupSource -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash }
                Write-Log "Cached ccmsetup.exe to $ccmSetupCache (SHA256: $sourceHash)."
            }
        }
        catch {
            Write-Log "WARNING: Could not cache ccmsetup.exe to ${ccmSetupCache}: $_" 'WARN'
        }
    }
    else {
        Write-Log "ccmsetup.exe not found at $ccmSetupSource - skipping cache." 'WARN'
    }

    Set-HealthState 'Healthy'
    exit 0
}

if ($checkOnly) {
    Write-Log "=== Check-only mode: repairs skipped. Client needs attention. ===" 'WARN'
    Set-HealthState 'CheckOnly'
    exit 1
}

Write-Log "=== Health checks indicate client needs repair. Starting remediation... ==="

# --- Step 1: Repair WMI (only when WMI itself is broken) ---
Write-Log "--- Step 1: WMI repair ---"
if ($needsWMIRepair) {
    Repair-WMIRepository
} else {
    Write-Log "WMI is healthy - skipping WMI repair."
}

# --- Step 2: Reset policy cache ---
Write-Log "--- Step 2: Policy cache reset ---"
Reset-SCCMPolicyCache

# --- Step 3: Clean up CCM temp files ---
Write-Log "--- Step 3: Clean up CCM temp files ---"
Clear-CCMTempFiles

# --- Step 4: Reinstall SCCM client via ccmsetup.exe ---
Write-Log "--- Step 4: SCCM client reinstall ---"
$reinstallSuccess = Invoke-CCMSetupReinstall -Share $ClientShare -InstallProperties $ClientInstallProperties -NeedsUninstall $needsUninstall

if (-not $reinstallSuccess) {
    Write-Log "=== Reinstall failed. Manual intervention may be required. ===" 'ERROR'
    Set-HealthState 'RepairFailed'
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
