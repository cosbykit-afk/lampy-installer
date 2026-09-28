<#
.SYNOPSIS
    Lampy installer logic. Bundled into Lampy-Setup.exe, runs on the target machine.
.DESCRIPTION
    Installs the Lampy stack via WSL2:
      1. Ensures WSL2 is enabled and set as default
      2. Imports the lampy WSL distro from the bundled tarball
      3. Configures supervisord to launch all 7 services
      4. Registers a Scheduled Task to start Lampy on Windows boot
      5. Verifies all services are responding
    Idempotent: safe to re-run. Requires Administrator.
#>
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Lampy",
    [string]$DistroName = "lampy",
    [string]$TarballPath = "",
    [string]$ReleaseTag = "v1.0.0"
)

$ErrorActionPreference = "Continue"
# Note: "Continue" (not "Stop") because native commands (wsl.exe, dism.exe)
# write to stderr, which PowerShell would otherwise treat as terminating.
# Real failures are caught via explicit throw and $LASTEXITCODE checks below.

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# Must run as Administrator
$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw "Lampy installer must run as Administrator." }

# Locate the tarball: explicit path, local file, or download from GitHub Releases
$tarball = $TarballPath
if (-not $tarball) {
    $localTar = Join-Path $PSScriptRoot "lampy-public.tar"
    if (Test-Path $localTar) {
        $tarball = $localTar
        Write-Host "Using local tarball: $tarball"
    }
}
if (-not $tarball) {
    # Download chunked tarball from GitHub Releases and reassemble
    Write-Step "Downloading Lampy system image (10.6 GB in 2 GB chunks)"
    $releaseUrl = "https://github.com/cosbykit-afk/lampy-installer/releases/download/$ReleaseTag"
    if ([string]::IsNullOrEmpty($DownloadDir)) { $dlDir = Join-Path $InstallDir "download" } else { $dlDir = $DownloadDir }
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    # Migrate chunks from legacy C:\Lampy\download (previous installer versions)
    $legacyDlDir = "C:\Lampy\download"
    if (($legacyDlDir -ne $dlDir) -and (Test-Path $legacyDlDir)) {
        Get-ChildItem -Path $legacyDlDir -Filter "lampy-public.tar.part-*" | ForEach-Object {
            $dest = Join-Path $dlDir $_.Name
            $needsDownload = $true
            if (Test-Path $dest) {
                $actualSize = (Get-Item $dest).Length
                $expectedSize = $chunkSizes[$chunkName]
                if ($expectedSize -and ($actualSize -eq $expectedSize)) {
                    $needsDownload = $false
                } else {
                    Write-Host "Chunk $chunkName is incomplete ($actualSize / $expectedSize bytes), re-downloading..."
                    Remove-Item $dest -Force
                }
            }
            if ($needsDownload) {
                Write-Host "Migrating chunk from legacy location: $($_.Name)"
                Move-Item $_.FullName $dest -Force
            }
        }
    }
    $tarball = Join-Path $dlDir "lampy-public.tar"
    if (-not (Test-Path $tarball)) {
        # Get chunk list: try GitHub API first (works for any release tag),
        # fall back to hardcoded v1.0.0 chunks if API fails (rate limit, etc.)
        $chunkNames = @()
        try {
            $apiUrl = "https://api.github.com/repos/cosbykit-afk/lampy-installer/releases/tags/$ReleaseTag"
            $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 30
            $assets = $release.assets | Where-Object { $_.name -like "lampy-public.tar.part-*" } | Sort-Object name
            $chunkSizes = @{}
            foreach ($a in $assets) { $chunkNames += $a.name; $chunkSizes[$a.name] = $a.size }
            Write-Host "Found $($chunkNames.Count) chunks via API."
        } catch {
            Write-Host "API lookup failed ($($_.Exception.Message)), using v1.0.0 chunk list."
        }
        if ($chunkNames.Count -eq 0 -and ($ReleaseTag -eq "v1.0.0" -or $ReleaseTag -eq "v1.0.0-slim")) {
            # Fallback: v1.0.0 has part-aa through part-ag
            $chunkNames = @("lampy-public.tar.part-aa", "lampy-public.tar.part-ab", "lampy-public.tar.part-ac", "lampy-public.tar.part-ad", "lampy-public.tar.part-ae", "lampy-public.tar.part-af", "lampy-public.tar.part-ag")
            Write-Host "Using hardcoded v1.0.0 chunk list ($($chunkNames.Count) chunks)."
            $chunkSizes = @{
                "lampy-public.tar.part-aa" = 1887436800
                "lampy-public.tar.part-ab" = 1887436800
                "lampy-public.tar.part-ac" = 1887436800
                "lampy-public.tar.part-ad" = 1887436800
                "lampy-public.tar.part-ae" = 1887436800
                "lampy-public.tar.part-af" = 1887436800
                "lampy-public.tar.part-ag" = 228433920
            }
        }
        if ($chunkNames.Count -eq 0) { throw "No tarball chunks found for release $ReleaseTag" }
        $baseUrl = "https://github.com/cosbykit-afk/lampy-installer/releases/download/$ReleaseTag"
        $i = 0
        foreach ($chunkName in $chunkNames) {
            $i++
            $dest = Join-Path $dlDir $chunkName
            if (-not (Test-Path $dest)) {
                $url = "$baseUrl/$chunkName"
                Write-Host "Downloading chunk $i/$($chunkNames.Count): $chunkName..."
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
            } else {
                Write-Host "Chunk $i/$($chunkNames.Count) already present, skipping."
            }
        }
        Write-Host "Reassembling tarball..."
        $outStream = [System.IO.File]::Create($tarball)
        try {
            foreach ($chunkName in $chunkNames) {
                $inStream = [System.IO.File]::OpenRead((Join-Path $dlDir $chunkName))
                try { $inStream.CopyTo($outStream) } finally { $inStream.Close() }
            }
        } finally { $outStream.Close() }
        Write-Host "Tarball reassembled: $tarball"
    } else {
        Write-Host "Tarball already downloaded: $tarball"
    }
}
if (-not (Test-Path $tarball)) { throw "Tarball not found: $tarball" }

