#!/bin/sh
set -eu
cd "$(dirname "$0")"

case "$#:${1:-}" in
    0:) install_dir= ;;
    1:--install) install_dir="$HOME/Applications" ;;
    *)
        printf '%s\n' "Usage: $0 [--install]" >&2
        exit 2
        ;;
esac

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
/usr/libexec/PlistBuddy -c "Add :FeedBasketBuildID string $(/usr/bin/uuidgen)" "$app/Contents/Info.plist"
cp FeedBasket.icns "$app/Contents/Resources/FeedBasket.icns"
cp ../design/icons/feedbasket-*.png "$app/Contents/Resources/"
codesign --force --sign "$signing_identity" "$app"
# Finder displays the bundle directory's modification time.
touch "$app"

if [ -n "$install_dir" ]; then
    mkdir -p "$install_dir"
    installed="$install_dir/FeedBasket.app"
    if [ -e "$installed" ] || [ -L "$installed" ]; then
        if [ -L "$installed" ] || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                "$installed/Contents/Info.plist" 2>/dev/null)" != "app.feedbasket.reader" ]; then
            printf 'Cannot replace the existing item at %s\n' "$installed" >&2
            exit 1
        fi
    fi

    staging="$(mktemp -d "$install_dir/.FeedBasket.XXXXXX")"
    previous="$staging/previous.app"
    cleanup_install() {
        if [ -d "$previous" ] && [ ! -e "$installed" ]; then
            if ! mv "$previous" "$installed"; then
                printf 'Previous app is available at %s\n' "$previous" >&2
                return
            fi
        fi
        rm -rf "$staging"
    }
    trap cleanup_install EXIT
    trap 'exit 1' HUP INT TERM
    ditto "$app" "$staging/FeedBasket.app"
    if [ -d "$installed" ]; then
        mv "$installed" "$previous"
    fi
    mv "$staging/FeedBasket.app" "$installed"
    touch "$installed"
    printf '%s\n' "$installed"
else
    printf '%s\n' "$app"
fi
