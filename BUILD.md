# Building the Lampy Windows distribution

Everything is built from code. No manual steps.

## Prerequisites (build machine)

- Windows 10/11 with Docker Desktop and WSL2
- PowerShell 5.1+
- The `lampy-single` Docker image
  (source: https://github.com/cosbykit-afk/lampy-single)

## Build pipeline

```powershell
# 1. Export the image to a WSL tarball (from the Docker image)
docker export lampy-single -o lampy-wsl.tar

# 2. Import as a test distro
wsl --import lampy-test C:\Lampy\wsl-test lampy-wsl.tar

# 3. Slim it: remove unused ML packages (5.2 GB of dead weight)
wsl -d lampy-test -u root pip uninstall -y torch torchvision triton `
    accelerate docling docling-core docling-ibm-models docling-parse easyocr `
    nvidia-cublas nvidia-cuda-cupti nvidia-cuda-nvrtc nvidia-cuda-runtime `
    nvidia-cudnn-cu13 nvidia-cufft nvidia-cufile nvidia-curand `
    nvidia-cusolver nvidia-cusparse nvidia-cusparselt-cu13 `
    nvidia-nccl-cu13 nvidia-nvjitlink nvidia-nvshmem-cu13 nvidia-nvtx

# 4. Verify all 7 services still run
wsl -d lampy-test -u root supervisorctl -c /etc/supervisor/conf.d/lampy.conf status
# Expected: apache2, codeserver, forum, james, ollama, pgai-worker, postgres all RUNNING

# 5. Re-export the slimmed tarball
wsl --export lampy-test C:\Users\kitco\lampy-wsl-slim.tar
# Result: ~10.6 GB (was 15.78 GB)
```

### Why slim?

The Docker image ships 5.2 GB of PyTorch, NVIDIA CUDA libraries, and
document-processing ML packages (torch, triton, nvidia-*, docling, easyocr,
accelerate). **Checked 2026-09-27:** none of the 7 Lampy services import
them:

- pgai-worker's dependencies: click, psycopg, pydantic, structlog, etc. (no torch)
- Forum app: zero torch imports
- All 7 services verified RUNNING after removal
- Forum + R Theory HTTP 200, 559 users in DB after removal

### 6. Split for GitHub Releases

GitHub Releases has a 2 GB per-file limit. Split the tarball:

```powershell
# Split into 2 GB chunks
$chunkSize = 2GB
# ... (see scripts/split-tarball.ps1)
```

Upload the chunks as release assets to a GitHub Release tagged
`v1.0.0-slim`. The installer (`install.ps1`) downloads and reassembles them
automatically.

## How the installer works (install.ps1)

On the target machine, as Administrator:

1. **Tarball** — uses `-TarballPath` if given, a local `lampy-wsl-slim.tar`
   if present, otherwise downloads chunks from GitHub Releases and reassembles
2. **WSL2 check** — enables WSL + VirtualMachinePlatform via DISM if missing
   (reboot required, then re-run)
3. **Import** — `wsl --import lampy C:\Lampy\wsl lampy-wsl-slim.tar`
4. **WSL adaptations** — the Docker image needs fixes to run under WSL:
   - Create `/var/run/supervisor/`, `/var/log/supervisor/`, `/var/run/postgresql/`
   - Symlink postgres binaries into `/usr/local/bin/` (not on WSL PATH)
   - Append `[unix_http_server]` / `[supervisorctl]` / `[rpcinterface:supervisor]`
     to the supervisor config (the Docker image omits them)
   - Set `PATH` + `PGDATA` in `[program:postgres]`
   - Set `POSTGRES_PASSWORD` in `[program:pgai-worker]`
   - Write `/etc/wsl.conf` `[boot]` command to launch supervisord on distro start
5. **Boot task** — registers a Scheduled Task `Lampy` (SYSTEM, at startup)
6. **Verify** — waits 60s, then checks PostgreSQL, Apache, forum, Ollama,
   and code-server

All steps are idempotent — safe to re-run.

## Proven

2026-09-27:
- Exported `kitcosby/lampy-single:windows-1.0.0`, imported as WSL distro
- Removed 5.2 GB dead packages, all 7/7 services RUNNING via supervisord
- Forum + R Theory HTTP 200, 559 users in the database
- Re-exported as `lampy-wsl-slim.tar` (10.6 GB)

## Releasing a new version

1. Build and slim the tarball (steps 1–5 above)
2. Split into 2 GB chunks, create a GitHub Release (e.g. `v1.0.1-slim`),
   upload chunks as assets
3. Update `install.ps1`'s default `$ReleaseTag` to the new tag
4. Tag the Docker image and push to Docker Hub + GHCR
5. Update README version section, commit, push to this repo
