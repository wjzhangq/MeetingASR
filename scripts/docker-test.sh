#!/usr/bin/env bash
# 在 Linux 容器中编译并运行与平台无关的单元测试（macOS 上直接 `swift test` 即可）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SWIFT_IMAGE:-swift:6.0-noble}"
docker run --rm -v "$ROOT":/src -v meetingasr-build:/src/.build -w /src "$IMAGE" \
  bash -c "command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl bzip2 >/dev/null; }
           scripts/fetch-sherpa-onnx.sh && swift ${*:-test}"
