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
    f.write("[boot]\ncommand = supervisord -c /etc/supervisor/conf.d/lampy.conf\n")
print("wsl.conf written")
