"""Apply install-time passwords to the supervisor config.

Reads a JSON config from the __CONFIG_B64__ placeholder (base64 of JSON;
filled in by install.ps1 before piping this script to python3 via stdin,
so passwords never touch a command line, the log, or a file).

Keys: pg_password, forum_db_password, codeserver_password ("" = disabled),
        forum_secret_key.

Idempotent: each key ends up as exactly one environment= line in its
program section (existing duplicates are removed first).
"""
import json
import base64
import re

cfg = json.loads(base64.b64decode('__CONFIG_B64__').decode())

p = "/etc/supervisor/conf.d/lampy.conf"
c = open(p).read()


def _quote(v):
    # Supervisor parses environment= with shlex-like rules; quote safely.
    return '"%s"' % v.replace("\\", "\\\\").replace('"', '\\"')


def _each_section(name, fn):
    global c
    c = re.sub(r"(\[program:%s\].*?)(?=\n\[)" % re.escape(name),
               lambda m: fn(m.group(1)), c, flags=re.S)


def set_env(section, key, value):
    """Ensure exactly one environment=KEY=value line in the section."""
    def fix(body):
        lines = [l for l in body.split("\n")
                 if not re.match(r"^environment=%s=" % re.escape(key), l)]
        lines.insert(1, "environment=%s=%s" % (key, _quote(value)))
        return "\n".join(lines)
    _each_section(section, fix)


def del_env(section, key):
    """Remove all environment=KEY= lines from the section."""
    def fix(body):
        lines = [l for l in body.split("\n")
                 if not re.match(r"^environment=%s=" % re.escape(key), l)]
        return "\n".join(lines)
    _each_section(section, fix)


set_env("pgai-worker", "POSTGRES_PASSWORD", cfg["pg_password"])
set_env("forum", "FORUM_DB_PASS", cfg["forum_db_password"])
set_env("forum", "FORUM_SECRET_KEY", cfg["forum_secret_key"])
if cfg["codeserver_password"]:
    set_env("codeserver", "PASSWORD", cfg["codeserver_password"])
else:
    del_env("codeserver", "PASSWORD")

open(p, "w").write(c)
print("passwords applied")
