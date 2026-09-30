# The LLM pipeline

Free-form questions, the messaging-mode commands (`/translate`, `/rewrite`,
`/eli5`, `/brainstorm`, `/joke`, ...) and the reply-autonomy ghostwriter all
go through `qa.answer` → `toolcall.runDetailed` → a provider adapter.

## When the bot answers

`handleMessage` treats a message as addressed to the bot when it is a
private chat, mentions the bot's username, replies to one of the bot's
messages, or contains the chat's magic word (`/magicword`). `/command@bot`
qualifiers are stripped (`normalizeCommandMention`); a qualifier naming a
*different* bot makes the message be ignored entirely. `!command` is
accepted everywhere as an alias for `/command` because Matrix clients
swallow a leading slash.

Before any model call: a message that is only a video link is skipped
(the passive downloader already handles it); a trivial greeting/ack gets a
canned reply (`features/trivial_reply.zig`, `WARDEN_LLM_SKIP_TRIVIAL_MESSAGES`);
then the owner-only gate (access-control.md).

## Building the prompt (`features/qa.zig`)

System prompt = the per-chat persona if set, else `WARDEN_SYSTEM_PROMPT`,
else `default_system_prompt`; followed by a length budget line; followed
by a **generated tool list** —
one line per tool actually enabled for this chat, with the head of its
description. The list is generated per request so it can never drift from
what is callable; when asked what it can do, the model is told to answer
from it.

User message = the context block from `features/context_assembly.zig`,
then "This message is from: <name (@handle, platform id)>", then the
question (or the replied-to bot message plus the reply). The asker line
exists because group chats have many participants and the history's tags
alone don't identify the current speaker.

The context block, under hard character budgets per section:

1. `Today is <weekday>, <date> <time> UTC.` — dates are always computed
   here, never left for the model to infer.
2. Stable facts about the asker (pinned + hybrid-ranked), then a small set
   of tentative facts under a "may be stale" heading. Facts are bitemporal
   (`facts.valid_to`, `superseded_by`); a contradicted fact is never
   retrieved.
