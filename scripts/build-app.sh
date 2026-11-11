#!/bin/sh
set -eu
binary="$1"
app="$2"
identity="${3:-}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
signing="$root/.local-signing"
local_identity=no
if [ -z "$identity" ] && [ -f "$signing/identity" ]; then
    identity=$(cat "$signing/identity")
    local_identity=yes
fi
identity=${identity:--}
stamp="$app.inputs"
inputs=$(mktemp "${TMPDIR:-/tmp}/boomer-build-inputs.XXXXXX")
staging=
cleanup() {
    rm -f "$inputs"
    [ -z "$staging" ] || rm -rf "$staging"
}
trap cleanup EXIT HUP INT TERM
shasum -a 256 "$binary" "$root/resources/Info.plist" "$root/scripts/build-app.sh" > "$inputs"
printf '%s\n%s\n' "$identity" "$local_identity" >> "$inputs"
if [ -f "$stamp" ] && cmp -s "$inputs" "$stamp" && /usr/bin/codesign --verify --strict "$app" 2>/dev/null; then
    echo "$app is up to date (signature preserved)."
    exit 0
fi
# A locked/unavailable keychain must not overwrite a working signed app.
staging=$(mktemp -d "$app.stage.XXXXXX")
next="$staging/Boomer.app"
mkdir -p "$next/Contents/MacOS" "$next/Contents/Resources"
cp "$binary" "$next/Contents/MacOS/boomer"
cp "$root/resources/Info.plist" "$next/Contents/Info.plist"
if [ "$local_identity" = yes ]; then
    echo 'Unlocking Boomer local signing keychain.'
    /usr/bin/security unlock-keychain -p "$(cat "$signing/password")" "$signing/boomer.keychain-db"
    echo 'Signing Boomer with its persistent development identity.'
    /usr/bin/codesign --force --sign "$identity" --keychain "$signing/boomer.keychain-db" \
        --timestamp=none "$next"
else
    /usr/bin/codesign --force --sign "$identity" "$next"
fi
/usr/bin/codesign --verify --strict "$next"
/usr/bin/ditto "$next" "$app"
mv "$inputs" "$stamp"
if [ "$identity" = - ]; then
    echo 'WARNING: ad-hoc signing; rebuilding changes the identity used by Screen Recording permissions.' >&2
    echo 'Use make setup-signing once, or make CODESIGN_IDENTITY="Apple Development: …".' >&2
fi
