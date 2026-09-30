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
    \\Knowledge: you are not limited to the chat. The exact tools you can
    \\call right now are listed at the end of this prompt, under "Your
    \\tools" — that list is generated from what's actually enabled for
    \\this chat, so it is the authority on what you can and can't do; when
    \\someone asks what you're capable of, answer from it. A few tools need
    \\care: for reminders (set_reminder), translate whatever natural-
    \\language time the user gave into that tool's required duration
    \\shorthand yourself, except for a named weekday ("this Friday", "on
    \\Monday"): pass the day name straight through (see the tool's own
    \\description) rather than computing a day offset yourself, since you
    \\don't reliably know what day of the week today is — the current
    \\date/time given below the question does, and the tool resolves the
    \\weekday server-side from it. Converting a photo/document/voice/audio/
    \\video the user just sent to a different format is convert_file;
    \\begin_file_conversion starts the flow when they want to convert
    \\something but haven't attached a file to this message yet — it just
    \\asks them to send the file, so don't use it if one's already attached
    \\here. For anything factual you don't confidently know (current
    \\events, prices, releases, docs), use web_search rather than guessing
    \\or claiming you can't know; fetch a promising result with fetch_url
    \\when the snippet isn't enough. Say plainly when you couldn't find an
    \\answer.
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
    \\capabilities — are answered directly from this prompt (and the tool
    \\list at its end), never with a tool: your name is Warden, full stop,
    \\regardless of the account handle or display name this platform shows
    \\for you.
    \\
    \\After tools: once a tool has run, always finish with a visible reply
    \\— the user never sees tool calls or your reasoning, only your text.
    \\Lines tagged "[used: ...]" in the chat history are your own earlier
    \\tool calls and what they returned, so you can tell what you actually
    \\did (and didn't do) on previous turns.
;

/// Longest slice of a tool's description that makes it into the generated
/// "Your tools" list.
const tool_list_desc_max = 140;

/// Renders `tool_defs` as a compact "Your tools" section for the system
/// prompt: one line per enabled tool, name plus the head of its description.
pub fn renderToolList(allocator: std.mem.Allocator, tool_defs: []const registry.ToolDef) ![]const u8 {
    if (tool_defs.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "\n\nYour tools (everything you can call in this chat right now):\n");
    for (tool_defs) |d| {
        try buf.appendSlice(allocator, "- ");
        try buf.appendSlice(allocator, d.name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, descriptionHead(d.description));
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

/// The first sentence of a tool description, capped at
/// `tool_list_desc_max` bytes on a UTF-8 boundary.
fn descriptionHead(description: []const u8) []const u8 {
    var end = description.len;
    if (std.mem.indexOf(u8, description, ". ")) |dot| end = dot + 1;
    if (end > tool_list_desc_max) {
        end = tool_list_desc_max;
        while (end > 0 and (description[end] & 0xC0) == 0x80) end -= 1;
    }
    return std.mem.trimEnd(u8, description[0..end], " ");
}

const thinking_token_reserve = toolcall.thinking_token_reserve;

/// Deliberately conservative (fewer characters per token than most real-world
/// English text averages) so the *answer* portion of the budget is never the
/// actual bottleneck for a less token-efficient script/ language.
const min_chars_per_token: usize = 3;

/// `max_tokens` for a request whose visible answer is capped at
/// `max_answer_len` characters.
fn answerMaxTokens(max_answer_len: usize) u32 {
    const capped_chars = @min(max_answer_len, std.math.maxInt(u32) * min_chars_per_token);
    const answer_tokens: u32 = @intCast(capped_chars / min_chars_per_token);
    return thinking_token_reserve +| answer_tokens;
}

/// Only worth the extra round trip once the assembled prompt is already
/// large enough that a char/token heuristic's error margin could matter --
/// most turns are far under this and skip calibration entirely.
const token_calibration_char_threshold: usize = 20_000;

/// Best-effort, non-blocking cross-check of `context_assembly.zig`'s
/// char-based budgets against a real input-token count -- there's no actual
/// tokenizer anywhere else in this codebase, so this is the only place drift
/// between "chars we budgeted" and "tokens the model actually sees" would
/// ever surface. Never alters or delays the real request:
/// `Provider.countTokens` returns `null` for any provider that doesn't
/// implement it (only Anthropic's Messages API does today), and any error
/// is swallowed.
fn calibrateTokenBudget(provider: llm.Provider, allocator: std.mem.Allocator, system_prompt_text: []const u8, user_content: []const u8) void {
    const heuristic_chars = system_prompt_text.len + user_content.len;
    if (heuristic_chars < token_calibration_char_threshold) return;

    const request: llm.ChatRequest = .{
        .system = system_prompt_text,
        .messages = &.{.{ .role = .user, .content = &.{.{ .text = user_content }} }},
    };
    const real_tokens = (provider.countTokens(allocator, request) catch |err| {
        std.log.debug("qa: token calibration unavailable: {t}", .{err});
        return;
    }) orelse return;

    // `min_chars_per_token` is deliberately conservative (fewer chars per
    // token than typical English), so it should normally over-estimate --
    // only a *higher* real count than that estimate is the actual risk (a
    // request landing closer to the model's context ceiling than budgeted).
    const heuristic_tokens = heuristic_chars / min_chars_per_token;
    if (real_tokens > heuristic_tokens) {
        std.log.warn("qa: real input tokens ({d}) exceeded the char-based estimate ({d} tokens from {d} chars) -- context budgets may need retuning", .{ real_tokens, heuristic_tokens, heuristic_chars });
    }
}

/// Operator-chosen reply length (`WARDEN_LLM_REPLY_LENGTH`), e.g. "1 paragraph",
/// "80 words", "300 tokens". Words and paragraphs are a prompt instruction the
/// user can override by asking for more; tokens is also a hard `max_tokens` cap.
pub const ReplyLength = struct {
    amount: u32,
    unit: Unit,

    pub const Unit = enum { tokens, words, paragraphs };

    pub const max_amount: u32 = 100_000;

    /// `null` for "off" (empty, "0", "off", "none"): no reply-length rule, the
    /// platform limit alone applies.
    pub fn parse(raw: []const u8) error{InvalidReplyLength}!?ReplyLength {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "0") or
            std.ascii.eqlIgnoreCase(trimmed, "off") or std.ascii.eqlIgnoreCase(trimmed, "none")) return null;

        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const amount_text = it.next() orelse return error.InvalidReplyLength;
        const unit_text = it.next() orelse return error.InvalidReplyLength;
        if (it.next() != null) return error.InvalidReplyLength;

        const amount = std.fmt.parseInt(u32, amount_text, 10) catch return error.InvalidReplyLength;
        if (amount == 0 or amount > max_amount) return error.InvalidReplyLength;
        const unit: Unit = if (unitIs(unit_text, "token"))
            .tokens
        else if (unitIs(unit_text, "word"))
            .words
        else if (unitIs(unit_text, "paragraph"))
            .paragraphs
        else
            return error.InvalidReplyLength;
        return .{ .amount = amount, .unit = unit };
    }

    /// Accepts the singular or plural form, case-insensitively.
    fn unitIs(text: []const u8, singular: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(text, singular)) return true;
        return text.len == singular.len + 1 and (text[text.len - 1] | 0x20) == 's' and
            std.ascii.eqlIgnoreCase(text[0..singular.len], singular);
    }

    /// The prompt sentence describing this limit to the model.
    fn instruction(self: ReplyLength, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.unit) {
            .tokens => std.fmt.allocPrint(
                allocator,
                "keep every reply within about {d} tokens (roughly {d} words). This is a hard cap — output past it is cut off — so finish well inside it rather than starting something long.",
                .{ self.amount, self.amount * 3 / 4 },
            ),
            .words => std.fmt.allocPrint(
                allocator,
                "keep replies to at most about {d} words. Only go longer when the user explicitly asks for detail, a list or something long-form, or the task inherently needs it (translating or rewriting a text they gave you).",
                .{self.amount},
            ),
            .paragraphs => std.fmt.allocPrint(
                allocator,
                "keep replies to at most {d} short paragraph{s}. Only go longer when the user explicitly asks for detail, a list or something long-form, or the task inherently needs it (translating or rewriting a text they gave you).",
                .{ self.amount, if (self.amount == 1) "" else "s" },
            ),
        };
    }
};

