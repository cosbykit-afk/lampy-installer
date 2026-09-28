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
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
   (The `-ExecutionPolicy Bypass` is needed because the script isn't
   digitally signed — this only affects that one run.)
4. The installer will:
   - Download the Lampy system image (11 GB, in 7 chunks from
     GitHub Releases) — this takes a while on first run
   - Enable WSL2 if it isn't already (may ask you to reboot once, then re-run)
   - Import the Lampy system as a WSL distro
   - Fetch the latest R Theory and Bible websites from GitHub
   - Start all 8 services
   - Register Lampy to start automatically when Windows boots
5. When it finishes, open your browser:
   - Forum: http://localhost/app/
   - R Theory site: http://localhost/r-theory/
   - Bible site: http://localhost/bible/
   - code-server: http://localhost:8080/

That's it. No Docker, no command line beyond the one install command, no
configuration.

> **Note:** If you already have the tarball locally (e.g. `lampy-public.tar`
> on disk), pass it directly to skip the download:
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\install.ps1 -TarballPath "C:\path\to\lampy-public.tar"
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

## Change your passwords (do this first!)

Lampy ships with default passwords that everyone knows. **Change them
right after installing**, especially before putting Lampy on the internet.

### 1. code-server password

code-server is the in-browser code editor at http://localhost:8080/.
The default password is `password`.

To change it:

1. Open PowerShell (no need for admin this time).
2. Run:
   ```powershell
   wsl -d lampy
   ```
   You're now inside Lampy's Linux system. Your prompt will change.
3. Run:
   ```bash
   nano ~/.config/code-server/config.yaml
   ```
4. Find the line that says `password: password` and change it to
   something only you know, e.g. `password: MyNewPassword123`
5. Press `Ctrl+O`, then `Enter` to save. Press `Ctrl+X` to exit nano.
6. Type `exit` to leave Lampy's Linux system and return to PowerShell.
7. Restart code-server:
   ```powershell
   wsl -d lampy -u root supervisorctl -c /etc/supervisor/conf.d/lampy.conf restart codeserver
   ```

### 2. PostgreSQL password

The database user is `postgres` and the default password is `password`.
Several Lampy services use this password, so you need to update it in
two places: the database itself, and the config file that tells the
services what the password is.

**Step A — change it in the database:**

1. Open PowerShell.
2. Run (replace `YourNewDbPassword` with your own):
   ```powershell
   wsl -d lampy -u postgres psql -c "ALTER USER postgres PASSWORD 'YourNewDbPassword';"
   ```
3. You should see `ALTER ROLE`. That means it worked.

**Step B — tell Lampy's services about the new password:**

1. Open the config file:
   ```powershell
   wsl -d lampy
   ```
   ```bash
   sudo nano /etc/supervisor/conf.d/lampy.conf
   ```
2. Find the line containing `POSTGRES_PASSWORD=password`
   (it's in the pgai-worker section).
3. Change `password` to your new password from Step A.
   Make sure there are no extra spaces.
4. Press `Ctrl+O`, `Enter` to save, `Ctrl+X` to exit.
5. Type `exit` to return to PowerShell.
6. Restart the affected service:
   ```powershell
   wsl -d lampy -u root supervisorctl -c /etc/supervisor/conf.d/lampy.conf restart pgai-worker
   ```

### 3. Forum admin account

There is no default forum admin. The first time you visit
http://localhost/app/ you'll be asked to create an admin account.
Pick a strong password — this is your forum's master key.

### Quick reference

| Service     | Default                             | Where to change it                |
|-------------|-------------------------------------|-----------------------------------|
| code-server | password `password`                 | `~/.config/code-server/config.yaml` inside WSL |
| PostgreSQL  | user `postgres`, password `password` | `psql` + `/etc/supervisor/conf.d/lampy.conf` |
| Forum admin | (none — you create it)              | First visit to http://localhost/app/ |

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

## Build status (2026-09-28)

- **Release `v1.0.0`: COMPLETE** — all 7 chunks of `lampy-public.tar`
  (11 GB) plus `lampy-public.tar.sha256` are on GitHub Releases
- **Installer verifies downloads** — `install.ps1` checks each chunk's
  SHA256 against the manifest; on re-run it skips verified chunks
  and re-downloads only corrupt or missing ones
- **Build dependencies** — Python wheelhouse (3 parts) + Ollama mirror
  (4 parts) on the `build-deps-v1` release of
  [lampy-deps](https://github.com/cosbykit-afk/lampy-deps)

## Known issues

- **Stale `install.ps1` copies** — if you downloaded the installer before
  2026-09-28, re-download `install.ps1`; older copies don't verify chunk
  checksums on retry and will re-download good chunks
- **`lampy-wsl-slim.tar` name in old docs** — some earlier docs and scripts
  reference `lampy-wsl-slim.tar`; the released file is `lampy-public.tar`
- **First download is slow** — 11 GB over GitHub Releases; the installer
  resumes cleanly, so interrupting and re-running is safe

## Version

- Installer: 1.1.6
- Base image: `kitcosby/lampy-single:windows-1.0.0`
  (digest `sha256:69a301fb52d664e31105972d88b1d2431d923e2bb8474e2c531e08a59e004455`)
- System image: `lampy-public.tar` (11 GB, 7 chunks, released 2026-09-28)
