#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA_DIR="$ROOT_DIR/docs/media"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
FONT="/System/Library/Fonts/Helvetica.ttc"

mkdir -p "$MEDIA_DIR"

/usr/bin/xcrun swift run \
  --package-path "$ROOT_DIR/AgentKeyringPackage" \
  agent-keyring-docs-renderer \
  "$MEDIA_DIR"

FILTER_COMPLEX="
[0:v]scale=1200:600:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:20:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='1. Enable secure import once':fontcolor=0x17191c:fontsize=36:x=(w-text_w)/2:y=650[v0];
[1:v]scale=1200:600:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:20:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='2. Export all items from Apple Passwords':fontcolor=0x17191c:fontsize=36:x=(w-text_w)/2:y=650[v1];
[2:v]scale=1200:600:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:20:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='3. Choose which credentials agents can use':fontcolor=0x17191c:fontsize=36:x=(w-text_w)/2:y=650[v2];
[3:v]scale=1200:600:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:20:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='4. Ask a model to suggest the rules':fontcolor=0x17191c:fontsize=36:x=(w-text_w)/2:y=650[v3];
[4:v]scale=1200:600:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:20:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='5. Approve sensitive requests once':fontcolor=0x17191c:fontsize=36:x=(w-text_w)/2:y=650[v4];
[v0][v1]xfade=transition=fade:duration=0.5:offset=3.5[x1];
[x1][v2]xfade=transition=fade:duration=0.5:offset=7.0[x2];
[x2][v3]xfade=transition=fade:duration=0.5:offset=10.5[x3];
[x3][v4]xfade=transition=fade:duration=0.5:offset=14.0,format=yuv420p[video]
"

"$FFMPEG" -hide_banner -loglevel error -y \
  -loop 1 -framerate 30 -t 4 -i "$MEDIA_DIR/setup.png" \
  -loop 1 -framerate 30 -t 4 -i "$MEDIA_DIR/ready.png" \
  -loop 1 -framerate 30 -t 4 -i "$MEDIA_DIR/access.png" \
  -loop 1 -framerate 30 -t 4 -i "$MEDIA_DIR/assistant.png" \
  -loop 1 -framerate 30 -t 4 -i "$MEDIA_DIR/approval.png" \
  -filter_complex "$FILTER_COMPLEX" \
  -map "[video]" -t 18 -r 30 -an -movflags +faststart \
  "$MEDIA_DIR/agent-keyring-demo.mp4"

"$FFMPEG" -hide_banner -loglevel error -y \
  -i "$MEDIA_DIR/agent-keyring-demo.mp4" \
  -filter_complex "fps=12,scale=960:-1:flags=lanczos,split[frames][palette_source];[palette_source]palettegen=max_colors=128[palette];[frames][palette]paletteuse=dither=bayer" \
  "$MEDIA_DIR/agent-keyring-demo.gif"

echo "Rendered README media in $MEDIA_DIR"
