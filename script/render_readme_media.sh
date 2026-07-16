#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEDIA_DIR="$ROOT_DIR/docs/media"
STORY_DIR="$ROOT_DIR/.build/readme-story"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"

mkdir -p "$MEDIA_DIR" "$STORY_DIR"
shopt -s nullglob
story_frames=("$STORY_DIR"/*.png)
if ((${#story_frames[@]})); then
  trash "${story_frames[@]}"
fi

/usr/bin/xcrun swift run \
  --package-path "$ROOT_DIR/AgentKeyringPackage" \
  agent-keyring-docs-renderer \
  "$MEDIA_DIR" \
  "$STORY_DIR"

"$FFMPEG" -hide_banner -loglevel error -y \
  -i "$STORY_DIR/approval.png" \
  -frames:v 1 "$MEDIA_DIR/approval-watch.png"

FILTER_COMPLEX="
[0:v]zoompan=z='min(zoom+0.00016,1.020)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=128:s=1920x1080:fps=30,trim=duration=4.25,setpts=PTS-STARTPTS[p0];
[1:v]zoompan=z='min(zoom+0.00028,1.036)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=128:s=1920x1080:fps=30,trim=duration=4.25,setpts=PTS-STARTPTS[p1];
[2:v]zoompan=z='min(zoom+0.00035,1.045)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=128:s=1920x1080:fps=30,trim=duration=4.25,setpts=PTS-STARTPTS[p2];
[3:v]zoompan=z='min(zoom+0.00028,1.036)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=128:s=1920x1080:fps=30,trim=duration=4.25,setpts=PTS-STARTPTS[p3];
[4:v]zoompan=z='if(eq(on,0),1.040,max(zoom-0.00032,1.0))':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=128:s=1920x1080:fps=30,trim=duration=4.25,setpts=PTS-STARTPTS[p4];
[p0][p1]xfade=transition=fade:duration=0.28:offset=3.97[x1];
[x1][p2]xfade=transition=fade:duration=0.28:offset=7.94[x2];
[x2][p3]xfade=transition=fade:duration=0.28:offset=11.91[x3];
[x3][p4]xfade=transition=fade:duration=0.28:offset=15.88,format=yuv420p[video]
"

"$FFMPEG" -hide_banner -loglevel error -y \
  -loop 1 -framerate 30 -t 4.25 -i "$STORY_DIR/problem.png" \
  -loop 1 -framerate 30 -t 4.25 -i "$STORY_DIR/rules.png" \
  -loop 1 -framerate 30 -t 4.25 -i "$STORY_DIR/approval.png" \
  -loop 1 -framerate 30 -t 4.25 -i "$STORY_DIR/assistant.png" \
  -loop 1 -framerate 30 -t 4.25 -i "$STORY_DIR/complete.png" \
  -filter_complex "$FILTER_COMPLEX" \
  -map "[video]" -t 20.13 -r 30 -an -c:v libx264 -crf 18 -preset medium \
  -movflags +faststart \
  "$MEDIA_DIR/agent-keyring-demo.mp4"

"$FFMPEG" -hide_banner -loglevel error -y \
  -i "$MEDIA_DIR/agent-keyring-demo.mp4" \
  -filter_complex "fps=10,scale=800:-1:flags=lanczos,split[frames][palette_source];[palette_source]palettegen=max_colors=96[palette];[frames][palette]paletteuse=dither=bayer" \
  "$MEDIA_DIR/agent-keyring-demo.gif"

echo "Rendered README media in $MEDIA_DIR"
