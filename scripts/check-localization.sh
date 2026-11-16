#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
#
# Every text the app shows must be translated in each Localization/<lang>.lproj, with
# the same placeholders. The Swift compiler lists the texts (as Xcode does).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swift build --disable-sandbox --product Longcable \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$out" >/dev/null
python3 - "$out" Localization <<'PY'
import glob, json, os, re, subprocess, sys
out, root = sys.argv[1], sys.argv[2]
keys = set()
for path in glob.glob(os.path.join(out, "*.stringsdata")):
    for entries in json.load(open(path)).get("tables", {}).values():
        keys.update(e["key"] for e in entries)
spec = re.compile(r"%(?:\d+\$)?(?:ll|l)?[@duxf]")
def placeholders(s): return sorted(re.sub(r"\d+\$", "", p) for p in spec.findall(s))
problems = 0
for lproj in sorted(glob.glob(os.path.join(root, "*.lproj"))):
    lang = os.path.basename(lproj)[:-6]
    for table in sorted(glob.glob(os.path.join(lproj, "*.strings"))):
        name = os.path.basename(table)
        if lang == "en": continue
        data = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", table],
                                         check=True, capture_output=True).stdout)
        if name == "Localizable.strings":
            for k in sorted(keys - data.keys()):
                print(f"{lang}: missing translation: {k}"); problems += 1
            for k in sorted(data.keys() - keys):
                print(f"{lang}: no longer used: {k}"); problems += 1
        for k, v in data.items():
            if name != "InfoPlist.strings" and placeholders(k) != placeholders(v):
                print(f"{lang}/{name}: placeholders differ: {k!r} -> {v!r}"); problems += 1
print(f"{len(keys)} texts checked" if not problems else f"{problems} localization problem(s)")
sys.exit(1 if problems else 0)
PY
