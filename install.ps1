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
    [string]$ReleaseTag = "",
    [string]$DownloadDir = "",
    [string]$InstallMode = "fresh",
    [string]$FallbackManifest = ""
)

$ErrorActionPreference = "Continue"
# Note: "Continue" (not "Stop") because native commands (wsl.exe, dism.exe)
# write to stderr, which PowerShell would otherwise treat as terminating.
# Real failures are caught via explicit throw and $LASTEXITCODE checks below.

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

$script:LogPath = $null
function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Write-Host $line
    if ($script:LogPath) { Add-Content -Path $script:LogPath -Value $line -ErrorAction SilentlyContinue }
}

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
    if ($start -gt 0) { Write-Log "  Resuming $dest at $start / $expectedSize bytes..." }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(6)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("Lampy-Installer/1.0")
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
        if ($start -gt 0) { $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($start, $null) }
        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ($start -gt 0 -and $resp.StatusCode -ne [System.Net.HttpStatusCode]::PartialContent) {
            Write-Log "  Server did not honor resume; restarting download from zero."
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
                    if ($expectedSize) { $pct = [math]::Round(100.0 * $total / $expectedSize, 1); Write-Log "  $total / $expectedSize bytes ($pct%)" }
                    else { Write-Log "  $total bytes..." }
                    $lastReport = [DateTime]::UtcNow
                }
            }
        } finally { $fs.Close() }
        return "downloaded"
    } finally { $client.Dispose(); $req.Dispose() }
}

function Get-ChunkWithRetry($url, $dest, $expectedSize) {
    # v1.0.2: transient drops on 1.8GB chunks are expected; retry up to 3 times.
    # Get-ChunkResumable resumes via HTTP Range, so each retry picks up where
    # the previous attempt stopped instead of starting over.
    for ($a = 1; $a -le 3; $a++) {
        try {
            return Get-ChunkResumable $url $dest $expectedSize
        } catch {
            Write-Log "  download attempt $a/3 failed: $($_.Exception.Message)"
            if ($a -eq 3) { throw "Download failed after 3 attempts: $url" }
            Write-Log "  waiting 10s, then resuming where it stopped..."
            Start-Sleep -Seconds 10
        }
    }
}

