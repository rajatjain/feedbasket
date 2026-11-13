#!/bin/sh
set -eu
cd "$(dirname "$0")"

signing_identity="-"
if [ -f .signing-identity ]; then
    signing_identity="$(cat .signing-identity)"
    if [ -z "$signing_identity" ] || [ "$signing_identity" = "-" ]; then
        printf '%s\n' "Set .signing-identity to your code signing certificate name or fingerprint." >&2
        exit 1
    fi
fi

swift build -c release
binary="$(swift build -c release --show-bin-path)/FeedBasket"
app="$PWD/dist/FeedBasket.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/FeedBasket"
cp Info.plist "$app/Contents/Info.plist"
cp FeedBasket.icns "$app/Contents/Resources/FeedBasket.icns"
cp ../design/icons/feedbasket-*.png "$app/Contents/Resources/"
codesign --force --sign "$signing_identity" "$app"
# Finder displays the bundle directory's modification time.
touch "$app"
printf '%s\n' "$app"
