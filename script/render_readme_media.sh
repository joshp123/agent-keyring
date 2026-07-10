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

"$FFMPEG" -hide_banner -loglevel error -y \
  -i "$MEDIA_DIR/approval.png" \
  -i "$MEDIA_DIR/native-watch-prompt.png" \
  -filter_complex "
    color=c=0xf3f5f9:s=1280x640[base];
    [0:v]scale=-1:590[app];
    [1:v]scale=-1:340[prompt];
    [base][app]overlay=55:25[with_app];
    [with_app][prompt]overlay=900:150[out]
  " \
  -map '[out]' -frames:v 1 "$MEDIA_DIR/approval-watch.png"

FILTER_COMPLEX="
color=c=0x0b1020:s=1280x720:r=30:d=3.6,drawtext=fontfile=${FONT}:text='Ask Codex to sign in.':fontcolor=white:fontsize=58:x=(w-text_w)/2:y=260,drawtext=fontfile=${FONT}:text='Agent Keyring handles the password — with your rules.':fontcolor=0xa7f3d0:fontsize=31:x=(w-text_w)/2:y=350[intro];
[0:v]scale=1200:610:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:16:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='Apple Passwords stays your source of truth':fontcolor=0x17191c:fontsize=34:x=(w-text_w)/2:y=658[ready];
[1:v]scale=1200:610:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:16:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='Sensitive access asks on Apple Watch or Touch ID':fontcolor=0x17191c:fontsize=34:x=(w-text_w)/2:y=658[approval];
[2:v]scale=1200:610:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:16:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='Choose Ask, Automatic or Blocked':fontcolor=0x17191c:fontsize=34:x=(w-text_w)/2:y=658[access];
[3:v]scale=1200:610:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:16:color=0xf3f5f9,drawtext=fontfile=${FONT}:text='Or let a model suggest every rule':fontcolor=0x17191c:fontsize=34:x=(w-text_w)/2:y=658[assistant];
[intro][ready]xfade=transition=fade:duration=0.45:offset=3.15[x1];
[x1][approval]xfade=transition=fade:duration=0.45:offset=6.30[x2];
[x2][access]xfade=transition=fade:duration=0.45:offset=9.45[x3];
[x3][assistant]xfade=transition=fade:duration=0.45:offset=12.60,format=yuv420p[video]
"

"$FFMPEG" -hide_banner -loglevel error -y \
  -loop 1 -framerate 30 -t 3.6 -i "$MEDIA_DIR/ready.png" \
  -loop 1 -framerate 30 -t 3.6 -i "$MEDIA_DIR/approval-watch.png" \
  -loop 1 -framerate 30 -t 3.6 -i "$MEDIA_DIR/access.png" \
  -loop 1 -framerate 30 -t 3.6 -i "$MEDIA_DIR/assistant.png" \
  -filter_complex "$FILTER_COMPLEX" \
  -map "[video]" -t 15.75 -r 30 -an -movflags +faststart \
  "$MEDIA_DIR/agent-keyring-demo.mp4"

"$FFMPEG" -hide_banner -loglevel error -y \
  -i "$MEDIA_DIR/agent-keyring-demo.mp4" \
  -filter_complex "fps=12,scale=960:-1:flags=lanczos,split[frames][palette_source];[palette_source]palettegen=max_colors=128[palette];[frames][palette]paletteuse=dither=bayer" \
  "$MEDIA_DIR/agent-keyring-demo.gif"

echo "Rendered README media in $MEDIA_DIR"
