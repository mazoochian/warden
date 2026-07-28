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
# No args (the normal `docker compose up warden` path, and every other
# service's own entrypoint invocation) -> run the bot itself. A command
# WAS given (e.g. `docker compose run --rm warden ./cleanup-left-chats`)
# -> exec exactly that instead, with .env already sourced into the
# environment either way. Previously this unconditionally ran
# `/app/warden "$@"`, silently passing any other command as an ignored
# argv to the bot itself instead of actually running it -- confirmed live
# 2026-07-28: `docker compose run --rm warden ./cleanup-left-chats` just
# started a second full bot instance, which fought the real one over
# Telegram's getUpdates long-poll (409 Conflict) for several minutes
# before being noticed and killed.
if [ "$#" -eq 0 ]; then
    exec /app/warden
fi
exec "$@"
