"""Fix supervisor config for WSL: postgres PATH/PGDATA, RPC sections for
supervisorctl. Idempotent: safe to re-run (repair mode). Password-related
environment is owned by set-passwords.py, not this script."""
import re

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


def _fix_pgdata(body):
    lines = [l for l in body.split("\n") if not l.startswith("environment=")]
    lines.insert(1, 'environment=PATH="/usr/lib/postgresql/16/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",PGDATA="/home/postgres/pgdata/data"')
    return "\n".join(lines)
_each_section("postgres", _fix_pgdata)


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

# Boot wrapper: recreates tmpfs dirs (/var/run is wiped on every WSL boot)
with open("/usr/local/bin/lampy-boot.sh", "w") as f:
    f.write("""#!/bin/bash
# Lampy boot wrapper: recreate tmpfs directories, then start supervisord
mkdir -p /var/run/supervisor /var/log/supervisor /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql
ln -sf /usr/lib/postgresql/16/bin/postgres /usr/local/bin/postgres
ln -sf /usr/lib/postgresql/16/bin/pg_ctl /usr/local/bin/pg_ctl
ln -sf /usr/lib/postgresql/16/bin/initdb /usr/local/bin/initdb
exec supervisord -c /etc/supervisor/conf.d/lampy.conf
""")
import os
os.chmod("/usr/local/bin/lampy-boot.sh", 0o755)
print("boot wrapper written")
