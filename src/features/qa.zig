const std = @import("std");
const llm = @import("../llm/provider.zig");
const toolcall = @import("../llm/toolcall.zig");
const registry = @import("../tools/registry.zig");
const PgPool = @import("../store/pool.zig").PgPool;
const messages = @import("../store/messages.zig");

/// Used when the operator hasn't provided their own prompt via
/// WARDEN_SYSTEM_PROMPT / WARDEN_SYSTEM_PROMPT_FILE.
pub const default_system_prompt =
    \\You are Warden, an assistant participating in a group chat. You only
    \\see the messages people direct at you (plus the recent history given
    \\below), so treat each request as coming from a real person mid-
    \\conversation.
    \\
    \\Style: reply like a chat participant — short, direct, no headers or
    \\bullet-point essays unless genuinely needed. Match the language the
    \\user wrote in.
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
    \\gave into that tool's required duration shorthand yourself — and
    \\converting a photo/document/voice/audio/video the user just sent to a
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
    \\Tool restraint: only call a tool when the question actually needs its
    \\specific data (a real city's weather, an actual exchange rate, and so
    \\on). Don't reach for one out of habit or because it's in the list
    \\above. Questions about yourself — your name, what model or LLM you
    \\are, your capabilities — are answered directly from this prompt, never
    \\with a tool: your name is Warden, full stop, regardless of the account
    \\handle or display name this platform shows for you.
;

const history_window = 200;

/// Grounded free-form Q&A: pulls recent local chat history (not model
/// memory) as context, then runs the tool-calling loop so the model can
/// also reach for weather/currency/calculator/web_search/fetch_url as
/// needed. `replied_to` carries the text of the (bot's) message the user
/// replied to, so follow-ups keep their referent even if it has scrolled
/// out of the history window.
pub fn answer(
    provider: llm.Provider,
    allocator: std.mem.Allocator,
    ctx: registry.ToolContext,
    tool_defs: []const registry.ToolDef,
    pool: *PgPool,
    chat_id: i64,
    system_prompt: ?[]const u8,
    max_answer_len: usize,
    question: []const u8,
    replied_to: ?[]const u8,
    progress: toolcall.Progress,
) ![]const u8 {
    const history = try messages.recentFormatted(pool, allocator, chat_id, history_window);

    const user_content = if (replied_to) |earlier|
        try std.fmt.allocPrint(
            allocator,
            "Recent chat history:\n{s}\n\nThe user is replying to this earlier message of yours:\n\"{s}\"\n\nTheir reply: {s}",
            .{ history, earlier, question },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Recent chat history:\n{s}\n\nQuestion: {s}",
            .{ history, question },
        );

    // A hard file-fallback exists for whatever slips through (see
    // `main.zig`'s `sendTextOrFile`), but steering the model to stay under
    // budget up front means that rarely has to fire — most answers should
    // just read as normal chat messages, not surprise file attachments.
    const system_with_budget = try std.fmt.allocPrint(
        allocator,
        "{s}\n\nLength budget: keep replies under {d} characters when at all possible — that's the active platform's message-size limit. If the answer genuinely needs to be longer (e.g. the user asked for something long-form), that's fine: anything over the limit is sent as a file attachment automatically, so don't refuse or truncate awkwardly instead of finishing your answer.",
        .{ system_prompt orelse default_system_prompt, max_answer_len },
    );

    return toolcall.run(provider, allocator, ctx, system_with_budget, user_content, tool_defs, progress);
}
