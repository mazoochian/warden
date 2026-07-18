const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");

/// Scraper mode/endpoint for `scrape_site`. Defined here (rather than in
/// `store/bot_config.zig`) so `registry.zig` — imported by every tool — has
/// no dependency on the store layer; `bot_config.zig` produces values of
/// this shape instead.
pub const ScraperMode = enum { local, remote };

pub const ScraperConfig = struct {
    mode: ScraperMode = .local,
    remote_url: ?[]const u8 = null,
    remote_api_key: ?[]const u8 = null,
};

/// Most tools are pure request/response (fetch some data, return text to
/// feed back to the model). A few — like rendering and sending a diagram —
/// have a side effect (sending a photo to the chat), so the
/// connector/chat_id/scratch dir are available too. Optional (rather than
/// required) so simple tools and their tests can keep constructing a
/// `ToolContext` with just `allocator`/`io`.
/// Callback surface the `set_reminder` tool uses to persist/query/cancel
/// reminders — same ptr+vtable shape as `Connector`/`llm.Provider`, so this
/// file (imported by every tool) still never depends on the store layer
/// directly (see `ScraperConfig`'s doc comment above for why that boundary
/// matters); `main.zig` wires the real Postgres-backed implementation in,
/// scoped to the sending chat/identity for a given message.
pub const ReminderSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const CancelResult = enum { canceled, not_found, not_authorized };

    pub const VTable = struct {
        /// `recur_interval_seconds` set makes this a recurring reminder —
        /// see the `0003_reminders_recurrence.sql` migration comment.
        create: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) anyerror!i64,
        cancel: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!CancelResult,
        /// Returns pending reminders for this chat, already formatted as a
        /// human-readable list (empty-case text included) — formatting
        /// needs `now` and per-row lookups the tool itself has no access
        /// to, so it's simplest for the sink to own it end to end.
        listPending: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
    };

    pub fn create(self: ReminderSink, allocator: std.mem.Allocator, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) !i64 {
        return self.vtable.create(self.ptr, allocator, message, due_at, recur_interval_seconds);
    }

    pub fn cancel(self: ReminderSink, allocator: std.mem.Allocator, id: i64) !CancelResult {
        return self.vtable.cancel(self.ptr, allocator, id);
    }

    pub fn listPending(self: ReminderSink, allocator: std.mem.Allocator) ![]const u8 {
        return self.vtable.listPending(self.ptr, allocator);
    }
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: Io,
    connector: ?iface.Connector = null,
    chat_id: ?[]const u8 = null,
    /// Scratch directory for tools that shell out to an external renderer.
    tmp_dir: ?[]const u8 = null,
    /// Base URL of a SearXNG instance for `web_search`; null when web
    /// search isn't configured.
    searxng_url: ?[]const u8 = null,
    /// Owner-configurable mode/endpoint for `scrape_site`; defaults to
    /// on-device extraction with no remote endpoint configured.
    scraper: ScraperConfig = .{},
    /// Current time (unix seconds) — `set_reminder` needs this to turn a
    /// relative duration into an absolute `due_at`.
    now: i64 = 0,
    /// Set for a real inbound message; null for contexts that never run
    /// tools needing reminder persistence (e.g. digest generation, which
    /// always passes an empty tool list anyway).
    reminders: ?ReminderSink = null,
    /// Local filesystem path to this message's downloaded attachment (see
    /// `iface.Attachment`), when it has one and `main.zig` successfully
    /// downloaded it — the file `convert_file` operates on. Null when the
    /// message had no attachment, or the download failed.
    attachment_path: ?[]const u8 = null,
    /// Original filename Telegram (or whichever platform) reported for the
    /// attachment, if any — carries the source extension `convert_file`
    /// needs when `attachment_mime` alone doesn't disambiguate.
    attachment_file_name: ?[]const u8 = null,
    attachment_mime: ?[]const u8 = null,
};

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON Schema object text describing the tool's input.
    input_schema_json: []const u8,
    execute: *const fn (ctx: ToolContext, input_json: []const u8) anyerror![]const u8,
};

pub fn find(defs: []const ToolDef, name: []const u8) ?ToolDef {
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}
