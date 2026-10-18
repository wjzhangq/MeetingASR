#!/usr/bin/env bash
# 下载随 App 打包的模型到 Resources/models（目录结构见 docs/models.md）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 用法：scripts/fetch-models.sh [目标目录] [--with-asr sensevoice]...
# 额外的 SenseVoice 模型可选（体积较大），放在 asr-sensevoice/。
DEST=""
EXTRA_ASR=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-asr) EXTRA_ASR+=("$2"); shift 2 ;;
    *) DEST="$1"; shift ;;
  esac
done
DEST="${DEST:-$ROOT/Resources/models}"
R="https://github.com/k2-fsa/sherpa-onnx/releases/download"
mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_tar() { # url dirname-inside-archive target-subdir
  local url="$1" inner="$2" target="$DEST/$3"
  [[ -d "$target" ]] && { echo "skip $3"; return; }
  echo "Downloading $url"
  curl -fSL "$url" -o "$TMP/a.tar.bz2"
  tar xjf "$TMP/a.tar.bz2" -C "$TMP"
  mv "$TMP/$inner" "$target"
  rm -f "$TMP/a.tar.bz2"
}
fetch_file() { # url target-path
  local url="$1" target="$DEST/$2"
  [[ -f "$target" ]] && { echo "skip $2"; return; }
  mkdir -p "$(dirname "$target")"
  echo "Downloading $url"
  curl -fSL "$url" -o "$target"
}

fetch_tar  "$R/asr-models/sherpa-onnx-paraformer-zh-2023-09-14.tar.bz2" sherpa-onnx-paraformer-zh-2023-09-14 asr
fetch_tar  "$R/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" sherpa-onnx-pyannote-segmentation-3-0 segmentation
fetch_file "$R/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx" embedding/campplus.onnx
fetch_tar  "$R/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar.bz2" sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12 punct
fetch_file "$R/asr-models/silero_vad.onnx" vad/silero_vad.onnx

for m in "${EXTRA_ASR[@]+"${EXTRA_ASR[@]}"}"; do
  case "$m" in
    sensevoice)
      fetch_tar "$R/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2" sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17 asr-sensevoice
      find "$DEST/asr-sensevoice" -mindepth 1 ! -name 'model.onnx' ! -name 'tokens.txt' -exec rm -rf {} +
      ;;
    *) echo "unknown asr model: $m (sensevoice)" >&2; exit 1 ;;
  esac
done

# 仅保留运行所需文件，减小安装包
find "$DEST/asr" -type f ! -name 'model.int8.onnx' ! -name 'tokens.txt' -delete
find "$DEST/segmentation" -type f ! -name 'model.onnx' -delete
find "$DEST/punct" -type f ! -name 'model.onnx' -delete
find "$DEST" -type d -empty -delete
du -sh "$DEST"
