#!/bin/zsh
# Renders the README art (scripts/readme-art/*.html) to docs/images/readme/ with
# headless Chrome at 2x. Run it after the screenshots in docs/images/ change.
#
#   scripts/readme-art/render.sh            # every image
#   scripts/readme-art/render.sh hero       # one
set -euo pipefail

here=${0:A:h}
out=${here:h:h}/docs/images/readme
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$out"

# name width height
art=(
  "hero 1000 520"
  "modes 1000 640"
  "screens 1000 560"
  "performance 1000 330"
)

for entry in $art; do
  parts=(${=entry})
  name=$parts[1] width=$parts[2] height=$parts[3]
  if (( $# )) && [[ ${@[(Ie)$name]} -eq 0 ]]; then continue; fi
  png=$(mktemp -t agello-art).png
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=2 --default-background-color=00000000 \
    --window-size=$width,$height --screenshot="$png" "file://$here/$name.html" 2>/dev/null
  cwebp -quiet -q 90 -alpha_q 100 "$png" -o "$out/$name.webp"
  rm -f "$png"
  print "$name.webp $(( $(stat -f %z "$out/$name.webp") / 1024 )) KB"
done
