const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const http_util = @import("../http_util.zig");
const log = @import("../log.zig").scoped("llm");

const EmbeddingObject = struct {
    embedding: []f32 = &.{},
};

const ApiError = struct {
    message: []const u8 = "",
    type: []const u8 = "",
};

const EmbeddingsResponse = struct {
    data: []EmbeddingObject = &.{},
    @"error": ?ApiError = null,
};

/// The output dimension every `memories.embedding` column is fixed to —
/// see `store/migrations/0025_memories.sql`. `embed`'s caller (the
/// `MemoryToolAdapter`/`qa.zig`'s retrieval step) doesn't validate this
/// itself; a mismatched model just surfaces as a Postgres error on
/// insert/search, not a client-side check here.
pub const embedding_dimensions = 1536;

/// Small, separate `POST {base_url}/embeddings` client for an
/// OpenAI-compatible embeddings backend — kept apart from
/// `OpenAiCompatProvider` (chat/`OpenAiCompatProvider`'s
/// `/chat/completions` wire shape) since embeddings hit a different
/// endpoint with a different request/response shape entirely; nothing
/// there was reusable beyond the base_url/api_key/model fields and the
/// Bearer-header pattern, both duplicated here rather than shared through
/// an awkward common base.
pub const EmbeddingsClient = struct {
    http_client: http.Client,
    /// e.g. "https://api.openai.com/v1" — no trailing slash (see
    /// `config.zig`'s `embeddings_url` doc comment).
    base_url: []const u8,
    /// Empty string means no Authorization header is sent.
    api_key: []const u8,
    model: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, base_url: []const u8, api_key: []const u8, model: []const u8) EmbeddingsClient {
        return .{
            .http_client = .{ .allocator = allocator, .io = io },
            .base_url = base_url,
            .api_key = api_key,
            .model = model,
        };
    }

    pub fn deinit(self: *EmbeddingsClient) void {
        self.http_client.deinit();
    }

    /// Same buffer-ownership shape as `OpenAiCompatProvider.buildHeaders`
    /// — an earlier version of that returned a slice into a callee-local
    /// buffer and segfaulted on first use, see its own doc comment for why
    /// both output buffers must be caller-owned.
    fn buildHeaders(self: *const EmbeddingsClient, auth_header_buf: []u8, headers_buf: *[1]http.Header) ![]const http.Header {
        if (self.api_key.len == 0) return &.{};
        const value = try std.fmt.bufPrint(auth_header_buf, "Bearer {s}", .{self.api_key});
        headers_buf[0] = .{ .name = "Authorization", .value = value };
        return headers_buf[0..1];
    }

    /// Embeds `text`, returning a `[]f32` of length `embedding_dimensions`
    /// on success (allocated in `allocator`). Errors (network failure, a
    /// non-2xx response, an unparseable body) propagate straight to the
    /// caller — `MemoryToolAdapter`/`qa.zig`'s retrieval step decide how to
    /// degrade, not this client.
    pub fn embed(self: *EmbeddingsClient, allocator: std.mem.Allocator, text: []const u8) ![]f32 {
        var payload_writer: Io.Writer.Allocating = .init(allocator);
        defer payload_writer.deinit();
        const w = &payload_writer.writer;
        try w.writeAll("{\"model\":");
        try json.Stringify.value(self.model, .{}, w);
        try w.writeAll(",\"input\":");
        try json.Stringify.value(text, .{}, w);
        try w.writeByte('}');

        const url = try std.fmt.allocPrint(allocator, "{s}/embeddings", .{self.base_url});
        defer allocator.free(url);

        var auth_header_buf: [8 + 255]u8 = undefined;
        var headers_buf: [1]http.Header = undefined;
        const headers = try self.buildHeaders(&auth_header_buf, &headers_buf);

        const body = try http_util.postJson(&self.http_client, allocator, url, headers, w.buffered());
        defer allocator.free(body);

        const parsed = json.parseFromSlice(
            EmbeddingsResponse,
            allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |err| {
            log.err("embeddings: response unparseable ({t}): {s}", .{ err, body[0..@min(body.len, 400)] });
            return err;
        };

        if (parsed.value.@"error") |err| {
            log.err("embeddings: api error: {s}: {s}", .{ err.type, err.message });
            return error.EmbeddingsApiError;
        }
        if (parsed.value.data.len == 0) return error.EmbeddingsEmptyResponse;
        return parsed.value.data[0].embedding;
    }
};

/// Formats a vector as pgvector's text input literal (`[0.1,0.2,...]`) —
/// `db.zig` only supports text-format parameter binding (no binary/array
/// param support), so this is how `store/memories.zig` binds an
/// `embedding` column value via `stmt.bindText`.
pub fn formatVectorLiteral(allocator: std.mem.Allocator, vec: []const f32) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeByte('[');
    for (vec, 0..) |v, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{v});
    }
    try w.writeByte(']');
    // `w.buffered()` is a sub-slice into `out`'s own (possibly larger,
    // grown-by-doubling) internal buffer, not itself a freeable
    // allocation -- duping it here, before `deinit()` frees that internal
    // buffer, is what makes the returned slice safe for a caller to
    // `allocator.free()` later. Same convention `anthropic.zig`'s
    // `buildPayload` already uses for exactly this reason.
    return allocator.dupe(u8, w.buffered());
}

const testing = std.testing;

test "formatVectorLiteral produces a pgvector-style bracketed literal" {
    const out = try formatVectorLiteral(testing.allocator, &.{ 0.1, 0.2, -0.5 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[0.1,0.2,-0.5]", out);
}

test "formatVectorLiteral handles an empty vector" {
    const out = try formatVectorLiteral(testing.allocator, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[]", out);
}
