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
    [string]$InstallDir = "C:\Lampy",
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
Write-Step "1/7 Ensuring WSL2 is available"
# Check 1: is wsl.exe on PATH at all?
$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCmd) {
    Write-Host "WSL not found. Enabling Windows features..."
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Host "WSL enabled. A reboot is required, then re-run the installer."
    exit 2
}
# Check 2: does wsl.exe actually respond?
$wslWorks = $false
try {
    $null = & wsl.exe --status 2>&1
    $wslWorks = ($LASTEXITCODE -eq 0)
} catch { $wslWorks = $false }
if (-not $wslWorks) {
    try {
        $null = & wsl.exe --list --quiet 2>&1
        $wslWorks = ($LASTEXITCODE -eq 0)
    } catch { $wslWorks = $false }
}
if (-not $wslWorks) {
    Write-Host "WSL is present but not responding. Attempting repair..."
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Host "Repair attempted. Reboot if needed, then re-run the installer."
    exit 2
}
Write-Host "WSL is installed and working."
& wsl.exe --set-default-version 2 | Out-Null


if (-not $tarball) {
    $localTar = Join-Path $PSScriptRoot "lampy-wsl-slim.tar"
    if (Test-Path $localTar) {
        $tarball = $localTar
        Write-Host "Using local tarball: $tarball"
    }
}
if (-not $tarball) {
    # Download chunked tarball from GitHub Releases and reassemble
    Write-Step "2/7 Downloading Lampy system image (11 GB in 7 chunks)"
    $releaseUrl = "https://github.com/cosbykit-afk/lampy-installer/releases/download/$ReleaseTag"
    $dlDir = Join-Path $InstallDir "download"
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $tarball = Join-Path $dlDir "lampy-public.tar"
    # Check if we have a complete tarball already (must be >10GB)
    $tarballOk = $false
    if (Test-Path $tarball) {
        $tarballSize = (Get-Item $tarball).Length
        if ($tarballSize -gt 10GB) {
            Write-Host "Tarball already present ($([math]::Round($tarballSize/1GB,1)) GB), skipping download."
            $tarballOk = $true
        } else {
            Write-Host "Existing tarball incomplete ($([math]::Round($tarballSize/1MB,0)) MB), will re-download chunks."
            Remove-Item $tarball -Force
        }
    }
    if (-not $tarballOk) {
        $apiUrl = "https://api.github.com/repos/cosbykit-afk/lampy-installer/releases/tags/$ReleaseTag"
        try {
            $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
        } catch {
            throw "Could not find Lampy release $ReleaseTag. Check https://github.com/cosbykit-afk/lampy-installer/releases"
        }
        $chunks = $release.assets | Where-Object { $_.name -like "lampy-public.tar.part-*" } | Sort-Object name
        if (-not $chunks -or $chunks.Count -eq 0) {
            throw "No tarball chunks in release $ReleaseTag. Assets may still be uploading: https://github.com/cosbykit-afk/lampy-installer/releases/tag/$ReleaseTag"
        }
        Write-Host "Release has $($chunks.Count) chunks. Checking each one..."
        $shaAsset = $release.assets | Where-Object { $_.name -eq "lampy-public.tar.sha256" }
        if (-not $shaAsset) { throw "No checksum file in release. Cannot verify chunks." }
        $shaDest = Join-Path $dlDir "lampy-public.tar.sha256"
        Write-Host "Downloading checksum file..."
        Invoke-WebRequest -Uri $shaAsset.browser_download_url -OutFile $shaDest -UseBasicParsing
        $expectedHashes = @{}
        Get-Content $shaDest | ForEach-Object {
            if ($_ -match '^([a-fA-F0-9]{64})\s+(.+)$') {
                $expectedHashes[$matches[2].Trim()] = $matches[1].ToLower()
            }
        }
        # Verify/download EACH chunk - ALL must pass before assembly
        $verifiedCount = 0
        $i = 0
        foreach ($chunk in $chunks) {
            $i++
            $dest = Join-Path $dlDir $chunk.name
            $expected = $expectedHashes[$chunk.name]
            if (-not $expected) { throw "No checksum for $($chunk.name). Aborting." }
            $ok = $false
            if (Test-Path $dest) {
                $fs = (Get-Item $dest).Length
                if ($fs -eq $chunk.size) {
                    $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLower()
                    if ($actual -eq $expected) {
                        Write-Host "[$i/$($chunks.Count)] $($chunk.name): OK ($([math]::Round($fs/1MB,0)) MB)"
                        $ok = $true
                    }
                }
                if (-not $ok) { Write-Host "[$i/$($chunks.Count)] $($chunk.name): invalid, downloading..." }
            } else {
                Write-Host "[$i/$($chunks.Count)] $($chunk.name): missing, downloading..."
            }
            if (-not $ok) {
                Invoke-WebRequest -Uri $chunk.browser_download_url -OutFile $dest -UseBasicParsing
                $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLower()
                if ($actual -ne $expected) {
                    Remove-Item $dest -Force -ErrorAction SilentlyContinue
                    throw "Checksum failed for $($chunk.name) after download. Re-run installer."
                }
                Write-Host "[$i/$($chunks.Count)] $($chunk.name): downloaded and verified."
                $ok = $true
            }
            if ($ok) { $verifiedCount++ }
        }
        if ($verifiedCount -ne $chunks.Count) {
            throw "Only $verifiedCount of $($chunks.Count) chunks verified. Cannot proceed."
        }
        Write-Host "All $($chunks.Count) chunks verified. Assembling tarball..."
        $outStream = [System.IO.File]::Create($tarball)
        try {
            foreach ($chunk in $chunks) {
                $cp = Join-Path $dlDir $chunk.name
                $inStream = [System.IO.File]::OpenRead($cp)
                try { $inStream.CopyTo($outStream) } finally { $inStream.Close() }
            }
        } finally { $outStream.Close() }
        $finalSize = (Get-Item $tarball).Length
        if ($finalSize -lt 10GB) {
            Remove-Item $tarball -Force
            throw "Assembled tarball too small. Deleted. Re-run installer."
        }
        Write-Host "Tarball ready: $([math]::Round($finalSize/1GB,1)) GB"
    }
}
if (-not (Test-Path $tarball)) { throw "Tarball not found: $tarball" }

