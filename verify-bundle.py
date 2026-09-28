#!/usr/bin/env python3
"""verify-bundle.py — build-time guard for the Lampy installer bundle.

Parses install.ps1 and uninstall.ps1 for every literal file they expect
alongside themselves (Join-Path $PSScriptRoot "<name>") and asserts each
one is present in the staging dir AND in the NSIS File list. This is the
check that would have caught v1.1.1 shipping without wsl-envfix.py.

Usage: python3 verify-bundle.py <staging-dir>
Exits 0 on success, 1 with a loud error on any gap.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent
STAGE = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
if not STAGE:
    sys.exit("usage: verify-bundle.py <staging-dir>")

# 1. Files the scripts expect beside themselves.
needed = set()
for script in ("install.ps1", "uninstall.ps1"):
    text = (REPO / script).read_text(encoding="utf-8-sig")
    for m in re.finditer(r'Join-Path\s+\$PSScriptRoot\s+"([^"]+)"', text):
        needed.add(m.group(1))
# lampy-public.tar is produced at runtime by reassembly, not bundled.
needed.discard("lampy-public.tar")

# 2. Files the NSIS script actually bundles.
nsi = (REPO / "lampy-slim.nsi").read_text(encoding="utf-8-sig")
bundled = set(re.findall(r'^\s*File\s+"\$\{OUTDIR\}[\\/]([^"\\\/]+)"', nsi, re.M))

errors = []
for f in sorted(needed):
    if f not in bundled:
        errors.append(f"SCRIPT NEEDS '{f}' BUT lampy-slim.nsi DOES NOT BUNDLE IT")
    if not (STAGE / f).is_file():
        errors.append(f"'{f}' missing from staging dir {STAGE}")
for f in sorted(bundled):
    if not (STAGE / f).is_file():
        errors.append(f"NSIS bundles '{f}' but it is missing from staging dir {STAGE}")

if errors:
    print("BUNDLE VERIFICATION FAILED:")
    for e in errors:
        print("  " + e)
    sys.exit(1)
print(f"Bundle OK: {len(needed)} script-referenced file(s), {len(bundled)} bundled: "
      + ", ".join(sorted(bundled)))
