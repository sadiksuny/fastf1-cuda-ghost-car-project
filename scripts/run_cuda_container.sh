#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="f1-cuda-ghost:dev"

docker build -f Dockerfile.cuda -t "$IMAGE_NAME" .
docker run --rm -it --gpus all \
  -v "$(pwd)":/workspace/f1 \
  -w /workspace/f1 \
  "$IMAGE_NAME"
