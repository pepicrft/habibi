#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
nsh="${NSH_BIN:-nsh}"
case "$("$nsh" --version)" in
  'nsh 0.2.0 '*) ;;
  *) echo 'Kit pages require NSH 0.2.0.' >&2; exit 1 ;;
esac
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
for manifest in kits/*/nsh.json; do
  kit="$(basename "$(dirname "$manifest")")"
  "$nsh" build "kits/$kit/App.tsx" --release --out "$out/$kit"
  cp "$out/$kit/bundle.js" "core/assets/$kit-page.js"
done
python3 kits/verify.py --record
