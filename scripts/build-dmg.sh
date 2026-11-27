#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s /absolute/path/Pulse.app /absolute/path/output.dmg\n' "$0" >&2
    exit 2
fi

app="$1"
output="$2"
cd "$(dirname "$0")/.."
codesign --verify --deep --strict "$app"

environment="$PWD/.build/dmg-env"
if [[ ! -x "$environment/bin/dmgbuild" ]]; then
    python3 -m venv "$environment"
    "$environment/bin/pip" install 'dmgbuild==1.6.5'
fi

work="$(mktemp -d "$PWD/.build/pulse-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sips -z 88 72 -s format png Artwork/PulseMark.svg --out "$work/mark.png" >/dev/null
swiftc scripts/dmg-background.swift -o "$work/draw-background"
"$work/draw-background" Resources/BricolageGrotesque.ttf "$work/mark.png" "$work/background.png" 1
"$work/draw-background" Resources/BricolageGrotesque.ttf "$work/mark.png" "$work/background@2x.png" 2
"$environment/bin/dmgbuild" -s scripts/dmg-settings.py \
    -D "app=$app" -D "background=$work/background.png" Pulse "$output"
hdiutil verify "$output"
