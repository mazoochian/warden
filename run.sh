#!/usr/bin/env bash
# Convenience wrapper for the two ways warden gets run on this desktop:
#   ./run.sh dev      zig build run, straight against .env (fast iteration)
#   ./run.sh deploy    docker compose up -d --build (container, like prod)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

cmd="${1:-}"

case "$cmd" in
  dev)
    set -a
    . ./.env
    set +a
    exec zig build run
    ;;
  deploy)
    docker compose up -d --build
    docker compose ps
    ;;
  *)
    echo "usage: $0 {dev|deploy}" >&2
    echo "  dev     run natively via 'zig build run' (sources .env)" >&2
    echo "  deploy  docker compose up -d --build (warden + searxng)" >&2
    exit 1
    ;;
esac
