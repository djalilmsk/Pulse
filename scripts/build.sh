#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --release ) ]]; then
    printf 'Usage: %s [--release]\n' "$0" >&2
    exit 2
fi

arch="$(uname -m)"
app="$PWD/dist/Pulse.app"
sparkle_version=2.10.1
sparkle_checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
sparkle="$PWD/.build/sparkle-$sparkle_version"

if [[ ! -x "$sparkle/bin/generate_appcast" || ! -f "$sparkle/Sparkle.framework/Sparkle" ]]; then
    mkdir -p "$sparkle"
    download="$(mktemp -d "$PWD/.build/sparkle-download.XXXXXX")"
    trap 'rm -rf "$download"' EXIT
    curl -fLsS --retry 2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
        -o "$download/Sparkle.tar.xz"
    printf '%s  %s\n' "$sparkle_checksum" "$download/Sparkle.tar.xz" | shasum -a 256 -c -
    tar -xf "$download/Sparkle.tar.xz" -C "$sparkle" Sparkle.framework bin LICENSE
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp Resources/Info.plist "$app/Contents/Info.plist"
for resource in Resources/*; do
    [[ "$resource" == Resources/Info.plist ]] && continue
    cp "$resource" "$app/Contents/Resources/"
done
ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"

swiftc -parse-as-library -Osize -target "${arch}-apple-macos14.0" \
    -F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -Xlinker -dead_strip Sources/Pulse.swift -o "$app/Contents/MacOS/Pulse"
strip -x "$app/Contents/MacOS/Pulse"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

printf 'Built %s\n' "$app"

if [[ ${1:-} == --release ]]; then
    public_key="$(plutil -extract SUPublicEDKey raw "$app/Contents/Info.plist")"
    if [[ "$("$sparkle/bin/generate_keys" --account org.pulse.updates -p)" != "$public_key" ]]; then
        printf 'The Pulse Sparkle signing key in Keychain does not match the app.\n' >&2
        exit 1
    fi

    version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
    zip="Pulse-$version-macos-$arch.zip"
    dmg="Pulse-$version-macos-$arch.dmg"
    release="$(mktemp -d "$PWD/dist/release.XXXXXX")"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$release/$zip"
    "$sparkle/bin/generate_appcast" --account org.pulse.updates --maximum-deltas 0 \
        --download-url-prefix "https://github.com/djalilmsk/Pulse/releases/download/v$version/" \
        --link "https://github.com/djalilmsk/Pulse/releases/tag/v$version" \
        -o "$release/appcast.xml" "$release"
    scripts/build-dmg.sh "$app" "$release/$dmg"
    printf 'Release assets:\n%s\n%s\n%s\n' "$release/$zip" "$release/$dmg" "$release/appcast.xml"
fi
