const std = @import("std");
const llm = @import("../llm/provider.zig");
const toolcall = @import("../llm/toolcall.zig");
const registry = @import("../tools/registry.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const context_assembly = @import("context_assembly.zig");
const embeddings = @import("../llm/embeddings.zig");

/// Used when the operator hasn't provided their own prompt via
/// WARDEN_SYSTEM_PROMPT / WARDEN_SYSTEM_PROMPT_FILE.
pub const default_system_prompt =
    \\You are Warden, an assistant participating in a group chat. You only
    \\see the messages people direct at you (plus the recent history given
    \\below), so treat each request as coming from a real person mid-
    \\conversation.
    \\
    \\Style: reply like a chat participant — short, direct, no headers or
    \\bullet-point essays unless genuinely needed. One short paragraph
    \\answers the large majority of questions; only go longer when the user
    \\explicitly asks for detail, a list, or something long-form. Match the
    \\language the user wrote in.
    \\
    \\Grounding: the recent chat history is included below for the cases
    \\where you actually need it — the user explicitly references something
    \\earlier ("like I said", "what did you find before", "continue that"),
    \\or they're replying to one of your own messages, which you should then
    \\treat as a follow-up to it (usually a clarification request, or a
    \\remark that something you did worked or failed). Its username tags are
    \\just this platform's account handles, not names — don't infer an
    \\identity from one. Otherwise, treat each message as a standalone
    \\question and answer it on its own terms; don't let unrelated earlier
    \\messages in the history steer or color your answer.
    \\
    \\Knowledge: you are not limited to the chat. You have tools — weather
    \\and air quality, currency and crypto prices, a calculator, English and
    \\slang dictionaries, Hacker News search, QR code generation, drawing
    \\diagrams, building a word cloud out of text you provide, web search,
    \\fetching a URL's content, setting/listing/canceling reminders
    \\(set_reminder) — translate whatever natural-language time the user
    \\gave into that tool's required duration shorthand yourself, except for
    \\a named weekday ("this Friday", "on Monday"): pass the day name
    \\straight through (see the tool's own description) rather than
    \\computing a day offset yourself, since you don't reliably know what
    \\day of the week today is — the current date/time given below the
    \\question does, and the tool resolves the weekday server-side from it
    \\— and converting a photo/document/voice/audio/video the user just sent to a
    \\different format (convert_file), or starting the conversion flow
    \\(begin_file_conversion) when they say they want to convert something
    \\but haven't attached a file to this message yet — that tool just asks
    \\them to send the file; don't use it if one's already attached here.
    \\For anything
    \\factual you don't confidently know (current events, prices, releases,
    \\docs), use web_search rather than guessing or claiming you can't know;
    \\fetch a promising result with fetch_url when the snippet isn't enough.
    \\Say plainly when you couldn't find an answer.
    \\
    \\Identity: every message you receive is tagged with exactly who sent
    \\it — their name, @handle if they have one, and platform id. This is
    \\a group chat, not a conversation with one fixed person, so use that
    \\tag to keep track of who's actually talking to you turn to turn;
    \\don't assume the person asking now is the same one from earlier in
    \\the history. When the sender refers to someone else in the chat by
    \\name ("tell Courtney I said hi", "what's Alex's handle", "mention
    \\Sam"), use find_chat_member to resolve that name to their real
    \\@handle/id before answering — don't guess a username from the name
    \\alone, and if it returns more than one plausible match, ask which one
    \\they meant.
    \\
    \\Tool restraint: only call a tool when the question actually needs its
    \\specific data (a real city's weather, an actual exchange rate, and so
    \\on). Don't reach for one out of habit or because it's in the list
    \\above. But when a question DOES map to one of these tools, use it
    \\decisively and answer from its result — don't guess, hedge, or pad a
    \\tool-backed answer with generic filler once you have the real data.
    \\Questions about yourself — your name, what model or LLM you are, your
    \\capabilities — are answered directly from this prompt, never with a
    \\tool: your name is Warden, full stop, regardless of the account handle
    \\or display name this platform shows for you.
;

/// Reserved token budget for a reasoning model's `<think>...</think>` phase,
/// on top of whatever the visible answer itself needs — a chain-of-thought
/// can run to several thousand tokens for a non-trivial question, and none
/// of it counts toward the platform's *character* limit (it's stripped or
/// hidden before the user ever sees it, see `openai_compat.zig`'s
/// `stripThinkingBlock`/`shownText`). Without this, `max_tokens` sized only
/// off the visible answer's length risks the model exhausting its whole
/// budget mid-thought and never producing (or truncating) the real answer.
const thinking_token_reserve: u32 = 4000;

/// Deliberately conservative (fewer characters per token than most
/// real-world English text averages) so the *answer* portion of the budget
/// is never the actual bottleneck for a less token-efficient script/
/// language — overshooting here just means `max_tokens` is a bit more
/// generous than strictly necessary, not that a real answer gets cut short.
const min_chars_per_token: usize = 3;

/// `max_tokens` for a request whose visible answer is capped at
/// `max_answer_len` characters (the active platform's message-size limit,
/// see `main.zig`'s `effectiveMaxMessageLength`) — covers both that answer
/// and `thinking_token_reserve` worth of chain-of-thought ahead of it.
fn answerMaxTokens(max_answer_len: usize) u32 {
    const capped_chars = @min(max_answer_len, std.math.maxInt(u32) * min_chars_per_token);
    const answer_tokens: u32 = @intCast(capped_chars / min_chars_per_token);
    return thinking_token_reserve +| answer_tokens;
}

/// Identifies who's actually sending *this* turn's question — deliberately
/// separate from the "who: text" tags in `recentFormatted`'s history, which
/// only cover past messages and fall back to "unknown" for a sender with
/// neither a username nor a display name. Without this, a group chat with
/// several active participants gives the model no reliable way to tell them
/// apart on the current turn (see main.zig's `resolveSenderIdentity`/
/// `iface.Message.identity`, which is where these fields come from).
pub const Asker = struct {
    display_name: []const u8,
    username: ?[]const u8 = null,
    /// Platform-native user id (Telegram: decimal string).
    native_id: []const u8,
};

/// Grounded free-form Q&A: pulls recent local chat history (not model
/// memory) as context, then runs the tool-calling loop so the model can
/// also reach for weather/currency/calculator/web_search/fetch_url as
/// needed. `replied_to` carries the text of the (bot's) message the user
/// replied to, so follow-ups keep their referent even if it has scrolled
/// out of the history window. `asker` identifies who sent this specific
/// question — see `Asker`'s doc comment. `stream`/`show_thinking` are
/// forwarded straight to `toolcall.run`/`ChatRequest` — see
/// `config.zig`'s `llm_streaming` doc comment and
/// `store/chat_settings.zig`'s `getShowThinkingOverride` for why both are
/// caller-controlled (a global default that can be overridden) rather than
/// fixed. `max_tokens` is derived from `max_answer_len` unless
/// `max_tokens_override` is set — see `answerMaxTokens`. `history_window`
/// caps how many recent messages `recentFormatted` sends verbatim as
/// context (`config.zig`'s `llm_history_messages`) — the whole context-
/// sizing mechanism today; see `ROADMAP.md`'s backlog for a real
/// summarization-based downsampling strategy.
pub fn answer(
    provider: llm.Provider,
    embeddings_client: ?*embeddings.EmbeddingsClient,
    allocator: std.mem.Allocator,
    ctx: registry.ToolContext,
    tool_defs: []const registry.ToolDef,
    pool: *PgPool,
    chat_id: i64,
    asker_identity_id: i64,
    system_prompt: ?[]const u8,
    max_answer_len: usize,
    asker: Asker,
    question: []const u8,
    replied_to: ?[]const u8,
    progress: toolcall.Progress,
    stream: bool,
    show_thinking: bool,
    vision_enabled: bool,
    documents_enabled: bool,
    max_tokens_override: ?u32,
    history_window: i64,
) ![]const u8 {
    // ROADMAP.md's memory-layer phase: pinned/ranked facts, ranked/recent
    // daily digests, and recent chat history, all budget-capped in code —
    // see `context_assembly.zig`'s module doc comment. Never fails the
    // caller; a retrieval problem just drops that section from the prompt.
    const context = try context_assembly.assemble(
        pool,
        allocator,
        embeddings_client,
        chat_id,
        asker_identity_id,
        asker.display_name,
        question,
        ctx.now,
        history_window,
        context_assembly.default_budget,
    );

    const asker_line = if (asker.username) |u|
        try std.fmt.allocPrint(allocator, "{s} (@{s}, platform id {s})", .{ asker.display_name, u, asker.native_id })
    else
        try std.fmt.allocPrint(allocator, "{s} (platform id {s})", .{ asker.display_name, asker.native_id });

    const user_content = if (replied_to) |earlier|
        try std.fmt.allocPrint(
            allocator,
            "{s}\nThis message is from: {s}\n\nThe user is replying to this earlier message of yours:\n\"{s}\"\n\nTheir reply: {s}",
            .{ context, asker_line, earlier, question },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{s}\nThis message is from: {s}\n\nQuestion: {s}",
            .{ context, asker_line, question },
        );

    const effective_max_tokens = max_tokens_override orelse answerMaxTokens(max_answer_len);

    // When a flat `max_tokens_override` is active (a deployment tuned for
    // short, cheap answers), steer the model toward a length that actually
    // fits inside it — chars ≈ tokens × `min_chars_per_token` — rather than
    // the full platform limit, so the hard cutoff at `effective_max_tokens`
    // rarely has to actually bite (an answer cut off mid-sentence reads far
    // worse than one that was simply asked to stay short). Otherwise
    // (`max_tokens_override == null`), same behavior as before: aim for the
    // platform's own limit.
    const length_hint_chars = if (max_tokens_override) |t|
        @min(max_answer_len, @as(usize, t) * min_chars_per_token)
    else
        max_answer_len;

    // A hard file-fallback exists for whatever slips through (see
    // `main.zig`'s `sendTextOrFile`), but steering the model to stay under
    // budget up front means that rarely has to fire — most answers should
    // just read as normal chat messages, not surprise file attachments.
    const system_with_budget = try std.fmt.allocPrint(
        allocator,
        "{s}\n\nLength budget: keep replies under {d} characters when at all possible — that's the active platform's message-size limit. If the answer genuinely needs to be longer (e.g. the user asked for something long-form), that's fine: anything over the limit is sent as a file attachment automatically, so don't refuse or truncate awkwardly instead of finishing your answer.",
        .{ system_prompt orelse default_system_prompt, length_hint_chars },
    );

    return toolcall.run(provider, allocator, ctx, system_with_budget, user_content, tool_defs, progress, stream, show_thinking, vision_enabled, documents_enabled, effective_max_tokens);
}

test "answerMaxTokens reserves a thinking budget on top of the answer's own character-derived budget" {
    // Telegram's 4096-byte cap, at the conservative 3 chars/token estimate,
    // is (4096/3)=1365 tokens, plus the fixed thinking reserve.
    try std.testing.expectEqual(@as(u32, 4000 + 1365), answerMaxTokens(4096));
    try std.testing.expectEqual(@as(u32, 4000 + 0), answerMaxTokens(0));
}
