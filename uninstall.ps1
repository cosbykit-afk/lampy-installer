<#
.SYNOPSIS
    Uninstall Lampy: remove WSL distro, scheduled task, and install directory.
#>
param(
    [string]$InstallDir = "C:\Lampy",
    [string]$DistroName = "lampy"
)
$ErrorActionPreference = "Stop"

$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw "Uninstall must run as Administrator." }

Write-Host "Stopping Lampy..."
Stop-ScheduledTask -TaskName "Lampy" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "Lampy" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Unregistering WSL distro '$DistroName'..."
wsl --unregister $DistroName 2>$null
Write-Host "Removing $InstallDir..."
Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
Write-Host "Lampy uninstalled." -ForegroundColor Green