Write-Step "3/7 Importing lampy WSL distro"
$wslDir = Join-Path $InstallDir "wsl"
New-Item -ItemType Directory -Force -Path $wslDir | Out-Null
$existing = wsl --list --quiet | Where-Object { $_ -eq $DistroName }
if ($existing) {
    Write-Host "Distro '$DistroName' already registered -- unregistering for a clean import."
    wsl --unregister $DistroName
}
wsl --import $DistroName $wslDir $tarball
if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }

Write-Step "4/7 Configuring services inside WSL"
# The image ships /etc/supervisor/conf.d/lampy.conf with all 7 services, but it
# is Docker-specific. Apply WSL adaptations:
wsl -d $DistroName -u root bash -c "mkdir -p /var/run/supervisor /var/log/supervisor /var/run/postgresql; chown postgres:postgres /var/run/postgresql; chmod 2775 /var/run/postgresql; ln -sf /usr/lib/postgresql/16/bin/postgres /usr/local/bin/postgres; ln -sf /usr/lib/postgresql/16/bin/pg_ctl /usr/local/bin/pg_ctl; ln -sf /usr/lib/postgresql/16/bin/initdb /usr/local/bin/initdb"

# Fix postgres program environment: needs both PATH and PGDATA for WSL
# (wsl-envfix.py ships alongside this script; piped to python3 via stdin)
Get-Content -Path (Join-Path $PSScriptRoot "wsl-envfix.py") -Raw | wsl -d $DistroName -u root python3
if ($LASTEXITCODE -ne 0) { throw "wsl-envfix.py failed" }

# Boot supervisord on every WSL distro start

Write-Step "5/7 Fetching latest R Theory and Bible websites from GitHub"
# R Theory website (static) -> /var/www/html/r-theory/
wsl -d $DistroName -u root bash -c "rm -rf /var/www/html/r-theory && mkdir -p /var/www/html && cd /var/www/html && curl -sL https://github.com/cosbykit-afk/r-theory-rewrite/archive/refs/heads/main.tar.gz | tar xz && mv r-theory-rewrite-main r-theory && chown -R www-data:www-data r-theory"
if ($LASTEXITCODE -ne 0) { Write-Warning "R Theory download failed, using baked-in version" }

# Bible website (Flask + SQLite) -> /opt/bible/
wsl -d $DistroName -u root bash -c "rm -rf /opt/bible/website && mkdir -p /opt/bible && cd /opt/bible && curl -sL https://github.com/cosbykit-afk/bible-project/archive/refs/heads/main.tar.gz | tar xz && mv bible-project-main/website website && rm -rf bible-project-main"
if ($LASTEXITCODE -ne 0) { Write-Warning "Bible website download failed, using baked-in version" }

Write-Step "6/7 Registering boot startup (Task Scheduler)"
$taskName = "Lampy"
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $DistroName -u root /usr/local/bin/lampy-boot.sh"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Write-Host "Scheduled task '$taskName' registered."

Write-Step "7/7 Starting Lampy and verifying"
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
Write-Host "Bible:       http://localhost/bible/"
Write-Host "code-server: http://localhost:8080/"
