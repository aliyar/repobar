#!/bin/bash
# Builds site/assets images from the renders in docs/screenshots.
# Crops are taken from the transparent panel render, then everything is converted to WebP.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="docs/screenshots"
OUT="site/assets"
mkdir -p "$OUT"

crop() { # in out w h x y
  ffmpeg -hide_banner -loglevel error -y -i "$1" -vf "crop=$3:$4:$5:$6" "$2"
}

for scheme in light dark; do
  cp "$SRC/panel-bare-$scheme.png"    "$OUT/panel-$scheme.png"
  cp "$SRC/settings-bare-$scheme.png" "$OUT/settings-$scheme.png"
  # the expanded repository row and its three incoming commits
  crop "$SRC/panel-bare-$scheme.png" "$OUT/commits-$scheme.png" 680 286 12 96
  # just the action row: Pull, Mark as seen, Open in ...
  crop "$SRC/panel-bare-$scheme.png" "$OUT/actions-$scheme.png" 680 78 12 370
done
# the social card ships as JPEG; the PNG master stays in docs/screenshots
sips -s format jpeg -s formatOptions 80 "$SRC/og.png" --out "$OUT/og.jpg" >/dev/null

for f in "$OUT"/*.png; do
  cwebp -quiet -q 92 -alpha_q 100 "$f" -o "${f%.png}.webp"
done

echo "site assets:"
for f in "$OUT"/*.png "$OUT"/*.webp; do
  printf "  %-28s %6s KB  %s\n" "$(basename "$f")" "$(( $(stat -f%z "$f") / 1024 ))" "$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
done
