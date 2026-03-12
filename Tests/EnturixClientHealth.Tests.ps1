#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pester 5 unit tests for EnturixClientHealth.ps1

.DESCRIPTION
    Loads only the function definitions from EnturixClientHealth.ps1 (strips the
    #region --- Main --- body so that exit calls and mandatory params are never hit).
    All external dependencies (registry, filesystem, WMI, services) are mocked.
#>

BeforeAll {
    $scriptPath = Resolve-Path "$PSScriptRoot\..\EnturixClientHealth.ps1"
    $raw        = Get-Content $scriptPath -Raw -Encoding UTF8

    # ── Strip the main execution body ──────────────────────────────────────────
    # Everything from '#region --- Main ---' onwards is discarded so that health
    # checks, repairs, and exit calls never run during unit tests.
    $beforeMain     = ($raw -split [regex]::Escape('#region --- Main ---'))[0]

    # ── Keep only the logging + function regions ────────────────────────────────
    # Drop #Requires directives (elevation check blocks dot-sourcing in some hosts)
    # and the param() block (mandatory params would error without arguments).
    $functionsBlock = ($beforeMain -split [regex]::Escape('#region --- Logging ---'), 2)[1]
    $functionsBlock = '#region --- Logging ---' + $functionsBlock

    # Prepend script-level variables that the functions reference at runtime.
    # $LogPath/$LogFile are needed by the Logging region's script-level statements.
    $preamble = @"
`$PowerShellVersion  = [int]`$PSVersionTable.PSVersion.Major
`$ErrorActionPreference = 'Continue'
`$LogPath = [IO.Path]::GetTempPath()

"@

    $tempFile = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.ps1')
    Set-Content -Path $tempFile -Value ($preamble + $functionsBlock) -Encoding UTF8
    . $tempFile
    Remove-Item $tempFile -ErrorAction SilentlyContinue

    # Keep a temp file reference in case a test ever calls Write-Log without mocking it
    $script:TestLogFile = [IO.Path]::GetTempFileName()

    # Compile a minimal .NET stub exe so Invoke-CCMSetupReinstall can call
    # & $ccmSetup without a CommandNotFoundException or resource error.
    # The stub accepts any arguments and exits with code 0 immediately.
    $script:FakeShare = Join-Path ([IO.Path]::GetTempPath()) 'PesterFakeShare'
    New-Item -ItemType Directory -Path $script:FakeShare -Force | Out-Null
    Add-Type -TypeDefinition @'
using System;
class CcmSetupStub {
    static int Main(string[] args) { return 0; }
}
'@ -OutputAssembly (Join-Path $script:FakeShare 'ccmsetup.exe')
}

AfterAll {
    Remove-Item $script:TestLogFile -ErrorAction SilentlyContinue
    Remove-Item $script:FakeShare -Recurse -Force -ErrorAction SilentlyContinue
}

# ══════════════════════════════════════════════════════════════════════════════
#  XML config loading (Main region — tested via helper logic, not dot-sourced)
# ══════════════════════════════════════════════════════════════════════════════
Describe 'XML Configuration Loading' {
    BeforeAll {
        $script:CfgDir = Join-Path ([IO.Path]::GetTempPath()) 'PesterCfgTest'
        New-Item -ItemType Directory -Path $script:CfgDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item $script:CfgDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Valid config with all three elements' {
        BeforeAll {
            $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
    <ClientShare>\\srv\Client$</ClientShare>
    <ClientInstallProperties>SMSSITECODE=P01</ClientInstallProperties>
    <LogPath>C:\Logs\Test</LogPath>
</Configuration>
'@
            $script:ValidCfg = Join-Path $script:CfgDir 'valid.xml'
            Set-Content $script:ValidCfg $xml -Encoding UTF8
        }

        It 'parses ClientShare correctly' {
            [xml]$cfg = Get-Content $script:ValidCfg -Encoding UTF8
            ($cfg.Configuration.ClientShare -as [string]).Trim() | Should -Be '\\srv\Client$'
        }
        It 'parses ClientInstallProperties correctly' {
            [xml]$cfg = Get-Content $script:ValidCfg -Encoding UTF8
            ($cfg.Configuration.ClientInstallProperties -as [string]).Trim() | Should -Be 'SMSSITECODE=P01'
        }
        It 'parses LogPath correctly' {
            [xml]$cfg = Get-Content $script:ValidCfg -Encoding UTF8
            ($cfg.Configuration.LogPath -as [string]).Trim() | Should -Be 'C:\Logs\Test'
        }
    }

    Context 'Config with empty LogPath defaults to C:\EnturixClientHealth' {
        BeforeAll {
            $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
    <ClientShare>\\srv\Client$</ClientShare>
    <ClientInstallProperties></ClientInstallProperties>
    <LogPath></LogPath>
</Configuration>
'@
            $script:EmptyLogCfg = Join-Path $script:CfgDir 'empty-logpath.xml'
            Set-Content $script:EmptyLogCfg $xml -Encoding UTF8
        }

        It 'falls back to C:\EnturixClientHealth when LogPath is empty' {
            [xml]$cfg = Get-Content $script:EmptyLogCfg -Encoding UTF8
            $logPath = ($cfg.Configuration.LogPath -as [string]).Trim()
            if (-not $logPath) { $logPath = 'C:\EnturixClientHealth' }
            $logPath | Should -Be 'C:\EnturixClientHealth'
        }
    }

    Context 'Config file does not exist' {
        It 'Test-Path returns $false for a missing config' {
            Test-Path (Join-Path $script:CfgDir 'nonexistent.xml') | Should -BeFalse
        }
    }

    Context 'Malformed XML' {
        BeforeAll {
            $script:BadCfg = Join-Path $script:CfgDir 'bad.xml'
            Set-Content $script:BadCfg 'this is not xml' -Encoding UTF8
        }

        It 'throws when parsed with [xml] cast' {
            { [xml](Get-Content $script:BadCfg -Encoding UTF8) } | Should -Throw
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  ccmsetup.exe cache hash comparison
# ══════════════════════════════════════════════════════════════════════════════
Describe 'ccmsetup.exe cache hash comparison' {
    BeforeAll {
        $script:HashDir = Join-Path ([IO.Path]::GetTempPath()) 'PesterHashTest'
        New-Item -ItemType Directory -Path $script:HashDir -Force | Out-Null

        # Source file — arbitrary reproducible content
        $script:SrcFile  = Join-Path $script:HashDir 'source\ccmsetup.exe'
        $script:DestDir  = Join-Path $script:HashDir 'dest'
        $script:DestFile = Join-Path $script:DestDir 'ccmsetup.exe'

        New-Item -ItemType Directory -Path (Split-Path $script:SrcFile) -Force | Out-Null
        New-Item -ItemType Directory -Path $script:DestDir               -Force | Out-Null

        [IO.File]::WriteAllBytes($script:SrcFile,  [byte[]](1..16))
        [IO.File]::WriteAllBytes($script:DestFile, [byte[]](1..16))   # identical to source
    }
    AfterAll {
        Remove-Item $script:HashDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'Source and destination have the same SHA-256 hash' {
        It 'hashes are equal — copy should be skipped' {
            $srcHash  = (Get-FileHash $script:SrcFile  -Algorithm SHA256).Hash
            $destHash = (Get-FileHash $script:DestFile -Algorithm SHA256).Hash
            $srcHash | Should -Be $destHash
        }
    }

    Context 'Source and destination differ' {
        BeforeEach {
            # Write different bytes to destination
            [IO.File]::WriteAllBytes($script:DestFile, [byte[]](17..32))
        }
        AfterEach {
            # Restore identical state for any following tests
            [IO.File]::WriteAllBytes($script:DestFile, [byte[]](1..16))
        }

        It 'hashes are not equal — copy should proceed' {
            $srcHash  = (Get-FileHash $script:SrcFile  -Algorithm SHA256).Hash
            $destHash = (Get-FileHash $script:DestFile -Algorithm SHA256).Hash
            $srcHash | Should -Not -Be $destHash
        }

        It 'after copy, hashes match' {
            Copy-Item $script:SrcFile $script:DestDir -Force
            $srcHash  = (Get-FileHash $script:SrcFile  -Algorithm SHA256).Hash
            $destHash = (Get-FileHash $script:DestFile -Algorithm SHA256).Hash
            $srcHash | Should -Be $destHash
        }
    }

    Context 'Destination file does not yet exist' {
        BeforeEach {
            Remove-Item $script:DestFile -ErrorAction SilentlyContinue
        }
        AfterEach {
            [IO.File]::WriteAllBytes($script:DestFile, [byte[]](1..16))
        }

        It 'dest hash is null when file is absent' {
            $destHash = if (Test-Path $script:DestFile) {
                (Get-FileHash $script:DestFile -Algorithm SHA256).Hash
            } else { $null }
            $destHash | Should -BeNullOrEmpty
        }

        It 'source hash does not equal null — copy should proceed' {
            $srcHash  = (Get-FileHash $script:SrcFile -Algorithm SHA256).Hash
            $destHash = $null
            $srcHash | Should -Not -Be $destHash
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Get-CCMDirectory
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Get-CCMDirectory' {
    BeforeEach { Mock Write-Log {} }

    Context 'Registry value is present' {
        BeforeEach {
            Mock Get-ItemProperty {
                [PSCustomObject]@{ 'Local SMS Path' = 'C:\Windows\CCM\' }
            }
        }
        It 'returns the registry path with trailing backslash removed' {
            Get-CCMDirectory | Should -Be 'C:\Windows\CCM'
        }
    }

    Context 'Registry key is absent (Get-ItemProperty returns null)' {
        BeforeEach {
            Mock Get-ItemProperty { $null }
        }
        It 'falls back to C:\Windows\CCM' {
            Get-CCMDirectory | Should -Be 'C:\Windows\CCM'
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Get-CCMLogDirectory
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Get-CCMLogDirectory' {
    BeforeEach { Mock Write-Log {} }

    Context 'Logs subdirectory exists' {
        BeforeEach {
            Mock Get-CCMDirectory { 'C:\Windows\CCM' }
            Mock Test-Path { $true }
        }
        It 'returns <CCMDir>\Logs' {
            Get-CCMLogDirectory | Should -Be 'C:\Windows\CCM\Logs'
        }
    }

    Context 'Logs subdirectory is absent' {
        BeforeEach {
            Mock Get-CCMDirectory { 'C:\Windows\CCM' }
            Mock Test-Path { $false }
        }
        It 'falls back to the CCM directory itself' {
            Get-CCMLogDirectory | Should -Be 'C:\Windows\CCM'
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Test-CcmSDF
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Test-CcmSDF' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-CCMDirectory { 'C:\Windows\CCM' }
    }

    Context 'Eight SDF files present (above threshold)' {
        BeforeEach {
            Mock Get-ChildItem {
                1..8 | ForEach-Object { [PSCustomObject]@{ Name = "db$_.sdf" } }
            }
        }
        It 'returns $true' {
            Test-CcmSDF | Should -BeTrue
        }
    }

    Context 'Exactly seven SDF files (boundary)' {
        BeforeEach {
            Mock Get-ChildItem {
                1..7 | ForEach-Object { [PSCustomObject]@{ Name = "db$_.sdf" } }
            }
        }
        It 'returns $true' {
            Test-CcmSDF | Should -BeTrue
        }
    }

    Context 'Six SDF files (one below threshold)' {
        BeforeEach {
            Mock Get-ChildItem {
                1..6 | ForEach-Object { [PSCustomObject]@{ Name = "db$_.sdf" } }
            }
        }
        It 'returns $false' {
            Test-CcmSDF | Should -BeFalse
        }
    }

    Context 'No SDF files at all' {
        BeforeEach {
            Mock Get-ChildItem { @() }
        }
        It 'returns $false' {
            Test-CcmSDF | Should -BeFalse
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Test-CcmSQLCELog
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Test-CcmSQLCELog' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-CCMLogDirectory { 'C:\Windows\CCM\Logs' }
    }

    Context 'CcmSQLCE.log does not exist' {
        BeforeEach {
            Mock Test-Path { $false }
        }
        It 'returns $false — no corruption evidence' {
            Test-CcmSQLCELog | Should -BeFalse
        }
    }

    Context 'Log exists; recently written; created > 7 days ago (active corruption)' {
        BeforeEach {
            Mock Test-Path { $true }
            Mock Get-ItemProperty { [PSCustomObject]@{ logLevel = 1 } }
            $now = Get-Date
            Mock Get-Item {
                [PSCustomObject]@{
                    LastWriteTime = $now.AddDays(-1)    # written yesterday
                    CreationTime  = $now.AddDays(-30)   # created a month ago
                }
            }
        }
        It 'returns $true — database considered corrupt' {
            Test-CcmSQLCELog | Should -BeTrue
        }
    }

    Context 'Log exists but last write is older than 7 days (stale)' {
        BeforeEach {
            Mock Test-Path { $true }
            Mock Get-ItemProperty { [PSCustomObject]@{ logLevel = 1 } }
            $now = Get-Date
            Mock Get-Item {
                [PSCustomObject]@{
                    LastWriteTime = $now.AddDays(-30)
                    CreationTime  = $now.AddDays(-60)
                }
            }
        }
        It 'returns $false — no recent corruption activity' {
            Test-CcmSQLCELog | Should -BeFalse
        }
    }

    Context 'Client is in debug mode (logLevel = 0)' {
        BeforeEach {
            Mock Test-Path { $true }
            Mock Get-ItemProperty { [PSCustomObject]@{ logLevel = 0 } }
        }
        It 'returns $false — check is skipped in debug mode' {
            Test-CcmSQLCELog | Should -BeFalse
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Test-WMIHealth
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Test-WMIHealth' {
    # Note: winmgmt /verifyrepository is an external native command and cannot be
    # mocked via Pester. These tests rely on the real command returning a
    # "consistent" result (true on any healthy system) and cover the
    # Get-WmiObject / Get-CimInstance branch via mocking.

    BeforeEach {
        Mock Write-Log {}
        $script:PowerShellVersion = 5   # force the Get-WmiObject code path
    }

    Context 'WMI repo consistent and Win32_ComputerSystem accessible' {
        BeforeEach {
            Mock Get-WmiObject { [PSCustomObject]@{ Name = 'TestComputer' } }
        }
        It 'returns $false (no WMI issues detected)' {
            Test-WMIHealth | Should -BeFalse
        }
    }

    Context 'Win32_ComputerSystem query throws (WMI partially broken)' {
        BeforeEach {
            Mock Get-WmiObject { throw 'WMI RPC unavailable' }
        }
        It 'returns $true (vote incremented by exception)' {
            # winmgmt returns consistent (vote=0), but WMI query fails (vote=1) → broken
            Test-WMIHealth | Should -BeTrue
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Test-CcmExecService
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Test-CcmExecService' {
    BeforeEach { Mock Write-Log {} }

    Context 'Service is running' {
        BeforeEach {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' } }
        }
        It 'returns $false (healthy)' {
            Test-CcmExecService | Should -BeFalse
        }
    }

    Context 'Service does not exist' {
        BeforeEach {
            Mock Get-Service { $null }
        }
        It 'returns $true (service missing)' {
            Test-CcmExecService | Should -BeTrue
        }
    }

    Context 'Service stopped but starts successfully' {
        BeforeEach {
            Mock Get-Service  { [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Automatic' } }
            Mock Set-Service  {}
            Mock Start-Service {}
        }
        It 'returns $false (service recovered)' {
            Test-CcmExecService | Should -BeFalse
        }
        It 'calls Start-Service exactly once' {
            Test-CcmExecService
            Should -Invoke Start-Service -Exactly 1
        }
    }

    Context 'Service stopped and Start-Service throws' {
        BeforeEach {
            Mock Get-Service   { [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Automatic' } }
            Mock Set-Service   {}
            Mock Start-Service { throw 'Access denied' }
        }
        It 'returns $true (service cannot be started)' {
            Test-CcmExecService | Should -BeTrue
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Test-CcmWMIClass
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Test-CcmWMIClass' {
    BeforeEach {
        Mock Write-Log {}
        $script:PowerShellVersion = 5   # use Get-WmiObject path
    }

    Context 'SMS_Client class is accessible' {
        BeforeEach {
            Mock Get-WmiObject { [PSCustomObject]@{ ClientVersion = '5.00.9049.1000' } }
        }
        It 'returns $false (healthy)' {
            Test-CcmWMIClass | Should -BeFalse
        }
    }

    Context 'SMS_Client class query throws' {
        BeforeEach {
            Mock Get-WmiObject   { throw 'Invalid namespace' }
            Mock Remove-WmiObject {}
        }
        It 'returns $true (WMI class broken)' {
            Test-CcmWMIClass | Should -BeTrue
        }
        It 'attempts to clear the CCM WMI namespace' {
            Test-CcmWMIClass
            Should -Invoke Get-WmiObject -Exactly 2   # once for SMS_Client, once for __Namespace query
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Test-ProvisioningMode
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Test-ProvisioningMode' {
    BeforeEach {
        Mock Write-Log {}
        $script:PowerShellVersion = 5
    }

    Context 'ProvisioningMode is false' {
        BeforeEach {
            Mock Get-ItemProperty { [PSCustomObject]@{ ProvisioningMode = 'false' } }
        }
        It 'returns $false (client healthy)' {
            Test-ProvisioningMode | Should -BeFalse
        }
    }

    Context 'ProvisioningMode key is absent (null)' {
        BeforeEach {
            Mock Get-ItemProperty { $null }
        }
        It 'returns $false (key absent means not stuck)' {
            Test-ProvisioningMode | Should -BeFalse
        }
    }

    Context 'Client is stuck in provisioning mode' {
        BeforeEach {
            Mock Get-ItemProperty  { [PSCustomObject]@{ ProvisioningMode = 'true' } }
            Mock Set-ItemProperty  {}
            Mock Invoke-WmiMethod  { [PSCustomObject]@{ ReturnValue = 0 } }
        }
        It 'returns $true' {
            Test-ProvisioningMode | Should -BeTrue
        }
        It 'sets ProvisioningMode registry value to false' {
            Test-ProvisioningMode
            Should -Invoke Set-ItemProperty -Exactly 1 -ParameterFilter {
                $Name -eq 'ProvisioningMode' -and $Value -eq 'false'
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Test-PostRepairHealth
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Test-PostRepairHealth' {
    BeforeEach { Mock Write-Log {} }

    Context 'All four checks pass' {
        BeforeEach {
            Mock Get-Service   { [PSCustomObject]@{ Status = 'Running' } }
            Mock Get-Process   { [PSCustomObject]@{ Name = 'ccmexec' } }
            Mock Get-WmiObject { [PSCustomObject]@{ Name = 'Computer' } }
            Mock Test-Path     { $true }
        }
        It 'returns $true' {
            Test-PostRepairHealth | Should -BeTrue
        }
    }

    Context 'CcmExec service is stopped' {
        BeforeEach {
            Mock Get-Service   { [PSCustomObject]@{ Status = 'Stopped' } }
            Mock Get-Process   { [PSCustomObject]@{ Name = 'ccmexec' } }
            Mock Get-WmiObject { [PSCustomObject]@{ Name = 'Computer' } }
            Mock Test-Path     { $true }
        }
        It 'returns $false' {
            Test-PostRepairHealth | Should -BeFalse
        }
    }

    Context 'CcmExec process is not running' {
        BeforeEach {
            Mock Get-Service   { [PSCustomObject]@{ Status = 'Running' } }
            Mock Get-Process   { $null }
            Mock Get-WmiObject { [PSCustomObject]@{ Name = 'Computer' } }
            Mock Test-Path     { $true }
        }
        It 'returns $false' {
            Test-PostRepairHealth | Should -BeFalse
        }
    }

    Context 'WMI Win32_ComputerSystem inaccessible' {
        BeforeEach {
            Mock Get-Service   { [PSCustomObject]@{ Status = 'Running' } }
            Mock Get-Process   { [PSCustomObject]@{ Name = 'ccmexec' } }
            Mock Get-WmiObject { throw 'WMI error' }
            Mock Test-Path     { $true }
        }
        It 'returns $false' {
            Test-PostRepairHealth | Should -BeFalse
        }
    }

    Context 'HKLM CCM registry key missing' {
        BeforeEach {
            Mock Get-Service   { [PSCustomObject]@{ Status = 'Running' } }
            Mock Get-Process   { [PSCustomObject]@{ Name = 'ccmexec' } }
            Mock Get-WmiObject { [PSCustomObject]@{ Name = 'Computer' } }
            Mock Test-Path     { $false }
        }
        It 'returns $false' {
            Test-PostRepairHealth | Should -BeFalse
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Invoke-CCMSetupReinstall
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Invoke-CCMSetupReinstall' {
    BeforeEach {
        Mock Write-Log        {}
        Mock Register-DLLFiles {}
        Mock Start-Sleep      {}
        # Return $null from Get-Process so the "wait for ccmsetup" loop exits immediately
        Mock Get-Process      { $null }
    }

    Context 'ccmsetup.exe not found at the share' {
        BeforeEach {
            Mock Test-Path { $false }
        }
        It 'returns $false without attempting an install' {
            Invoke-CCMSetupReinstall -Share '\\fake\share' -InstallProperties '' -NeedsUninstall $false |
                Should -BeFalse
        }
        It 'does not call Register-DLLFiles' {
            Invoke-CCMSetupReinstall -Share '\\fake\share' -InstallProperties '' -NeedsUninstall $false
            Should -Invoke Register-DLLFiles -Exactly 0
        }
    }

    Context 'ccmsetup.exe found; CcmExec service appears after install' {
        # Uses a real cmd.exe stub — avoids CommandNotFoundException from & on a
        # non-existent path, which is terminating even with ErrorActionPreference=Continue.
        BeforeEach {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running' } }
        }
        It 'returns $true' {
            $result = Invoke-CCMSetupReinstall -Share $script:FakeShare -InstallProperties '' -NeedsUninstall $false
            $result | Should -BeTrue
        }
        It 'calls Register-DLLFiles before attempting install' {
            Invoke-CCMSetupReinstall -Share $script:FakeShare -InstallProperties '' -NeedsUninstall $false
            Should -Invoke Register-DLLFiles -Exactly 1
        }
    }

    Context 'ccmsetup.exe found; CcmExec service never appears after install' {
        BeforeEach {
            Mock Get-Service { $null }
        }
        It 'returns $false' {
            $result = Invoke-CCMSetupReinstall -Share $script:FakeShare -InstallProperties '' -NeedsUninstall $false
            $result | Should -BeFalse
        }
    }

    Context 'Uninstall is required before reinstall' {
        BeforeEach {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running' } }
        }
        It 'still returns $true after uninstall + install cycle' {
            $result = Invoke-CCMSetupReinstall -Share $script:FakeShare -InstallProperties 'SMSSITECODE=P01' -NeedsUninstall $true
            $result | Should -BeTrue
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Repair-WMIRepository
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Repair-WMIRepository' {
    BeforeEach {
        Mock Write-Log         {}
        Mock Start-Service     {}
        Mock Start-Sleep       {}
        # Return 'STOPPED' immediately so the wait loop exits on its first iteration
        # without spinning or triggering the force-kill branch.
        Mock Get-WinMgmtState  { 'STATE : 1  STOPPED' }
        # Return $false for all wbem paths so the binary re-registration loop and
        # native winmgmt.exe /resetrepository calls are never reached.
        Mock Test-Path { $false }
    }

    It 'restarts WinMgmt and pauses 10 s after stopping services' {
        Repair-WMIRepository
        Should -Invoke -CommandName Start-Service -ParameterFilter { $Name -eq 'winmgmt' } -Exactly 1
        Should -Invoke -CommandName Start-Sleep   -ParameterFilter { $Seconds -eq 10     } -Exactly 1
    }

    It 'completes without throwing when wbem paths are absent' {
        { Repair-WMIRepository } | Should -Not -Throw
    }

    Context 'Only System32\wbem path exists; no binaries present' {
        BeforeEach {
            # wbem directory path exists → Push/Pop-Location are called.
            # All binary filenames return $false → no & .\bin.exe attempt.
            Mock Test-Path -ParameterFilter { $Path -like '*System32\wbem'  } { $true  }
            Mock Test-Path -ParameterFilter { $Path -like '*SysWOW64\wbem'  } { $false }
            Mock Test-Path                                                     { $false }
            Mock Push-Location {}
            Mock Pop-Location  {}
        }

        It 'calls Push-Location once for the System32 wbem path' {
            $null = Repair-WMIRepository
            Should -Invoke -CommandName Push-Location -Exactly 1
        }

        It 'calls Pop-Location once after processing the wbem path' {
            $null = Repair-WMIRepository
            Should -Invoke -CommandName Pop-Location -Exactly 1
        }

        It 'completes without throwing' {
            { Repair-WMIRepository } | Should -Not -Throw
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Reset-SCCMPolicyCache
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Reset-SCCMPolicyCache' {
    BeforeEach {
        Mock Write-Log    {}
        Mock Stop-Service {}
        Mock Start-Sleep  {}
    }

    It 'stops CcmExec service' {
        Mock Test-Path  { $false }
        Mock Remove-Item {}
        Reset-SCCMPolicyCache
        Should -Invoke Stop-Service -ParameterFilter { $Name -eq 'ccmexec' } -Exactly 1
    }

    It 'waits 5 seconds after stopping the service' {
        Mock Test-Path  { $false }
        Mock Remove-Item {}
        Reset-SCCMPolicyCache
        Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 5 } -Exactly 1
    }

    Context 'No registry paths exist' {
        BeforeEach {
            Mock Test-Path   { $false }
            Mock Remove-Item {}
        }

        It 'does not call Remove-Item' {
            Reset-SCCMPolicyCache
            Should -Invoke Remove-Item -Exactly 0
        }

        It 'completes without throwing' {
            { Reset-SCCMPolicyCache } | Should -Not -Throw
        }
    }

    Context 'All five registry paths exist' {
        BeforeEach {
            Mock Test-Path   { $true }
            Mock Remove-Item {}
        }

        It 'calls Remove-Item exactly five times' {
            Reset-SCCMPolicyCache
            Should -Invoke Remove-Item -Exactly 5
        }

        It 'removes each path with -Recurse -Force' {
            Reset-SCCMPolicyCache
            Should -Invoke Remove-Item -ParameterFilter { $Recurse -eq $true -and $Force -eq $true } -Exactly 5
        }
    }

    Context 'Only one registry path exists' {
        BeforeEach {
            Mock Test-Path -ParameterFilter {
                $Path -eq 'HKLM:\SOFTWARE\Microsoft\CCM\CcmEval\Policy'
            } { $true }
            Mock Test-Path   { $false }
            Mock Remove-Item {}
        }

        It 'calls Remove-Item exactly once' {
            Reset-SCCMPolicyCache
            Should -Invoke Remove-Item -Exactly 1
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Clear-CCMCache
# ══════════════════════════════════════════════════════════════════════════════
Describe 'Clear-CCMCache' {
    BeforeEach {
        Mock Write-Log    {}
        Mock Stop-Service {}
        Mock Start-Sleep  {}
    }

    It 'stops CcmExec service' {
        Mock Test-Path    { $false }
        Clear-CCMCache
        Should -Invoke Stop-Service -ParameterFilter { $Name -eq 'ccmexec' } -Exactly 1
    }

    It 'waits 5 seconds after stopping the service' {
        Mock Test-Path    { $false }
        Clear-CCMCache
        Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 5 } -Exactly 1
    }

    Context 'No cache directories exist' {
        BeforeEach {
            Mock Test-Path    { $false }
            Mock Get-ChildItem { @() }
            Mock Remove-Item  {}
        }

        It 'does not call Get-ChildItem' {
            Clear-CCMCache
            Should -Invoke Get-ChildItem -Exactly 0
        }

        It 'completes without throwing' {
            { Clear-CCMCache } | Should -Not -Throw
        }
    }

    Context 'All three cache directories exist with files' {
        BeforeEach {
            Mock Test-Path    { $true }
            Mock Get-ChildItem {
                [PSCustomObject]@{ FullName = 'C:\Windows\CCM\Cache\file1.tmp' }
            }
            Mock Remove-Item  {}
        }

        It 'calls Get-ChildItem for all three directories' {
            Clear-CCMCache
            Should -Invoke Get-ChildItem -Exactly 3
        }

        It 'calls Remove-Item for each discovered file' {
            Clear-CCMCache
            Should -Invoke Remove-Item -Exactly 3
        }

        It 'completes without throwing' {
            { Clear-CCMCache } | Should -Not -Throw
        }
    }

    Context 'Only one cache directory exists' {
        BeforeEach {
            Mock Test-Path -ParameterFilter { $Path -eq 'C:\Windows\CCM\Cache' } { $true }
            Mock Test-Path    { $false }
            Mock Get-ChildItem {
                [PSCustomObject]@{ FullName = 'C:\Windows\CCM\Cache\stale.pkg' }
            }
            Mock Remove-Item {}
        }

        It 'calls Get-ChildItem exactly once' {
            Clear-CCMCache
            Should -Invoke Get-ChildItem -Exactly 1
        }
    }
}
