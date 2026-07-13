#!/bin/sh
# Warden reads its configuration from environment variables only; the .env
# file is plain shell (`export VAR=...`), so source it if one is mounted at
# /app/.env. `set -a` also exports any lines written without `export`.
set -e
if [ -f /app/.env ]; then
    set -a
    . /app/.env
    set +a
fi
exec /app/warden "$@"
