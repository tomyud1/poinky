#!/bin/bash
# tools/e2e/seed.sh <support-dir> [config.json to copy]: a support folder that skips the first-run tour
# and the "I live here" moment (realistic settings if you pass a config.json to start from).
set -eu
d=$1; mkdir -p "$d"
if [ $# -ge 2 ]; then cp "$2" "$d/config.json"; else echo '{}' > "$d/config.json"; fi
/usr/bin/python3 - "$d/config.json" <<'PY'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c["homeShown"]=True; json.dump(c,open(p,"w"),indent=2)
PY
echo '{"done":true,"page":4}' > "$d/welcome.json"
# The installed voice, so runs speak with Phonon like the real app (it's ~75 MB; a link, not a copy).
real="$HOME/Library/Application Support/Poinky/phonon"
[ -d "$real" ] && [ ! -e "$d/phonon" ] && ln -s "$real" "$d/phonon"
true
