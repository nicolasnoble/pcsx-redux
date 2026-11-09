#!/bin/sh
# Builds vp-translate.zip: the browser and the translation tool as an archive
# for pcsx-redux -archive. Usage: make-archive.sh [output.zip]
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=$(realpath -m "${1:-vp-translate.zip}")
rm -f "$out"
cd "$here"
files=$(ls *.lua translate-web.js | grep -v -e '-test\.lua$' -e '-gen\.lua$' -e '^main\.lua$')
zip -q -X -9 "$out" $files
echo "$out: $(echo $files | wc -w) files"
