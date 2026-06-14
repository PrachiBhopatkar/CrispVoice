#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-base}"   # base | small | medium | large-v3
DEST="Models"

case "$MODEL" in
  base|small|medium|large-v3) ;;
  *)
    echo "Unsupported model: $MODEL" >&2
    exit 1
    ;;
esac

mkdir -p "$DEST"

URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"

echo "Downloading ggml-${MODEL}.bin ..."
curl -L --fail -o "${DEST}/ggml-${MODEL}.bin" "$URL"
echo "Saved to ${DEST}/ggml-${MODEL}.bin"
