#!/bin/sh
# Makes the PNGs from the SVGs and social.html: run it after changing a logo.
# It needs Chromium (CHROME=/path/to/chrome to say where) and ImageMagick.
# Chromium won't make a window under 500 px, so the icons are drawn
# large and shrunk.
set -e
cd "$(dirname "$0")"
C=${CHROME:-chromium}
shot() {   # shot out.png width height page
    "$C" --headless --no-sandbox --hide-scrollbars --default-background-color=00000000 \
        --screenshot="$1" --window-size="$2,$3" "file://$PWD/$4" >/dev/null 2>&1
}
icon() {   # icon svg out.png size
    printf '<body style="margin:0;background:none"><img src="%s" width="512" height="512" style="display:block">' "$1" > .tile.html
    shot .big.png 600 600 .tile.html
    convert .big.png -crop 512x512+0+0 +repage -resize "$3x$3" "$2"
}
icon logo.svg apple-touch-icon.png 180
# iOS rounds the corners itself and wants none transparent
convert apple-touch-icon.png -background "#E07A5F" -alpha remove -alpha off apple-touch-icon.png
icon favicon.svg favicon-32.png 32
rm -f .tile.html .big.png
shot social.png 1200 630 social.html
