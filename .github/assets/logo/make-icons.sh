#!/bin/sh
# Regenerate the application icons from the project logo.
#
# Source of truth: emacs-gpu.svg (this directory).  Run this script from
# anywhere after changing the logo, or after a rebase onto a new Emacs
# tag if an icon file conflicted (resolution rule: ours, i.e. re-run
# this script).
#
# Outputs:
#   etc/images/icons/hicolor/{24x24,32x32,48x48,128x128}/apps/emacs.png
#   etc/images/icons/hicolor/scalable/apps/emacs.svg
#   nextstep/Cocoa/Emacs.base/Contents/Resources/Emacs.icns  (macOS only)
#
# The 16x16 hicolor PNG is left untouched (upstream's own render) and
# the 16pt icns slot renders from the unmodified upstream icon
# (emacs-official.svg): at that size the chip pins and the motion trail
# degrade into noise, legibility wins.
#
# Requires rsvg-convert (librsvg); the .icns step also needs iconutil
# and therefore macOS.

set -e

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
logo="$here/emacs-gpu.svg"
official="$here/emacs-official.svg"

command -v rsvg-convert >/dev/null || {
    echo "rsvg-convert not found (install librsvg)" >&2; exit 1;
}

# Freedesktop hicolor theme (GNU/Linux window/menu icon).
for s in 24 32 48 128; do
    rsvg-convert -w $s -h $s "$logo" \
        -o "$root/etc/images/icons/hicolor/${s}x${s}/apps/emacs.png"
done
cp "$logo" "$root/etc/images/icons/hicolor/scalable/apps/emacs.svg"
echo "hicolor icons regenerated"

# macOS application icon.
if command -v iconutil >/dev/null; then
    set=$(mktemp -d)/Emacs.iconset
    mkdir -p "$set"
    rsvg-convert -w 16 -h 16 "$official" -o "$set/icon_16x16.png"
    for spec in "16x16@2x 32" "32x32 32" "32x32@2x 64" "128x128 128" \
                "128x128@2x 256" "256x256 256" "256x256@2x 512" \
                "512x512 512" "512x512@2x 1024"; do
        name=${spec% *}; px=${spec#* }
        rsvg-convert -w "$px" -h "$px" "$logo" -o "$set/icon_$name.png"
    done
    iconutil -c icns "$set" \
        -o "$root/nextstep/Cocoa/Emacs.base/Contents/Resources/Emacs.icns"
    rm -rf "$(dirname "$set")"
    echo "Emacs.icns regenerated"
else
    echo "iconutil not found: skipping Emacs.icns (macOS only)"
fi