# ---------------------------------------------------------------------------
# Manifest-driven download (Installer_Requirements.md section 3).
# install.ps1 is the ONLY downloader. Every run appends to install.log.
# ---------------------------------------------------------------------------
if (-not $tarball) {
    Write-Step "Downloading Lampy system image"
    if ([string]::IsNullOrEmpty($DownloadDir)) { $dlDir = Join-Path $InstallDir "download" } else { $dlDir = $DownloadDir }
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $script:LogPath = Join-Path $dlDir "install.log"

    Write-Log "=== Lampy installer run ==="
    Write-Log "InstallDir=$InstallDir DownloadDir=$dlDir Mode=$InstallMode"

    # ---- Manifest discovery (REQ-M1/M2). Public endpoints only; no credentials.
    $manifest = $null; $manifestSource = ""; $wantTag = $ReleaseTag
    if ([string]::IsNullOrEmpty($wantTag)) {
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/cosbykit-afk/lampy-installer/releases/latest" -UseBasicParsing -TimeoutSec 30
            $wantTag = $rel.tag_name
            Write-Log "Latest installer release via public API: $wantTag"
        } catch { Write-Log "GitHub API unreachable ($($_.Exception.Message)); trying cached/bundled manifest." }
    } else { Write-Log "Release override: $wantTag" }
    if ($wantTag) {
        $murl = "https://raw.githubusercontent.com/cosbykit-afk/lampy-installer/$wantTag/manifest.json"
        try {
            $resp = Invoke-WebRequest -Uri $murl -UseBasicParsing -TimeoutSec 30
            $manifest = $resp.Content | ConvertFrom-Json
            $manifestSource = "network ($murl)"
        } catch { Write-Log "Manifest fetch failed: $murl ($($_.Exception.Message))" }
    }
    $cachedManifest = Join-Path $dlDir "manifest.json"
    if (-not $manifest -and (Test-Path $cachedManifest)) {
        try { $manifest = Get-Content $cachedManifest -Raw | ConvertFrom-Json; $manifestSource = "cache ($cachedManifest)" }
        catch { Write-Log "Cached manifest is corrupt; ignoring." }
    }
    if (-not $manifest -and $FallbackManifest -and (Test-Path $FallbackManifest)) {
        $manifest = Get-Content $FallbackManifest -Raw | ConvertFrom-Json
        $manifestSource = "bundled fallback"
    }
    if (-not $manifest) { throw "No manifest available: network, cache, and bundled fallback all failed." }
    Write-Log "Manifest source: $manifestSource | data release: $($manifest.data_release)"
    try { $manifest | ConvertTo-Json -Depth 6 | Set-Content $cachedManifest -ErrorAction Stop }
    catch { Write-Log "Could not cache manifest: $($_.Exception.Message)" }

    $chunks = @($manifest.chunks)
    $baseUrl = $manifest.base_url
    $tarballName = $manifest.tarball.name
    $tarballSize = [long]$manifest.tarball.size
    $tarballHash = $manifest.tarball.sha256
    if ($chunks.Count -eq 0) { throw "Manifest has no chunks." }
    Write-Log "$($chunks.Count) chunks, tarball $($tarballName) ($tarballSize bytes)."

    # ---- Legacy migration, one-time historical shim (REQ-D-FOLDER).
    $legacyDlDir = "C:\Lampy\download"
    if (($legacyDlDir -ne $dlDir) -and (Test-Path $legacyDlDir)) {
        foreach ($c in $chunks) {
            $legacyFile = Join-Path $legacyDlDir $c.name
            if (-not (Test-Path $legacyFile)) { continue }
            $dest = Join-Path $dlDir $c.name
            $legacyLen = (Get-Item $legacyFile).Length
            if (-not (Test-Path $dest)) {
                if ($legacyLen -ne [long]$c.size) { Write-Log "Legacy $($c.name) wrong size ($legacyLen/$($c.size)); ignoring." }
                else { Write-Log "Migrating legacy chunk: $($c.name)"; Move-Item $legacyFile $dest -Force }
            } elseif ((Get-Item $dest).Length -eq [long]$c.size) {
                Write-Log "Chunk $($c.name) already good; removing legacy duplicate."
                Remove-Item $legacyFile -Force
            } elseif ($legacyLen -eq [long]$c.size) {
                Write-Log "Legacy $($c.name) is complete but download-dir copy is partial; using legacy."
                Move-Item $legacyFile $dest -Force
            }
        }
    }

    $tarball = Join-Path $dlDir $tarballName

    function Test-Tarball($path) {
        if (-not (Test-Path $path)) { return $false }
        if ((Get-Item $path).Length -ne $tarballSize) {
            Write-Log "Collated tarball wrong size ($((Get-Item $path).Length)/$tarballSize); will rebuild from chunks."
            return $false
        }
        if ($tarballHash) {
            Write-Log "Verifying collated tarball SHA256 (10.7 GB, one moment)..."
            $actual = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $tarballHash) {
                Write-Log "Collated tarball FAILED hash check; will rebuild from chunks."
                return $false
            }
            Write-Log "Collated tarball hash OK."
        } else { Write-Log "Collated tarball size OK (no hash in manifest)." }
        return $true
    }

    if (-not (Test-Tarball $tarball)) {
        if (Test-Path $tarball) { Write-Log "Removing invalid tarball."; Remove-Item $tarball -Force }

        # ---- Inventory (REQ-I1..I3). Fresh measurement per file; a truncated
        # chunk can never read as complete.
        $i = 0
        $needDownload = @()
        foreach ($c in $chunks) {
            $i++
            $dest = Join-Path $dlDir $c.name
            $have = 0
            if (Test-Path $dest) { $have = (Get-Item $dest).Length }
            $want = [long]$c.size
            if ($have -eq $want) {
                Write-Log "Chunk $i/$($chunks.Count): $($c.name) already complete, skipping ($have bytes)."
            } elseif ($have -gt 0) {
                Write-Log "Chunk $i/$($chunks.Count): $($c.name) partial: have $have of $want bytes - will resume."
                $needDownload += $c
            } else {
                Write-Log "Chunk $i/$($chunks.Count): $($c.name) missing - will download ($want bytes)."
                $needDownload += $c
            }
        }

        # ---- Download (REQ-D1..D4): Range resume + 3 attempts per chunk.
        $i = 0
        foreach ($c in $needDownload) {
            $i++
            Write-Log "Downloading chunk $i/$($needDownload.Count): $($c.name)"
            Get-ChunkWithRetry "$baseUrl/$($c.name)" (Join-Path $dlDir $c.name) ([long]$c.size) | Out-Null
        }

        # ---- Verification (REQ-V1..V4). Bad chunks are deleted and fetched
        # once more; a second failure aborts. Good chunks are NEVER deleted.
        $attempt = 0
        do {
            $attempt++
            $bad = @()
            foreach ($c in $chunks) {
                $dest = Join-Path $dlDir $c.name
                $want = [long]$c.size
                $ok = (Test-Path $dest) -and ((Get-Item $dest).Length -eq $want)
                if ($ok -and $c.sha256) {
                    $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLower()
                    if ($actual -ne $c.sha256) {
                        Write-Log "  $($c.name) FAILED hash check (expected $($c.sha256), got $actual); will re-download."
                        $ok = $false
                    }
                } elseif ($ok) { Write-Log "  $($c.name) size OK ($want bytes)." }
                if (-not $ok) { $bad += $c }
            }
            foreach ($c in $bad) {
                $dest = Join-Path $dlDir $c.name
                Write-Log "Re-downloading $($c.name) ..."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
                Get-ChunkWithRetry "$baseUrl/$($c.name)" $dest ([long]$c.size) | Out-Null
            }
        } while ($bad.Count -gt 0 -and $attempt -lt 2)
        if ($bad.Count -gt 0) { throw "Chunk verification failed after re-download: $(($bad | ForEach-Object { $_.name }) -join ', ')" }
        Write-Log "All $($chunks.Count) chunks verified."

        Write-Log "Reassembling tarball..."
        $outStream = [System.IO.File]::Create($tarball)
        try {
            foreach ($c in $chunks) {
                $inStream = [System.IO.File]::OpenRead((Join-Path $dlDir $c.name))
                try { $inStream.CopyTo($outStream) } finally { $inStream.Close() }
            }
        } finally { $outStream.Close() }
        Write-Log "Tarball reassembled: $tarball"
        if (-not (Test-Tarball $tarball)) { throw "Reassembled tarball failed validation." }
    } else {
        Write-Log "Tarball already downloaded and verified: $tarball"
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