/// The two knobs that bound an answer's length.
pub const LengthLimits = struct {
    /// `WARDEN_LLM_MAX_TOKENS`: a flat `max_tokens` ceiling.
    max_tokens_override: ?u32 = null,
    reply_length: ?ReplyLength = null,
};

/// `max_tokens` for one request: the tighter of the flat override and a
/// token-unit reply length, else the platform-derived budget.
fn effectiveMaxTokens(limits: LengthLimits, max_answer_len: usize) u32 {
    var cap: ?u32 = limits.max_tokens_override;
    if (limits.reply_length) |rl| if (rl.unit == .tokens) {
        cap = if (cap) |c| @min(c, rl.amount) else rl.amount;
    };
    return cap orelse answerMaxTokens(max_answer_len);
}

/// The "Length budget" paragraph appended to the system prompt. The platform
/// limit is stated as a ceiling only: phrased as a target ("keep replies under
/// 4096 characters") models read it as licence to write several paragraphs.
fn lengthBudgetLine(allocator: std.mem.Allocator, limits: LengthLimits, max_answer_len: usize) ![]const u8 {
    const target = if (limits.reply_length) |rl|
        try rl.instruction(allocator)
    else
        "follow the Style guidance above — short and direct unless the user asks for more.";

    const ceiling_chars = if (limits.max_tokens_override) |t|
        @min(max_answer_len, @as(usize, t) * min_chars_per_token)
    else
        max_answer_len;

    return std.fmt.allocPrint(
        allocator,
        "Length budget: {s} Separately, this platform can't send a single message over {d} characters; that is a technical ceiling, not a length to aim for. If an answer genuinely has to exceed it, it's sent as a file automatically, so finish your answer rather than truncating it awkwardly.",
        .{ target, ceiling_chars },
    );
}

