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
    Idempotent: safe to re-run. Runs per-user (no elevation needed).
    Elevation is only required for the one-time WSL feature enablement;
    if WSL is already available the whole install runs unelevated.
#>
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Lampy",
    [string]$DistroName = "lampy",
    [string]$TarballPath = "",
    [string]$ReleaseTag = "v1.0.0",
    [string]$DownloadDir = "",
    [string]$InstallMode = "fresh"
)

$ErrorActionPreference = "Continue"
# Note: "Continue" (not "Stop") because native commands (wsl.exe, dism.exe)
# write to stderr, which PowerShell would otherwise treat as terminating.
# Real failures are caught via explicit throw and $LASTEXITCODE checks below.

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# Elevation is NOT required for a per-user install (WSL distros are per-user,
# registered under HKCU). Only the one-time WSL feature enablement needs it.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Locate the tarball: explicit path, local file, or download from GitHub Releases
$tarball = $TarballPath
if (-not $tarball) {
    $localTar = Join-Path $PSScriptRoot "lampy-public.tar"
    if (Test-Path $localTar) {
        $tarball = $localTar
        Write-Host "Using local tarball: $tarball"
    }
}

function Get-ChunkResumable($url, $dest, $expectedSize) {
    # Downloads with HTTP Range resume. Skips when the local file already
    # matches the expected size. Restarts from zero if the server ignores Range.
    $start = 0
    if (Test-Path $dest) { $start = (Get-Item $dest).Length }
    if ($expectedSize -and ($start -eq $expectedSize)) { return "already-complete" }
    if ($start -gt 0) { Write-Host "  Resuming $dest at $start / $expectedSize bytes..." }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(6)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("Lampy-Installer/1.0")
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
        if ($start -gt 0) { $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($start, $null) }
        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ($start -gt 0 -and $resp.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent) {
            Write-Host "  Server did not honor resume; restarting download from zero."
            $start = 0
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
        $resp.EnsureSuccessStatusCode() | Out-Null
        $mode = if (($start -gt 0)) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $fs = New-Object System.IO.FileStream($dest, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $buf = New-Object byte[] 1048576
            $total = $start
            $lastReport = [DateTime]::UtcNow
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $total += $n
                if (([DateTime]::UtcNow - $lastReport).TotalSeconds -ge 15) {
                    if ($expectedSize) { $pct = [math]::Round(100.0 * $total / $expectedSize, 1); Write-Host "  $total / $expectedSize bytes ($pct%)" }
                    else { Write-Host "  $total bytes..." }
                    $lastReport = [DateTime]::UtcNow
                }
            }
        } finally { $fs.Close() }
        return "downloaded"
    } finally { $client.Dispose(); $req.Dispose() }
}

function Get-ChunkHashes($manifestPath) {
    $hashes = @{}
    if (Test-Path $manifestPath) {
        foreach ($line in (Get-Content $manifestPath)) {
            if ($line -match "^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$") { $hashes[$matches[2]] = $matches[1].ToLower() }
        }
    }
    return $hashes
}

