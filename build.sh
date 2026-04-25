#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_TAG="${ISO_BUILDER_IMAGE:-bootstrap-pxe/iso-builder:local}"
CACHE_VOL="${ISO_BUILDER_CACHE:-bootstrap-pxe-builder-cache}"

docker build -t "$IMAGE_TAG" "$SCRIPT_DIR"

docker run --rm -it \
    --privileged \
    -v "$SCRIPT_DIR":/work \
    -v "$CACHE_VOL":/var/lib/docker \
    "$IMAGE_TAG"
