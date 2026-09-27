# Lampy for Windows

Lampy is a self-hosted forum stack with AI features: PostgreSQL + TimescaleDB,
Apache, Ollama (local LLM), Apache James (mail), code-server, pgAI vectorizer,
and the Flask forum app. This installer runs it on Windows via WSL2 —
no Docker required.

## Requirements

- Windows 10 version 2004+ or Windows 11 (64-bit)
- 25 GB free disk space (the install is ~20 GB)
- 8 GB RAM minimum, 16 GB recommended
- Administrator rights (for the install only)
- Internet access (for the initial download)

## Install

1. Download **install.ps1** and **uninstall.ps1** from this repo
   (or clone it).
2. Right-click PowerShell → **Run as administrator**.
3. Run:
   ```powershell
   .\install.ps1
   ```
4. The installer will:
   - Download the Lampy system image (10.6 GB, in 2 GB chunks from
     GitHub Releases) — this takes a while on first run
   - Enable WSL2 if it isn't already (may ask you to reboot once, then re-run)
   - Import the Lampy system as a WSL distro
   - Start all 7 services
   - Register Lampy to start automatically when Windows boots
5. When it finishes, open your browser:
   - Forum: http://localhost/app/
   - R Theory site: http://localhost/r-theory/
   - code-server: http://localhost:8080/

That's it. No Docker, no command line beyond the one install command, no
configuration.

> **Note:** If you already have the tarball locally (e.g. `lampy-wsl-slim.tar`
> on disk), pass it directly to skip the download:
> ```powershell
> .\install.ps1 -TarballPath "C:\path\to\lampy-wsl-slim.tar"
> ```

## What gets installed

- **Location:** `C:\Lampy\`
  - `C:\Lampy\wsl\` — the Lampy Linux system (WSL2 distro)
  - `C:\Lampy\download\` — downloaded image chunks (safe to delete after install)
  - `C:\Lampy\install.ps1`, `uninstall.ps1` — installer scripts
- **WSL distro:** named `lampy` (see it with `wsl --list`)
- **Boot startup:** a Scheduled Task named `Lampy` starts all services at boot
- **Ports used:** 80 (web), 443 (https), 5432 (PostgreSQL), 8080 (code-server),
  11434 (Ollama), 2525/2465/2587/1143/1993/1110 (mail)

## Default passwords

The install ships with default passwords. **Change these before exposing
Lampy to the internet.**

| Service      | Credential                              |
|--------------|-----------------------------------------|
| PostgreSQL   | user `postgres`, password `password`    |
| code-server  | password `password`                     |
| Forum admin  | set up on first visit to `/app/`       |

To change the PostgreSQL password:

```powershell
wsl -d lampy -u postgres psql -c "ALTER USER postgres PASSWORD 'your-new-password';"
```

Then update the pgai-worker config:

```powershell
# Edit /etc/supervisor/conf.d/lampy.conf inside WSL and replace
# POSTGRES_PASSWORD="password" with your new password, then:
wsl -d lampy -u root supervisorctl -c /etc/supervisor/conf.d/lampy.conf restart pgai-worker
```

## Managing Lampy

**Check service status:**
```powershell
wsl -d lampy -u root supervisorctl -c /etc/supervisor/conf.d/lampy.conf status
```

**Restart all services:**
```powershell
wsl -d lampy -u root supervisorctl -c /etc/supervisor/conf.d/lampy.conf restart all
```

**Stop Lampy (keeps data):**
```powershell
Stop-ScheduledTask -TaskName "Lampy"
wsl --terminate lampy
```

**Start Lampy again:**
```powershell
Start-ScheduledTask -TaskName "Lampy"
```

**Open a Linux shell inside Lampy:**
```powershell
wsl -d lampy
```

## Backing up

The database lives inside the WSL distro. To back it up:

```powershell
wsl -d lampy -u postgres pg_dump -Fc forum > C:\Lampy\forum-backup.dump
```

To back up the entire Lampy system (distro + data):

```powershell
wsl --export lampy C:\Lampy\lampy-full-backup.tar
```

## Uninstall

Run as administrator:
```powershell
.\uninstall.ps1
```

This removes the WSL distro, the boot task, and `C:\Lampy\`. Your backups
(if you made any) are kept.

## Troubleshooting

**"WSL2 not installed" or virtualization errors:**
Enable virtualization in your BIOS/UEFI, then run `wsl --install` in an
admin PowerShell and reboot.

**Port 80 already in use:**
Another web server (IIS, Skype, etc.) is holding port 80. Stop it or
disable it, then restart Lampy.

**Services won't start after a Windows update:**
Run `wsl --shutdown`, then `Start-ScheduledTask -TaskName "Lampy"`.

**Forum shows a database error:**
Check PostgreSQL is running:
```powershell
wsl -d lampy -u root supervisorctl -c /etc/supervisor/conf.d/lampy.conf status postgres
```

## Building from source

See [BUILD.md](BUILD.md) for the full pipeline
(Docker image → slimmed WSL tarball → GitHub Releases chunks).

## Version

- Installer: 1.0.0-slim
- Base image: `kitcosby/lampy-single:windows-1.0.0`
  (digest `sha256:69a301fb52d664e31105972d88b1d2431d923e2bb8474e2c531e08a59e004455`)
- System image: `lampy-wsl-slim.tar` (10.6 GB, slimmed 2026-09-27 —
  removed 5.2 GB of unused torch/CUDA/ML packages)
