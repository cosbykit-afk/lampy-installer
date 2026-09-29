<#
.SYNOPSIS
    Uninstall Lampy: remove WSL distro, scheduled task, and install directory.
.DESCRIPTION
    Per-user uninstall (no admin required). Only removes the scheduled task
    if it belongs to the distro being uninstalled (checked via the task's
    command line). Asks for confirmation before deleting.
#>
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Lampy",
    [string]$DistroName = "lampy",
    [string]$TaskName = "Lampy",
    [switch]$Force
)
$ErrorActionPreference = "Stop"

if (-not $Force) {
    Write-Output "This will remove:"
    Write-Output "  - WSL distro '$DistroName' (ALL DATA inside it will be DELETED)"
    Write-Output "  - Scheduled task '$TaskName' (if it belongs to this distro)"
    Write-Output "  - Install directory '$InstallDir'"
    $ans = Read-Host "Type YES (all caps) to confirm uninstall"
    if ($ans -cne "YES") { Write-Output "Uninstall cancelled."; exit 0 }
}

# Only remove the scheduled task if it's for THIS distro. The task's
# command line contains "-d <distro>", so we check for that.
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $action = ($task.Actions | Select-Object -First 1).Arguments
    if ($action -match "-d\s+$DistroName\b") {
        Write-Output "Removing scheduled task '$TaskName' (belongs to '$DistroName')..."
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        Write-Output "Scheduled task '$TaskName' is for a different distro; leaving it."
    }
} else {
    Write-Output "Scheduled task '$TaskName' not found; skipping."
}

Write-Output "Unregistering WSL distro '$DistroName'..."
wsl --unregister $DistroName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Output "Warning: wsl --unregister failed (distro may not exist)."
}

Write-Output "Removing $InstallDir..."
Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
Write-Output "Lampy uninstalled."