Write-Step "1/5 Ensuring WSL2 is available"
$wslOk = $false
try {
    $wslList = wsl --list --verbose 2>&1
    $wslOk = ($LASTEXITCODE -eq 0)
} catch {
    $wslOk = $false
}
if (-not $wslOk) {
    Write-Host "Enabling WSL..."
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Host "WSL enabled. A reboot is required, then re-run the installer."
    exit 2
}
wsl --set-default-version 2 | Out-Null

Write-Step "2/5 Importing lampy WSL distro"
$wslDir = Join-Path $InstallDir "wsl"
New-Item -ItemType Directory -Force -Path $wslDir | Out-Null
# WSL distros are per-user (HKCU). Run as the user, NOT admin.
$existing = wsl --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $DistroName }
if ($existing) {
    Write-Host "Distro '$DistroName' already registered -- unregistering for a clean import."
    wsl --unregister $DistroName
}
wsl --import $DistroName $wslDir $tarball
if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }

Write-Step "3/5 Configuring services inside WSL"
# The image ships /etc/supervisor/conf.d/lampy.conf with all 7 services, but it
# is Docker-specific. Apply WSL adaptations:
wsl -d $DistroName -u root bash -c "mkdir -p /var/run/supervisor /var/log/supervisor /var/run/postgresql; chown postgres:postgres /var/run/postgresql; chmod 2775 /var/run/postgresql; ln -sf /usr/lib/postgresql/16/bin/postgres /usr/local/bin/postgres; ln -sf /usr/lib/postgresql/16/bin/pg_ctl /usr/local/bin/pg_ctl; ln -sf /usr/lib/postgresql/16/bin/initdb /usr/local/bin/initdb"

# Fix postgres program environment: needs both PATH and PGDATA for WSL
# (wsl-envfix.py ships alongside this script; piped to python3 via stdin)
Get-Content -Path (Join-Path $PSScriptRoot "wsl-envfix.py") -Raw | wsl -d $DistroName -u root python3
if ($LASTEXITCODE -ne 0) { throw "wsl-envfix.py failed" }

# Boot supervisord on every WSL distro start

Write-Step "4/5 Registering boot startup (Task Scheduler)"
$taskName = "Lampy"
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $DistroName -u root /usr/local/bin/lampy-boot.sh"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Write-Host "Scheduled task '$taskName' registered."

Write-Step "5/5 Starting Lampy and verifying"
Start-ScheduledTask -TaskName $taskName
Write-Host "Waiting for services to boot..."
Start-Sleep -Seconds 60
$checks = @(
    @{ Name = "PostgreSQL"; Cmd = "wsl -d $DistroName -u root pg_isready -h localhost" },
    @{ Name = "Apache";     Url = "http://localhost:80/" },
    @{ Name = "Forum";      Url = "http://localhost:80/app/" },
    @{ Name = "Ollama";     Url = "http://localhost:11434/" },
    @{ Name = "code-server"; Url = "http://localhost:8080/" }
)
$failed = 0
foreach ($c in $checks) {
    if ($c.Cmd) {
        Invoke-Expression $c.Cmd | Out-Null
        $ok = $LASTEXITCODE -eq 0
    } else {
        try { $r = Invoke-WebRequest -Uri $c.Url -UseBasicParsing -TimeoutSec 10; $ok = $r.StatusCode -eq 200 }
        catch { $ok = $false }
    }
    if ($ok) { $status = "OK" } else { $status = "FAILED"; $failed++ }
    Write-Host ("  {0}: {1}" -f $c.Name, $status)
}

if ($failed -gt 0) {
    Write-Warning "$failed service check(s) failed. See output above."
    exit 1
}
Write-Host "`nLampy installed and running." -ForegroundColor Green
Write-Host "Forum:       http://localhost/app/"
Write-Host "R Theory:    http://localhost/r-theory/"
Write-Host "code-server: http://localhost:8080/"
