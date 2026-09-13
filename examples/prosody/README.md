# Prosody — test-only XMPP server

A local XMPP server for developing against the XMPP connector. Test-only:
self-signed TLS and `internal_plain` auth storage — see the comments in
`config/prosody.cfg.lua`.

```bash
docker compose -f compose.yaml -f examples/prosody/compose.yaml up -d
docker compose exec prosody prosodyctl adduser bot@localhost
```

Then in `.env`:
```bash
export WARDEN_XMPP_JID=bot@localhost
export WARDEN_XMPP_PASSWORD=<the password you chose>
export WARDEN_XMPP_OWNER_ID=you@localhost
export WARDEN_XMPP_SERVER=prosody:5222      # compose service name, not the JID domain
export WARDEN_XMPP_TLS_MODE=self_signed     # default; bundle needs a real certificate
```