if (-not $tarball) {
    Write-Step "Downloading Lampy system image (10.6 GB in 2 GB chunks)"
    $releaseUrl = "https://github.com/cosbykit-afk/lampy-installer/releases/download/$ReleaseTag"
    if ([string]::IsNullOrEmpty($DownloadDir)) { $dlDir = Join-Path $InstallDir "download" } else { $dlDir = $DownloadDir }
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null

    # Chunk list + expected sizes: GitHub API first (works for any release tag),
    # fall back to the hardcoded v1.0.0 list if the API fails.
    $chunkNames = @()
    $chunkSizes = @{}
    try {
        $apiUrl = "https://api.github.com/repos/cosbykit-afk/lampy-installer/releases/tags/$ReleaseTag"
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 30
        $assets = $release.assets | Where-Object { $_.name -like "lampy-public.tar.part-*" } | Sort-Object name
        foreach ($a in $assets) { $chunkNames += $a.name; $chunkSizes[$a.name] = $a.size }
        Write-Host "Found $($chunkNames.Count) chunks via API."
    } catch {
        Write-Host "API lookup failed ($($_.Exception.Message)), using v1.0.0 chunk list."
    }
    if ($chunkNames.Count -eq 0 -and ($ReleaseTag -eq "v1.0.0" -or $ReleaseTag -eq "v1.0.0-slim")) {
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

    # SHA256 manifest for verification (release asset; also honored if already local)
    $manifestPath = Join-Path $dlDir "lampy-public.tar.sha256"
    if (-not (Test-Path $manifestPath)) {
        try {
            Invoke-WebRequest -Uri "$releaseUrl/lampy-public.tar.sha256" -OutFile $manifestPath -UseBasicParsing -TimeoutSec 30
            Write-Host "Downloaded chunk hash manifest."
        } catch { Write-Host "No hash manifest available; will verify by size only." }
    }
    $hashes = Get-ChunkHashes $manifestPath

    # Migrate chunks from the legacy C:\Lampy\download location (previous installer
    # versions). A legacy chunk is only accepted when its size matches the release;
    # a good chunk already in the download dir is NEVER deleted by migration.
    $legacyDlDir = "C:\Lampy\download"
    if (($legacyDlDir -ne $dlDir) -and (Test-Path $legacyDlDir)) {
        foreach ($legacyFile in (Get-ChildItem -Path $legacyDlDir -Filter "lampy-public.tar.part-*")) {
            $dest = Join-Path $dlDir $legacyFile.Name
            $expected = $chunkSizes[$legacyFile.Name]
            if (-not (Test-Path $dest)) {
                if ($expected -and ($legacyFile.Length -ne $expected)) {
                    Write-Host "Legacy chunk $($legacyFile.Name) has wrong size ($($legacyFile.Length)/$expected); ignoring."
                } else {
                    Write-Host "Migrating chunk from legacy location: $($legacyFile.Name)"
                    Move-Item $legacyFile.FullName $dest -Force
                }
            } elseif ($expected -and ((Get-Item $dest).Length -eq $expected)) {
                Write-Host "Chunk $($legacyFile.Name) already good in download dir; removing legacy duplicate."
                Remove-Item $legacyFile.FullName -Force
            }
        }
    }

    $tarball = Join-Path $dlDir "lampy-public.tar"
    if (-not (Test-Path $tarball)) {
        $baseUrl = "https://github.com/cosbykit-afk/lampy-installer/releases/download/$ReleaseTag"
        $i = 0
        foreach ($chunkName in $chunkNames) {
            $i++
            $dest = Join-Path $dlDir $chunkName
            $expected = $chunkSizes[$chunkName]
            Write-Host "Chunk $i/$($chunkNames.Count): $chunkName"
            $r = Get-ChunkResumable "$baseUrl/$chunkName" $dest $expected
            if ($r -eq "already-complete") { Write-Host "  already present, skipping." }
        }
        # Verify: size always, SHA256 when the manifest is available.
        # Bad chunks are deleted and re-downloaded once; a second failure aborts.
        $attempt = 0
        do {
            $attempt++
            $bad = @()
            foreach ($chunkName in $chunkNames) {
                $dest = Join-Path $dlDir $chunkName
                $expected = $chunkSizes[$chunkName]
                $ok = (Test-Path $dest) -and ((Get-Item $dest).Length -eq $expected)
                if ($ok -and $hashes.ContainsKey($chunkName)) {
                    $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLower()
                    if ($actual -ne $hashes[$chunkName]) {
                        Write-Host "  $chunkName FAILED hash check; will re-download."
                        $ok = $false
                    }
                } elseif ($ok) {
                    Write-Host "  $chunkName size OK."
                }
                if (-not $ok) { $bad += $chunkName }
            }
            foreach ($chunkName in $bad) {
                $dest = Join-Path $dlDir $chunkName
                Write-Host "Re-downloading $chunkName ..."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
                Get-ChunkResumable "$baseUrl/$chunkName" $dest $chunkSizes[$chunkName] | Out-Null
            }
        } while ($bad.Count -gt 0 -and $attempt -lt 2)
        if ($bad.Count -gt 0) { throw "Chunk verification failed after re-download: $($bad -join ', ')" }
        Write-Host "All $($chunkNames.Count) chunks verified."
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
    if (-not $isAdmin) {
        throw "WSL is not installed. Re-run this installer once AS ADMINISTRATOR to enable WSL, then re-run it normally."
    }
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
if ($InstallMode -eq "repair" -and $existing) {
    Write-Host "Repair mode: distro '$DistroName' already registered -- skipping import, re-running configuration."
} else {
    if ($existing) {
        Write-Host "Distro '$DistroName' already registered -- unregistering for a clean import."
        wsl --unregister $DistroName
    }
    wsl --import $DistroName $wslDir $tarball
    if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }
}

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
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
if ($isAdmin) {
    # Elevated: machine boot task as SYSTEM (previous behavior)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
} else {
    # Per-user install: start Lampy at logon as the installing user.
    # (WSL distros are per-user; a SYSTEM task would not see this user's distro.)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
}
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
