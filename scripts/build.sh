#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
arch="$(uname -m)"
app="$PWD/dist/Pulse.app"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
for resource in Resources/*; do
    [[ "$resource" == Resources/Info.plist ]] && continue
    cp "$resource" "$app/Contents/Resources/"
done

swiftc -parse-as-library -Osize -target "${arch}-apple-macos14.0" \
    -Xlinker -dead_strip Sources/Pulse.swift -o "$app/Contents/MacOS/Pulse"
strip -x "$app/Contents/MacOS/Pulse"
codesign --force --sign - "$app"
codesign --verify --strict "$app"

printf 'Built %s\n' "$app"
