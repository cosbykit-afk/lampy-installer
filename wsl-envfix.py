"""Fix supervisor config for WSL: postgres PATH/PGDATA, pgai-worker password."""
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

fixed = 'environment=PATH="/usr/lib/postgresql/16/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",PGDATA="/home/postgres/pgdata/data"'
c = re.sub(r"\[program:postgres\].*?(?=\n\[)",
            lambda m: re.sub(r"^environment=.*$", fixed, m.group(0), flags=re.M),
            c, flags=re.S)

# pgai-worker needs POSTGRES_PASSWORD (defaults match the image)
c = re.sub(r"\[program:pgai-worker\].*?(?=\n\[)",
            lambda m: re.sub(r"^command=",
                             "environment=POSTGRES_PASSWORD=password\ncommand=",
                             m.group(0), flags=re.M),
            c, flags=re.S)

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
