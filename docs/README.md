# Warden documentation

This directory is the home for how Warden behaves and why — for people and
for AI assistants working on the code. Source comments are kept short and
local (what a function does that its signature doesn't say); anything about
overall behaviour, cross-module flows, policies, or history belongs here.

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | Process model, threads, the per-message pipeline, module layout |
| [configuration.md](configuration.md) | Environment variables, dynamic config, feature flags, and how they layer |
| [access-control.md](access-control.md) | Owner / bot admin / platform admin / `/sudo`, the blocklist, the owner-only LLM gate, management rooms and audit/undo |
| [llm.md](llm.md) | The Q&A pipeline: context assembly, providers, the tool loop, streaming, thinking, empty turns, tool traces |
| [platforms.md](platforms.md) | Telegram Bot API, Matrix (+E2EE), XMPP, the personal Telegram account (TDLib), Instagram — capabilities and quirks per platform |
| [features.md](features.md) | Every feature module: what it does, who may use it, where its state lives |
| [commands.md](commands.md) | Command reference with access gates |
| [storage.md](storage.md) | Postgres, the connection pool, migrations, retention and Storage Sense |
| [web-api.md](web-api.md) | The HTTP/WebSocket API behind warden-ui: sessions, identity resolution, rate limits |
| [operations.md](operations.md) | Build, run, Docker, health checks and the self-watchdog, logging, timeouts |
| [testing.md](testing.md) | Running the suite, the test database, registration gotchas, known flakes |
| [decisions.md](decisions.md) | Design decisions and incident history — the "why" behind non-obvious code |

`ROADMAP.md` at the repository root is the chronological development log
(phases, dated entries); these documents describe the current state.

## Comment policy

- A `///` doc comment states what the item does when that isn't clear from
  its name and signature — one to three lines. It does not explain history,
  alternatives considered, or how other modules use it.
- A `//!` module comment is a short paragraph on what the module is for.
- Inline `//` comments mark a genuinely surprising line (a workaround, an
  ordering constraint, a load-bearing detail). Not narration.
- When a change needs a paragraph of explanation, write it in the relevant
  document here (and `decisions.md` if it is a "why", not a "what") and, at
  most, leave a one-line pointer in the code.