/// Identifies who's actually sending *this* turn's question — deliberately
/// separate from the "who: text" tags in `recentFormatted`'s history.
pub const Asker = struct {
    display_name: []const u8,
    username: ?[]const u8 = null,
    /// Platform-native user id (Telegram: decimal string).
    native_id: []const u8,
};

/// Grounded free-form Q&A: pulls recent local chat history (not model memory)
/// as context.
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
    length_limits: LengthLimits,
    history_window: i64,
    /// Retries per model call on a transient failure — see
    /// `toolcall.callProviderWithRetry`.
    max_retries: u32,
) !toolcall.RunResult {
    // Layer phase: pinned/ranked facts, ranked/recent daily digests, and recent
    // chat history, all budget-capped in code.
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

    const effective_max_tokens = effectiveMaxTokens(length_limits, max_answer_len);

    const system_with_budget = try std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}{s}",
        .{ system_prompt orelse default_system_prompt, try lengthBudgetLine(allocator, length_limits, max_answer_len), try renderToolList(allocator, tool_defs) },
    );

    calibrateTokenBudget(provider, allocator, system_with_budget, user_content);

    return toolcall.runDetailed(provider, allocator, ctx, system_with_budget, user_content, tool_defs, progress, stream, show_thinking, vision_enabled, documents_enabled, effective_max_tokens, max_retries);
}

test "answerMaxTokens reserves a thinking budget on top of the answer's own character-derived budget" {
    // Telegram's 4096-byte cap, at the conservative 3 chars/token estimate,
    // is (4096/3)=1365 tokens, plus the fixed thinking reserve.
    try std.testing.expectEqual(@as(u32, 4000 + 1365), answerMaxTokens(4096));
    try std.testing.expectEqual(@as(u32, 4000 + 0), answerMaxTokens(0));
}

test "calibrateTokenBudget skips the provider call entirely under the char threshold" {
    const PoisonProvider = struct {
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat, .countTokens = countTokens };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = allocator;
            _ = request;
            return error.ShouldNotBeCalled;
        }
        fn countTokens(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!u32 {
            _ = ptr;
            _ = allocator;
            _ = request;
            return error.ShouldNotBeCalled;
        }
    };
    var poison = PoisonProvider{};
    calibrateTokenBudget(poison.provider(), std.testing.allocator, "short system", "short question");
}

test "calibrateTokenBudget calls the provider once the prompt is over threshold, and tolerates no countTokens support" {
    const big = "x" ** (token_calibration_char_threshold + 1);
    const NoCountProvider = struct {
        fn provider(self: *@This()) llm.Provider {
            return .{ .ptr = self, .vtable = &vt };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = allocator;
            _ = request;
            return .{ .content = &.{}, .stop_reason = .end_turn };
        }
    };
    var no_count = NoCountProvider{};
    // Must not crash even though this provider has no countTokens slot.
    calibrateTokenBudget(no_count.provider(), std.testing.allocator, big, "question");
}

