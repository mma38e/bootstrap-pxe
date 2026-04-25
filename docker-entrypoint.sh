#!/bin/bash
set -euo pipefail

# Start dockerd in the background. /var/lib/docker is a named volume so the
# image cache (notably ansible-runner ~1.5 GB) persists between runs locally.
dockerd \
    --host=unix:///var/run/docker.sock \
    --storage-driver=overlay2 \
    >/var/log/dockerd.log 2>&1 &

DOCKERD_PID=$!
trap 'kill -TERM "$DOCKERD_PID" 2>/dev/null || true; wait "$DOCKERD_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
done

if ! docker info >/dev/null 2>&1; then
    echo "[entrypoint] dockerd failed to start within 30s" >&2
    tail -50 /var/log/dockerd.log >&2 || true
    exit 1
fi

exec "$@"
