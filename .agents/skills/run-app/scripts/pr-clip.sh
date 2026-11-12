#!/bin/zsh
# pr-clip.sh <in.mp4> <folder> — make a PR's clip with sound (#4856) from a take of
# scripts/video/make.py (voice mode's tape, #4854): at most 720p and 30 s, H.264 and AAC,
# under GitHub's 10 MB a file. It writes <folder>/<name of in>.mp4 and prints its path.
#
# <folder> is the one the browser tools upload from: their output folder,
# ~/Library/Caches/com.alexecollins.agents/browser/output/<agent>, which the first browser_*
# call of a turn makes. With "browser" for <folder>, the script takes the one folder there
# and stops when there is none or more than one; give the path when other agents use the
# browser. The upload itself is done with the browser tools (run-app SKILL.md, "A clip
# with sound").
set -euo pipefail

if (( $# != 2 )); then
  print -u2 "usage: pr-clip.sh <in.mp4> <folder | browser>"
  exit 2
fi
in=$1 folder=$2
[[ -f $in ]] || { print -u2 "pr-clip: $in is not a file"; exit 2; }
for tool in ffmpeg ffprobe; do
  command -v $tool >/dev/null || { print -u2 "pr-clip: $tool is missing (brew install ffmpeg)"; exit 2; }
done

if [[ $folder == browser ]]; then
  base=${PR_CLIP_BROWSER_OUTPUT:-$HOME/Library/Caches/com.alexecollins.agents/browser/output}
  folders=($base/*(N/))
  if (( ${#folders} != 1 )); then
    print -u2 "pr-clip: ${#folders} folders in $base, not one: call a browser_* tool first, or give the folder"
    exit 2
  fi
  folder=${folders[1]}
fi
[[ -d $folder ]] || { print -u2 "pr-clip: $folder is not a folder"; exit 2; }

audio=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$in")
[[ -n $audio ]] || { print -u2 "pr-clip: $in has no sound track; a silent clip is scripts/video/clip.sh's (#4094)"; exit 2; }
seconds=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in")
if (( seconds > 30 )); then
  print -u2 "pr-clip: $in is ${seconds%.*} s long; the clip keeps the first 30 s"
fi

out=$folder/${in:t:r}.mp4
ffmpeg -v error -y -i "$in" -t 30 \
  -vf "scale=-2:'min(720,ih)'" -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$out"

bytes=$(stat -f %z "$out")
if (( bytes >= 10 * 1024 * 1024 )); then
  rm -f "$out"
  print -u2 "pr-clip: the clip is $(( bytes / 1024 / 1024 )) MB, over GitHub's 10 MB: make the take shorter"
  exit 1
fi
print -r -- "$out"
