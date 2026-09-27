# Lampy Windows Installer

Builds a Windows installation file (`Lampy-Setup.exe`) from code that installs
the full Lampy stack (PostgreSQL+TimescaleDB, Apache, Ollama, James, code-server,
pgai-worker, Flask forum) via WSL2 — no Docker required on the target machine.

## Architecture

```
Build machine (Toetop):
  Dockerfile → docker build → lampy-single image
      → docker export → lampy-wsl.tar (WSL distro rootfs)
      → NSIS → Lampy-Setup.exe

Target machine (user's Windows):
  Lampy-Setup.exe
      → enable WSL2 (if needed)
      → wsl --import lampy C:\Lampy\wsl lampy-wsl.tar
      → configure services (supervisord)
      → Task Scheduler: start on boot
      → ports 80/443/5432/8080/11434... forwarded
```

## Files

- `build.ps1` — Build pipeline: image → WSL tarball → installer .exe. Run on the
  build machine. Everything from code, no manual steps.
- `install.ps1` — Installer logic. Bundled into the .exe, runs on the target
  machine. Idempotent: safe to re-run.
- `lampy.nsi` — NSIS script that wraps `install.ps1` + `lampy-wsl.tar` into
  `Lampy-Setup.exe`.
- `uninstall.ps1` — Clean removal: unregister WSL distro, remove scheduled task,
  delete `C:\Lampy`.

## Status

- [x] Docker image builds and validates (7/7 services)
- [x] WSL distro tarball exports and boots (2026-09-27: `lampy-test` distro,
      all 7/7 services RUNNING via supervisord, forum + R Theory HTTP 200,
      559 users in database)
- [ ] install.ps1 completes on a clean Windows machine (code written, WSL fixes baked in)
- [ ] NSIS .exe wraps and installs end-to-end
- [ ] Bootstraps correctly: services start on Windows boot, no manual steps

### WSL adaptations required (proven 2026-09-27)

The Docker image's supervisor config needs these changes for WSL:
1. Create `/var/run/supervisor/`, `/var/log/supervisor/`, `/var/run/postgresql/`
   (Docker creates these at container start; WSL does not)
2. Symlink postgres binaries to `/usr/local/bin/` (not on WSL PATH)
3. Append `[unix_http_server]`, `[supervisorctl]`, `[rpcinterface:supervisor]`
   sections (Docker image omits them)
4. Set `PATH` + `PGDATA` in `[program:postgres]` environment
5. Set `POSTGRES_PASSWORD` in `[program:pgai-worker]` environment
6. Kill stale apache processes before starting (they hold port 80)
7. `wsl.conf` `[boot]` command launches supervisord on distro start
