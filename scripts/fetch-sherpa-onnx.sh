#!/usr/bin/env bash
# 下载 sherpa-onnx 预编译共享库（C API + onnxruntime）到 Vendor/sherpa-onnx。
# 版本需与 Sources/SherpaOnnx/SherpaOnnx.swift 一致。
set -euo pipefail
VERSION="${SHERPA_ONNX_VERSION:-v1.13.8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/sherpa-onnx"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  FLAVOR="osx-arm64-shared" ;;
  Darwin-x86_64) FLAVOR="osx-universal2-shared" ;;
  Linux-x86_64)  FLAVOR="linux-x64-shared" ;;
  Linux-aarch64) FLAVOR="linux-aarch64-shared-cpu" ;;
  *) echo "unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

NAME="sherpa-onnx-$VERSION-$FLAVOR"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION/$NAME.tar.bz2"

if [[ -f "$DEST/.version" && "$(cat "$DEST/.version")" == "$NAME" ]]; then
  echo "sherpa-onnx already present: $NAME"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $URL"
curl -fSL "$URL" -o "$TMP/pkg.tar.bz2"
tar xjf "$TMP/pkg.tar.bz2" -C "$TMP"
rm -rf "$DEST"; mkdir -p "$DEST"

# Linux shared-cpu 包不含 include/，从源码仓库下载头文件
if [[ -d "$TMP/$NAME/include" ]]; then
  cp -R "$TMP/$NAME/include" "$DEST/include"
else
  echo "Fetching headers from source repository..."
  mkdir -p "$DEST/include/sherpa-onnx/c-api"
  curl -fSL "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VERSION/sherpa-onnx/c-api/c-api.h" \
    -o "$DEST/include/sherpa-onnx/c-api/c-api.h"
fi

mkdir -p "$DEST/lib"
cp -a "$TMP/$NAME/lib/"*sherpa-onnx-c-api* "$TMP/$NAME/lib/"*onnxruntime* "$DEST/lib/"
echo "$NAME" > "$DEST/.version"
echo "Installed to $DEST"
