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
    [string]$ReleaseTag = "v1.0.0-slim"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# Must run as Administrator
$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw "Lampy installer must run as Administrator." }

# Locate the tarball: explicit path, local file, or download from GitHub Releases
$tarball = $TarballPath
if (-not $tarball) {
    $localTar = Join-Path $PSScriptRoot "lampy-wsl-slim.tar"
    if (Test-Path $localTar) {
        $tarball = $localTar
        Write-Host "Using local tarball: $tarball"
    }
}
if (-not $tarball) {
    # Download chunked tarball from GitHub Releases and reassemble
    Write-Step "Downloading Lampy system image (10.6 GB in 2 GB chunks)"
    $releaseUrl = "https://github.com/cosbykit-afk/lampy-installer/releases/download/$ReleaseTag"
    $dlDir = Join-Path $InstallDir "download"
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $tarball = Join-Path $dlDir "lampy-wsl-slim.tar"
    if (-not (Test-Path $tarball)) {
        # Discover chunk count from the release metadata
        $apiUrl = "https://api.github.com/repos/cosbykit-afk/lampy-installer/releases/tags/$ReleaseTag"
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
        $chunks = $release.assets | Where-Object { $_.name -like "lampy-wsl-slim.tar.part*" } | Sort-Object name
        if (-not $chunks) { throw "No tarball chunks found in release $ReleaseTag" }
        Write-Host "Found $($chunks.Count) chunks."
        $i = 0
        foreach ($chunk in $chunks) {
            $i++
            $dest = Join-Path $dlDir $chunk.name
            if (-not (Test-Path $dest)) {
                Write-Host "Downloading chunk $i/$($chunks.Count): $($chunk.name)..."
                Invoke-WebRequest -Uri $chunk.browser_download_url -OutFile $dest -UseBasicParsing
            } else {
                Write-Host "Chunk $i/$($chunks.Count) already present, skipping."
            }
        }
        Write-Host "Reassembling tarball..."
        $outStream = [System.IO.File]::Create($tarball)
        try {
            foreach ($chunk in $chunks) {
                $inStream = [System.IO.File]::OpenRead((Join-Path $dlDir $chunk.name))
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
$wslList = wsl --list --verbose 2>&1
if ($LASTEXITCODE -ne 0) {
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
$existing = wsl --list --quiet | Where-Object { $_ -eq $DistroName }
if ($existing) {
    Write-Host "Distro '$DistroName' already registered — unregistering for a clean import."
    wsl --unregister $DistroName
}
wsl --import $DistroName $wslDir $tarball
if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }

Write-Step "3/5 Configuring services inside WSL"
# The image ships /etc/supervisor/conf.d/lampy.conf with all 7 services, but it
# is Docker-specific. Apply WSL adaptations:
wsl -d $DistroName -u root bash -c @'
set -e
# Directories that Docker creates at container start
mkdir -p /var/run/supervisor /var/log/supervisor /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql
# postgres binaries are not on the default WSL PATH
ln -sf /usr/lib/postgresql/16/bin/postgres /usr/local/bin/postgres
ln -sf /usr/lib/postgresql/16/bin/pg_ctl /usr/local/bin/pg_ctl
ln -sf /usr/lib/postgresql/16/bin/initdb /usr/local/bin/initdb
'@

# Append supervisor RPC sections (needed for supervisorctl) if missing
$hasRpc = wsl -d $DistroName -u root grep -c "unix_http_server" /etc/supervisor/conf.d/lampy.conf
if ($hasRpc -eq "0") {
    wsl -d $DistroName -u root python3 -c @'
open("/etc/supervisor/conf.d/lampy.conf","a").write("""
[unix_http_server]
file=/var/run/supervisor/supervisor.sock

[supervisorctl]
serverurl=unix:///var/run/supervisor/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
""")
'@
}

# Fix postgres program environment: needs both PATH and PGDATA for WSL
wsl -d $DistroName -u root python3 -c @'
import re
p = "/etc/supervisor/conf.d/lampy.conf"
c = open(p).read()
fixed = "environment=PATH=\"/usr/lib/postgresql/16/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\",PGDATA=\"/home/postgres/pgdata/data\""
c = re.sub(r"\[program:postgres\].*?(?=\n\[)",
            lambda m: re.sub(r"^environment=.*$", fixed, m.group(0), flags=re.M),
            c, flags=re.S)
# pgai-worker needs POSTGRES_PASSWORD (defaults match the image)
c = re.sub(r"\[program:pgai-worker\].*?(?=\n\[)",
            lambda m: re.sub(r"^command=",
                             "environment=POSTGRES_PASSWORD=\"password\"\ncommand=",
                             m.group(0), flags=re.M),
            c, flags=re.S)
open(p,"w").write(c)
print("wsl config patched")
'@

# Boot supervisord on every WSL distro start
wsl -d $DistroName -u root bash -c @'
cat > /etc/wsl.conf <<EOF
[boot]
command = supervisord -c /etc/supervisor/conf.d/lampy.conf
EOF
echo "wsl.conf written"
'@

Write-Step "4/5 Registering boot startup (Task Scheduler)"
$taskName = "Lampy"
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $DistroName -u root supervisord -c /etc/supervisor/conf.d/lampy.conf"
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
    Write-Host ("  {0}: {1}" -f $c.Name, $(if ($ok) { "OK" } else { "FAILED" }))
    if (-not $ok) { $failed++ }
}

if ($failed -gt 0) {
    Write-Warning "$failed service check(s) failed. See output above."
    exit 1
}
Write-Host "`nLampy installed and running." -ForegroundColor Green
Write-Host "Forum:       http://localhost/app/"
Write-Host "R Theory:    http://localhost/r-theory/"
Write-Host "code-server: http://localhost:8080/"
