#!/usr/bin/env bash
set -euo pipefail
app=$1
output=$2
stage=$(mktemp -d "${TMPDIR:-/tmp}/test-slive-dmg.XXXXXX")
trap 'rm -rf "$stage"; rm -f "$stage.dmg"' EXIT
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"
# hdiutil can transiently report Resource busy on hosted macOS runners.
for attempt in 1 2 3; do
  if hdiutil create -volname test-Slive -srcfolder "$stage" -fs HFS+ \
    -ov -format UDZO "$stage.dmg"; then
    mv "$stage.dmg" "$output"
    exit 0
  fi
  if [ "$attempt" -lt 3 ]; then sleep 5; fi
done
exit 1
