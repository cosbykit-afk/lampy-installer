# Building Lampy-Setup.exe from source

Everything is built from code. No manual steps.

## Prerequisites (build machine)

- Windows 10/11 with Docker Desktop
- PowerShell 5.1+
- NSIS 3.x (`makensis` on PATH) — for the `.exe` wrapper
- The `lampy-single` Docker image
  (source: https://github.com/cosbykit-afk/lampy-single)

## Build

```powershell
# Full pipeline: image -> WSL tarball -> Lampy-Setup.exe
.\build.ps1

# Skip the Docker build (use the already-released image)
.\build.ps1 -SkipDockerBuild
```

### What build.ps1 does

1. **Exports the image** to a WSL distro tarball:
   `docker export` → `lampy-wsl.tar` (~16 GB)
2. **Stages** `install.ps1`, `uninstall.ps1`, and the tarball into the output dir
3. **Wraps** everything into `Lampy-Setup.exe` via NSIS (`lampy.nsi`)

Output: `C:\Lampy\installer-build\Lampy-Setup.exe`

## How the installer works (install.ps1)

On the target machine, as Administrator:

1. **WSL2 check** — enables WSL + VirtualMachinePlatform via DISM if missing
   (reboot required, then re-run)
2. **Import** — `wsl --import lampy C:\Lampy\wsl lampy-wsl.tar`
3. **WSL adaptations** — the Docker image needs 7 fixes to run under WSL:
   - Create `/var/run/supervisor/`, `/var/log/supervisor/`, `/var/run/postgresql/`
   - Symlink postgres binaries into `/usr/local/bin/` (not on WSL PATH)
   - Append `[unix_http_server]` / `[supervisorctl]` / `[rpcinterface:supervisor]`
     to the supervisor config (the Docker image omits them)
   - Set `PATH` + `PGDATA` in `[program:postgres]`
   - Set `POSTGRES_PASSWORD` in `[program:pgai-worker]`
   - Write `/etc/wsl.conf` `[boot]` command to launch supervisord on distro start
4. **Boot task** — registers a Scheduled Task `Lampy` (SYSTEM, at startup)
   that runs supervisord inside the distro
5. **Verify** — waits 60s, then checks PostgreSQL, Apache, forum, Ollama,
   and code-server

All steps are idempotent — safe to re-run.

## Proven

2026-09-27: exported `kitcosby/lampy-single:windows-1.0.0`, imported as WSL
distro, all 7/7 services RUNNING via supervisord, forum + R Theory HTTP 200,
559 users in the database.

## Releasing

1. Run `.\build.ps1` on the build machine
2. Test `Lampy-Setup.exe` on a clean Windows VM
3. Push the installer scripts to GitHub (this repo)
4. Tag the Docker image: `docker tag kitcosby/lampy-single:latest kitcosby/lampy-single:windows-<version>` and push
5. Create a GitHub Release with `Lampy-Setup.exe` attached
   (note: the 16 GB `lampy-wsl.tar` is bundled inside the .exe by NSIS)
