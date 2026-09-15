# SearXNG — private web search

A private metasearch instance backing warden's `web_search` tool, with no
API keys and no bot checks. This is the sidecar most deployments want.

```bash
docker compose -f compose.yaml -f examples/searxng/compose.yaml up -d
```

The fragment sets `WARDEN_SEARXNG_URL` for the bot automatically. Without
it, set that variable yourself in `.env` (the instance must have
`format=json` enabled, which `settings.yml` here does) or the tool stays
disabled.
