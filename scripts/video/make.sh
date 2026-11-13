#!/bin/sh
# Makes the docs site's narrated videos with no person (#1078). See make.py and README.md.
#
#   scripts/video/make.sh u1 a2 …   [--no-build] [--keep] [--voice-only] [--compose-only] [--upload]
#   scripts/video/make.sh --sign-in linear   the video Chrome, for the person to sign in once
#
# The first run makes the voice and Whisper set-up in ~/.cache/agents-video/venv (mlx-audio
# and mlx-whisper), and fetches the voice's weights (Qwen3-TTS, about 4 GB) into the Hugging
# Face cache, once (#5079). --preflight fetches nothing: it says when they are missing.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
venv="$HOME/.cache/agents-video/venv"
if [ ! -x "$venv/bin/python" ]; then
	uv venv -q --python 3.11 "$venv"
fi
if ! "$venv/bin/python" -c "import mlx_audio, mlx_whisper, soundfile, PIL" 2>/dev/null; then
	VIRTUAL_ENV="$venv" uv pip install -q mlx-audio==0.6.5 soundfile mlx-whisper pillow
fi
case " $* " in
*" --preflight "*) ;;
*) "$venv/bin/python" "$here/voice.py" --fetch ;;
esac
exec "$venv/bin/python" "$here/make.py" "$@"
