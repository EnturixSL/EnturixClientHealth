# Disable recovery actions so SCM won't auto-restart after kill
& "$env:SystemRoot\System32\sc.exe" failure winmgmt reset= 0 actions= "" 2>&1 | Out-Null
& "$env:SystemRoot\System32\sc.exe" config winmgmt start= disabled 2>&1 | Out-Null
& "$env:SystemRoot\System32\sc.exe" stop winmgmt 2>&1 | Out-Null
Start-Sleep 3

# Kill the hosting svchost
$scOut  = (& "$env:SystemRoot\System32\sc.exe" queryex winmgmt) -join ' '
$svcPid = ([regex]::Match($scOut, 'PID\s*:\s*(\d+)')).Groups[1].Value
if ($svcPid -and $svcPid -ne '0') {
    & cmd /c "taskkill /PID $svcPid /F" 2>&1 | Out-Null
    Write-Host "Killed svchost PID $svcPid"
}
Get-Process -Name WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 3

$state = (& "$env:SystemRoot\System32\sc.exe" query winmgmt) -join ' '
Write-Host "WinMgmt state: $(if ($state -match 'STOPPED') { 'STOPPED' } else { $state })"

# Verify WMI is inaccessible
try {
    Get-WmiObject Win32_ComputerSystem -ErrorAction Stop | Out-Null
    Write-Host "WMI query: SUCCESS (WMI still responding - service may have restarted)"
} catch {
    Write-Host "WMI query: FAILED (good - WMI is now broken)"
}
