const std = @import("std");
const llm = @import("provider.zig");
const dynamic_config = @import("../store/dynamic_config.zig");
const PgPool = @import("../store/pool.zig").PgPool;

/// Wraps whichever real providers were configured at startup (see
/// `config.zig`'s `Config.llm_anthropic`/`Config.llm_openai_compat`)
/// behind one `llm.Provider` interface, re-checking `dynamic_config`'s
/// `WARDEN_LLM_PROVIDER` on every call instead of fixing the choice once
/// at process startup — see /home/armin/claude/warden-ui/ARCHITECTURE.md
/// §6 and ROADMAP.md Phase 3 ("Decided 2026-07-28 (Armin):
/// WARDEN_LLM_PROVIDER becomes hot-swappable"). Every downstream caller
/// (`qa.answer`, `toolcall.run`, etc.) keeps passing around a plain
/// `llm.Provider` value exactly as before — this wrapper absorbs the
/// hot-swap logic entirely inside its own vtable implementation, no
/// call-site changes needed anywhere else in the codebase.
pub const DynamicLlmProvider = struct {
    pool: *PgPool,
    anthropic: ?llm.Provider,
    openai_compat: ?llm.Provider,
    /// Whichever provider actually has credentials, used whenever the
    /// requested one (from `dynamic_config`, or the startup default if
    /// unset) isn't configured — so a bad/stale/never-set override can
    /// never leave the bot with no working provider at all. This is
    /// always one of `anthropic`/`openai_compat` (`Config.load` already
    /// guarantees at least one exists).
    fallback: llm.Provider,
    /// The provider `WARDEN_LLM_PROVIDER` selected at startup — the
    /// default `dynamic_config` falls back to when no DB override exists,
    /// same "missing row means default" convention as everywhere else.
    default_provider_name: []const u8,

    pub fn provider(self: *DynamicLlmProvider) llm.Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: llm.Provider.VTable = .{ .chat = chatFn, .chatStream = chatStreamFn };

    fn resolve(self: *DynamicLlmProvider, allocator: std.mem.Allocator) llm.Provider {
        const name = dynamic_config.getString(self.pool, allocator, "WARDEN_LLM_PROVIDER", self.default_provider_name) catch return self.fallback;
        defer allocator.free(name);

        if (std.mem.eql(u8, name, "openai_compat")) return self.openai_compat orelse self.fallback;
        if (std.mem.eql(u8, name, "anthropic")) return self.anthropic orelse self.fallback;
        return self.fallback;
    }

    fn chatFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
        const self: *DynamicLlmProvider = @ptrCast(@alignCast(ptr));
        return self.resolve(allocator).chat(allocator, request);
    }

    fn chatStreamFn(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest, sink: llm.StreamSink) anyerror!llm.ChatResponse {
        const self: *DynamicLlmProvider = @ptrCast(@alignCast(ptr));
        return self.resolve(allocator).chatStream(allocator, request, sink);
    }
};

const testing = std.testing;
const test_support = @import("../store/test_support.zig");
const identities = @import("../store/identities.zig");

fn testProviderTag(comptime tag: []const u8) llm.Provider {
    const S = struct {
        fn chat(ptr: *anyopaque, allocator: std.mem.Allocator, request: llm.ChatRequest) anyerror!llm.ChatResponse {
            _ = ptr;
            _ = allocator;
            _ = request;
            return .{ .content = &.{.{ .text = tag }}, .stop_reason = .end_turn };
        }
        const vt: llm.Provider.VTable = .{ .chat = chat };
    };
    return .{ .ptr = undefined, .vtable = &S.vt };
}

fn textOf(response: llm.ChatResponse) []const u8 {
    return switch (response.content[0]) {
        .text => |t| t,
        else => "",
    };
}

test "resolve picks the dynamic_config override, falls back to the startup default when unset" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    var wrapper = DynamicLlmProvider{
        .pool = &pool,
        .anthropic = testProviderTag("anthropic"),
        .openai_compat = testProviderTag("openai_compat"),
        .fallback = testProviderTag("anthropic"),
        .default_provider_name = "anthropic",
    };

    // No override yet -- uses the startup default.
    const before = try wrapper.provider().chat(a, .{ .messages = &.{} });
    try testing.expectEqualStrings("anthropic", textOf(before));

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try dynamic_config.set(&pool, "WARDEN_LLM_PROVIDER", "openai_compat", owner);

    const after = try wrapper.provider().chat(a, .{ .messages = &.{} });
    try testing.expectEqualStrings("openai_compat", textOf(after));
}

test "resolve falls back when the requested provider was never configured" {
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();
    const a = testing.allocator;

    var wrapper = DynamicLlmProvider{
        .pool = &pool,
        .anthropic = testProviderTag("anthropic"),
        .openai_compat = null, // never configured
        .fallback = testProviderTag("anthropic"),
        .default_provider_name = "anthropic",
    };

    const owner = try identities.getOrCreateMinimal(&pool, .telegram, "1", "owner", null, false, 1000);
    try dynamic_config.set(&pool, "WARDEN_LLM_PROVIDER", "openai_compat", owner);

    // Requested openai_compat, but it's null -- falls back rather than
    // crashing or leaving the bot with no working provider.
    const result = try wrapper.provider().chat(a, .{ .messages = &.{} });
    try testing.expectEqualStrings("anthropic", textOf(result));
}
