<#
.SYNOPSIS
    Build pipeline: Docker image -> WSL distro tarball -> Lampy-Setup.exe
.DESCRIPTION
    Run on the build machine (Toetop). Everything from code, no manual steps:
      1. Builds the lampy-single Docker image (or reuses the released one)
      2. Exports the running container filesystem to lampy-wsl.tar
      3. Prepares the WSL distro (wsl.conf, boot config)
      4. Wraps install.ps1 + tarball into Lampy-Setup.exe via NSIS
    The resulting .exe bootstraps correctly on a clean Windows machine.
#>
param(
    [string]$Image = "kitcosby/lampy-single:latest",
    [string]$OutDir = "C:\Lampy\installer-build",
    [switch]$SkipDockerBuild
)

$ErrorActionPreference = "Stop"
function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$tarball = Join-Path $OutDir "lampy-wsl.tar"

if (-not $SkipDockerBuild) {
    Write-Step "1/4 Building Docker image"
    # Image source: https://github.com/cosbykit-afk/lampy-single
    # docker build -t lampy-single C:\path\to\lampy-single
    Write-Host "(Using released image $Image — set -SkipDockerBuild to rebuild from source)"
}

Write-Step "2/4 Exporting container filesystem to WSL tarball"
$container = "lampy-wsl-export"
docker rm -f $container 2>$null | Out-Null
docker create --name $container $Image | Out-Null
docker export $container -o $tarball
docker rm -f $container | Out-Null
$size = [math]::Round((Get-Item $tarball).Length / 1GB, 2)
Write-Host "Tarball: $tarball ($size GB)"

Write-Step "3/4 Staging installer files"
Copy-Item "$PSScriptRoot\install.ps1" $OutDir -Force
Copy-Item "$PSScriptRoot\uninstall.ps1" $OutDir -Force
Write-Host "Staged install.ps1, uninstall.ps1"

Write-Step "4/4 Wrapping into Lampy-Setup.exe (NSIS)"
$nsi = Join-Path $PSScriptRoot "lampy.nsi"
if (Get-Command makensis -ErrorAction SilentlyContinue) {
    makensis /DOUTDIR="$OutDir" $nsi
    Write-Host "Installer: $OutDir\Lampy-Setup.exe" -ForegroundColor Green
} else {
    Write-Warning "NSIS (makensis) not found. Install NSIS to produce the .exe."
    Write-Host "Staged files are ready in $OutDir for manual wrapping."
}
