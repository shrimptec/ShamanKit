#!/usr/bin/env bash
# Copies ShamanKit into the WoW Forever AddOns folder (found via the Faugus prefix; it moves, so never hardcode it).
set -euo pipefail
cd "$(dirname "$0")"
prefix=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/faugus-launcher/config.json')))['default-prefix'])")
dest=$(find "$prefix" -maxdepth 8 -type d -path '*/_forever_/Interface/AddOns' 2>/dev/null | head -1)
[ -n "$dest" ] || { echo "AddOns folder not found under $prefix" >&2; exit 1; }
rm -rf "$dest/ShamanKit"
cp -r ShamanKit "$dest/ShamanKit"
grep -m1 Interface "$dest/ShamanKit/ShamanKit.toc"
echo "installed to $dest/ShamanKit (restart the game for a new addon; /reload for later edits)"
