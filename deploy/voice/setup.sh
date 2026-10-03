#!/bin/sh
# Sets up the natural navigation voice: installs Piper (a local neural text-to-speech) into the server's virtualenv and downloads two voice models into
# data/voice-models/ (about 60 to 120 MB each). Needs the network once; nothing is sent anywhere afterwards. Run it from anywhere, then restart the service:
#     sh deploy/voice/setup.sh && sudo systemctl restart ride-logger
# Pick other voices with VOICE_EN_MODEL / VOICE_DE_MODEL in .env (names from https://huggingface.co/rhasspy/piper-voices) and run this again.
set -eu
cd "$(dirname "$0")/../.."
EN="${VOICE_EN_MODEL:-$(sed -n 's/^VOICE_EN_MODEL=//p' .env 2>/dev/null | tail -1)}"; EN="${EN:-en_US-ryan-high}"
DE="${VOICE_DE_MODEL:-$(sed -n 's/^VOICE_DE_MODEL=//p' .env 2>/dev/null | tail -1)}"; DE="${DE:-de_DE-thorsten-medium}"
DIR="data/voice-models"
BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main"
.venv/bin/pip install -r requirements-voice.txt
mkdir -p "$DIR"
for NAME in "$EN" "$DE"; do
  LANG_CODE="${NAME%%-*}"                                  # en_GB
  REST="${NAME#*-}"; SPEAKER="${REST%-*}"; QUALITY="${REST##*-}"
  URL="$BASE/${LANG_CODE%%_*}/$LANG_CODE/$SPEAKER/$QUALITY/$NAME"
  for EXT in onnx onnx.json; do
    if [ ! -s "$DIR/$NAME.$EXT" ]; then
      curl -fL --retry 3 -o "$DIR/$NAME.$EXT.part" "$URL.$EXT"
      mv "$DIR/$NAME.$EXT.part" "$DIR/$NAME.$EXT"
    fi
  done
  echo "voice ready: $NAME"
done