test "ReplyLength.parse accepts amount + unit, singular or plural, and treats off/0/empty as no limit" {
    const R = ReplyLength;
    try std.testing.expectEqual(R{ .amount = 1, .unit = .paragraphs }, (try R.parse("1 paragraph")).?);
    try std.testing.expectEqual(R{ .amount = 3, .unit = .paragraphs }, (try R.parse("  3 Paragraphs ")).?);
    try std.testing.expectEqual(R{ .amount = 80, .unit = .words }, (try R.parse("80 words")).?);
    try std.testing.expectEqual(R{ .amount = 300, .unit = .tokens }, (try R.parse("300 TOKENS")).?);
    try std.testing.expectEqual(@as(?R, null), try R.parse(""));
    try std.testing.expectEqual(@as(?R, null), try R.parse("0"));
    try std.testing.expectEqual(@as(?R, null), try R.parse("off"));
    try std.testing.expectError(error.InvalidReplyLength, R.parse("300"));
    try std.testing.expectError(error.InvalidReplyLength, R.parse("0 words"));
    try std.testing.expectError(error.InvalidReplyLength, R.parse("-5 words"));
    try std.testing.expectError(error.InvalidReplyLength, R.parse("5 sentences"));
    try std.testing.expectError(error.InvalidReplyLength, R.parse("5 words please"));
    try std.testing.expectError(error.InvalidReplyLength, R.parse("5 wordss"));
    try std.testing.expectError(error.InvalidReplyLength, R.parse("100001 tokens"));
}

test "effectiveMaxTokens: a token-unit reply length caps max_tokens; words/paragraphs keep the platform budget" {
    try std.testing.expectEqual(answerMaxTokens(4096), effectiveMaxTokens(.{}, 4096));
    try std.testing.expectEqual(answerMaxTokens(4096), effectiveMaxTokens(.{ .reply_length = .{ .amount = 2, .unit = .paragraphs } }, 4096));
    try std.testing.expectEqual(@as(u32, 300), effectiveMaxTokens(.{ .reply_length = .{ .amount = 300, .unit = .tokens } }, 4096));
    try std.testing.expectEqual(@as(u32, 200), effectiveMaxTokens(.{ .max_tokens_override = 200, .reply_length = .{ .amount = 300, .unit = .tokens } }, 4096));
    try std.testing.expectEqual(@as(u32, 250), effectiveMaxTokens(.{ .max_tokens_override = 900, .reply_length = .{ .amount = 250, .unit = .tokens } }, 4096));
}

test "lengthBudgetLine states the reply length as the target and the platform limit only as a ceiling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = try lengthBudgetLine(a, .{ .reply_length = .{ .amount = 1, .unit = .paragraphs } }, 4096);
    try std.testing.expect(std.mem.indexOf(u8, line, "at most 1 short paragraph.") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "4096 characters; that is a technical ceiling, not a length to aim for") != null);

    const words = try lengthBudgetLine(a, .{ .reply_length = .{ .amount = 80, .unit = .words } }, 4096);
    try std.testing.expect(std.mem.indexOf(u8, words, "at most about 80 words") != null);

    const unset = try lengthBudgetLine(a, .{}, 4096);
    try std.testing.expect(std.mem.indexOf(u8, unset, "follow the Style guidance") != null);
}

test "renderToolList lists each enabled tool by name with the head of its description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const defs = [_]registry.ToolDef{
        .{ .name = "weather", .description = "Gets current weather (temperature, wind) for a city name. No API key required (Open-Meteo).", .input_schema_json = "{}", .execute = undefined },
        .{ .name = "noop", .description = "Does nothing", .input_schema_json = "{}", .execute = undefined },
    };
    const out = try renderToolList(a, &defs);
    try std.testing.expect(std.mem.indexOf(u8, out, "Your tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- weather: Gets current weather (temperature, wind) for a city name.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Open-Meteo") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- noop: Does nothing\n") != null);
    try std.testing.expectEqualStrings("", try renderToolList(a, &.{}));
}

test "descriptionHead caps a long first sentence on a UTF-8 boundary" {
    const long = "é" ** 100;
    const head = descriptionHead(long);
    try std.testing.expect(head.len <= tool_list_desc_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(head));
}