3. Ranked/recent daily digests of this chat (`daily_digests`).
4. Recent chat history: the last `WARDEN_LLM_HISTORY_MESSAGES` rows as
   `who: text` lines, prefixed with a `-- Weekday YYYY-MM-DD --` marker
   whenever the local day changes (`messages.appendDayMarker`) — including
   before the very first line, so a window that's been truncated to fit its
   character budget still opens with a real date rather than an undated
   wall of text. `truncateTail` re-attaches the nearest dropped marker if
   the cut fell after one, at the cost of a small, bounded overshoot past
   the budget. The bot's own lines carry `[used: tool(args) -> result;
   ...]` when tools ran (see "Tool traces").

Ranking uses an embedding of the question when `WARDEN_EMBEDDINGS_URL` is
configured, otherwise the keyword/recency/salience terms alone.

**Reply length.** The length budget line states the target from
`WARDEN_LLM_REPLY_LENGTH` (`qa.ReplyLength`: `"<n> paragraphs"`,
`"<n> words"`, `"<n> tokens"` or `"off"`; default `1 paragraph`), then the
platform's message limit explicitly as a ceiling "not a length to aim
for". Before this setting existed the line only said "keep replies under
4096 characters", which models read as a target and answered with three
or four paragraphs regardless of the Style section asking for one.
Paragraphs and words are instructions the user can override by asking for
detail (translations and rewrites of a given text are exempt too); tokens
is also a hard `max_tokens` cap on the whole output — reasoning models
spend part of it thinking, so a tight token cap can produce empty replies.

`max_tokens` = the tighter of `WARDEN_LLM_MAX_TOKENS` and a token-unit
reply length when either is set; otherwise a 4000-token reserve for
reasoning models' chain of thought plus `platform_limit / 3` for the
visible answer. All of `context_assembly.zig`'s budgets are character-based,
not a real token count — `qa.calibrateTokenBudget` cross-checks that
estimate against Anthropic's `/v1/messages/count_tokens`
(`Provider.countTokens`, `null` for providers that don't implement it) once
a prompt is large enough to matter, logging a warning rather than blocking
the request if the real count runs ahead of the estimate.

## The tool loop (`llm/toolcall.zig`)

`runDetailed` sends the conversation, executes every `tool_use` the model
returns (in order, feeding results back as `tool_result`s), and repeats up
to `max_iterations` (6). On the cap it sends one final "wrap up now" turn.
It returns `RunResult { text, tool_calls, stop_reason }`.

Per model call, `callProviderWithRetry` retries transient failures
(timeouts, dropped connections, 429/5xx, empty bodies) up to
`WARDEN_LLM_MAX_RETRIES` times with exponential backoff (1 s, 2 s, 4 s),
reporting each retry to the progress ticker. Only the failed HTTP call is
repeated — tools already executed are never re-run.

**Empty final turn.** If the model's last turn has no visible text, the
loop does not append that turn (an empty assistant message is rejected by
Anthropic and dropped by the OpenAI writer anyway); it appends a user
nudge — a length-limit variant when `stop_reason == .max_tokens` — and asks
once more. A second empty turn is returned as empty text and
`replyWithAnswer` shows a short fallback ("✅ Done." when tools ran, a
"couldn't put together a reply" line otherwise) and logs a WARN with the
stop reason, thinking size and tools run. This replaced silently deleting
the placeholder; see decisions.md, "Empty replies".

**Cancellation.** The placeholder carries a 🛑 Cancel button
(`features/cancel_request.zig`); pressing it sets an atomic flag the loop
checks before every model call and every tool execution. An HTTP call
already in flight is not interrupted (there is no cancellation point for
it) — the cancel takes effect when that call returns.

**Progress.** The loop reports `thinking`, `tool_use{name, input_digest}`,
`text` (cumulative, when streaming) and `retry` events; `main.zig`'s
`tickerLoop` renders them into the placeholder ("thinking…", "using
weather…", the streamed text). Ticker edits go through a dedicated thread
that is stopped with a bounded wait and detached if it doesn't stop.

Tool results are sanitised to valid UTF-8 (invalid bytes → U+FFFD) before
they reach the wire; Anthropic rejects a request whose tool result isn't a
JSON string.

## Providers (`llm/provider.zig`, `anthropic.zig`, `openai_compat.zig`)

Both adapters implement `chat` and `chatStream` (SSE). The content model is
`ContentBlock = text | thinking | image | document | tool_use |
tool_result`; `StopReason = end_turn | tool_use | max_tokens | other`.

- **Anthropic**: Messages API, no extended thinking requested. `thinking`
  blocks in the history are skipped on write (they would need signatures).
- **OpenAI-compatible** (Ollama, llama.cpp, vLLM, OpenRouter, other
  gateways): tool results become standalone `role: tool` messages; images
  become `image_url` data URLs; PDFs have no equivalent and degrade to a
  note in the text. A reasoning model's `reasoning_content` /
  `reasoning` field is kept as a `thinking` block and **handed back on the
  next assistant turn under the same field name** the backend used —
  interleaved-thinking models (MiniMax M-series) need their earlier
  reasoning next to their tool calls, and without it the turn after a tool
  result routinely comes back empty. Inline `<think>…</think>` tags in
  `content` are stripped (or, with show-thinking on, rewrapped) instead.
  `finish_reason: length` maps to `max_tokens`.

`WARDEN_LLM_PROVIDER` selects the default; `llm/dynamic_provider.zig`
re-reads dynamic config per call so it can be switched live. Delegates
(`WARDEN_DELEGATES`) are additional fixed providers the model can address
by name through the `ask_delegate` / `delegate_generate_image` tools.

**Show thinking.** `WARDEN_LLM_SHOW_THINKING` (per-chat override via
`/thinking`) renders `thinking` blocks ahead of the answer wrapped in the
control bytes `llm.thinking_start`/`thinking_end`; Telegram renders those
as an expandable blockquote (`platform/telegram/markdown_html.zig`), other
platforms as a "💭" paragraph (`renderThinkingPlain`). The markers must
never reach a user raw.

**Streaming.** `WARDEN_LLM_STREAMING` uses `chatStream`; visible text is
edited into the placeholder as it arrives (throttled by the ticker). Tool
calls are assembled whole before execution.

## Tools (`src/tools/`)

Each tool is a `ToolDef { name, description, input_schema_json, execute }`.
`execute` receives a `ToolContext` with the allocator, `Io`, and optional
sinks/handles: the connector and chat (for tools with side effects like
`draw_diagram`, `create_poll`, `qr_code`), the attachment path, the
reminder/alert/note/expense/memory sinks, the member directory, the
scraper config, the personal-account handles (owner only), and delegates.
A tool whose sink is null is filtered out of the list (`filterEnabledTools`)
rather than offered and failing.

Tools with side effects that already produce visible output (a photo, a
poll, a message sent through the personal account) are the usual reason
for an empty final text — the model considers the work done.

## Tool traces

`replyWithAnswer` stores the bot's reply with `messages.tool_trace`: a
compact `name(args) -> result; …` line (`toolcall.formatTrace`, arguments
capped at 80 bytes, results at 160, total ~700). The history renders it as
`warden: [used: …] <reply>`, and the system prompt tells the model what the
tag means — so on the next turn it knows what it actually did, including
turns whose visible text was just "Done.".

## Placeholders and delivery

On platforms that support editing (Telegram), a "thinking" placeholder is
sent immediately, animated by the ticker, then edited into the answer;
elsewhere one message is sent at the end. Answers longer than the
platform limit are sent as a `.txt` attachment. Telegram output goes
through `markdown_html.toHtml` (a narrow Markdown subset → HTML; unknown or
unclosed markup passes through as literal text), with a plain-text
fallback if the API rejects the HTML.

## Other callers of the loop

Digests, briefings' summaries, the feed watcher blurbs, the curated feed's
relevance/summary calls, and the reply-autonomy ghostwriter all call
`toolcall.run` with no tools and their own prompts.
