"""Fix supervisor config for WSL: postgres PATH/PGDATA, RPC sections for
supervisorctl. Idempotent: safe to re-run (repair mode). Password-related
environment is owned by set-passwords.py, not this script."""
import re

# Boot file version. Increment when the boot script template changes.
# The installer checks this to decide if Repair needs to re-run this script.
BOOT_VERSION = 2

p = "/etc/supervisor/conf.d/lampy.conf"
c = open(p).read()

# Append supervisor RPC sections (needed for supervisorctl) if missing
if "unix_http_server" not in c:
    c += """
[unix_http_server]
file=/var/run/supervisor/supervisor.sock

[supervisorctl]
serverurl=unix:///var/run/supervisor/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
"""


def _each_section(name, fn):
    global c
    c = re.sub(r"(\[program:%s\].*?)(?=\n\[)" % re.escape(name),
               lambda m: fn(m.group(1)), c, flags=re.S)


# Postgres: run the binary directly, not via /docker-entrypoint.sh.
# The entrypoint wrapper confuses supervisord's PID tracking (it starts
# postgres, which succeeds, but supervisord thinks it failed and spawns
# duplicates that fight over postmaster.pid). The data dir is already
# initialized, so the entrypoint's setup is not needed.
def _fix_pgcmd(body):
    body = re.sub(r"command=/docker-entrypoint\.sh postgres",
                  "command=/usr/lib/postgresql/16/bin/postgres -D /home/postgres/pgdata/data",
                  body)
    return body
_each_section("postgres", _fix_pgcmd)
def _fix_pgdata(body):
    lines = [l for l in body.split("\n") if not l.startswith("environment=")]
    lines.insert(1, 'environment=PATH="/usr/lib/postgresql/16/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",PGDATA="/home/postgres/pgdata/data"')
    return "\n".join(lines)
_each_section("postgres", _fix_pgdata)


# WSL runs supervisord as a DAEMON (not Docker's foreground PID 1 mode).
# Foreground (nodaemon=true) via a scheduled task is fragile: if supervisord
# dies, the task ends with no restart; Start-ScheduledTask on a running task
# is a no-op. Daemon mode lets the boot script ensure it's running.
if "nodaemon=true" in c:
    c = c.replace("nodaemon=true", "nodaemon=false")


def _fix_ollama_home(body):
    # Ollama panics with "$HOME is not defined" if HOME is unset
    # (2026-09-27, regressed 2026-09-28). Ensure HOME is present,
    # preserving any other environment vars. Idempotent.
    lines = body.split("\n")
    out = []
    found = False
    for l in lines:
        if l.startswith("environment="):
            found = True
            env = l[len("environment="):]
            if "HOME=" not in env:
                env = env + ',HOME="/root"' if env else 'HOME="/root"'
            out.append("environment=" + env)
        else:
            out.append(l)
    if not found:
        out.insert(1, 'environment=HOME="/root"')
    return "\n".join(out)
_each_section("ollama", _fix_ollama_home)

open(p, "w").write(c)
print("wsl config patched")

# Boot supervisord on every WSL distro start
with open("/etc/wsl.conf", "w") as f:
    f.write("[boot]\ncommand = /usr/local/bin/lampy-boot.sh\n")
print("wsl.conf written")

# Boot wrapper: idempotent "ensure supervisord is running". Recreates tmpfs
# dirs (/var/run is wiped on every WSL boot), then starts supervisord as a
# DAEMON if it's not already running. Safe to call repeatedly.
# With argument "keepalive", sleeps forever after ensuring supervisord —
# this keeps the WSL distro alive (a daemonized supervisord alone does not
# prevent WSL from shutting down when the last client disconnects).
with open("/usr/local/bin/lampy-boot.sh", "w") as f:
    f.write(f"""#!/bin/bash
# LAMPY_BOOT_VERSION={BOOT_VERSION}
# Lampy boot wrapper: recreate tmpfs directories, ensure supervisord daemon.
mkdir -p /var/run/supervisor /var/log/supervisor /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql
ln -sf /usr/lib/postgresql/16/bin/postgres /usr/local/bin/postgres
ln -sf /usr/lib/postgresql/16/bin/pg_ctl /usr/local/bin/pg_ctl
ln -sf /usr/lib/postgresql/16/bin/initdb /usr/local/bin/initdb
# Already running? Nothing to do.
if supervisorctl -c /etc/supervisor/conf.d/lampy.conf status >/dev/null 2>&1; then
    :
else
    # Start as a daemon (nodaemon=false in lampy.conf for WSL).
    supervisord -c /etc/supervisor/conf.d/lampy.conf
fi
# Keep the distro alive for the scheduled task; the installer omits this
# argument so its wsl invocation returns instead of hanging.
if [ "$1" = "keepalive" ]; then
    exec sleep infinity
fi
""")
import os
os.chmod("/usr/local/bin/lampy-boot.sh", 0o755)
print("boot wrapper written")
