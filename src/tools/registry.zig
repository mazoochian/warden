const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");
const delegates_mod = @import("../llm/delegates.zig");

/// Scraper mode/endpoint for `scrape_site`.
pub const ScraperMode = enum { local, remote };

pub const ScraperConfig = struct {
    mode: ScraperMode = .local,
    remote_url: ?[]const u8 = null,
    remote_api_key: ?[]const u8 = null,
};

/// Most tools are pure request/response (fetch some data, return text to feed
/// back to the model).
pub const ReminderSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const CancelResult = enum { canceled, not_found, not_authorized };

    pub const VTable = struct {
        /// `recur_interval_seconds` set makes this a recurring reminder —
        /// see the `0003_reminders_recurrence.sql` migration comment.
        create: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) anyerror!i64,
        cancel: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!CancelResult,
        /// Returns pending reminders for this chat, already formatted as a human-
        /// readable list (empty-case text included).
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

pub const AlertSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const CancelResult = enum { canceled, not_found, not_authorized };

    pub const VTable = struct {
        create: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, kind: []const u8, subject: []const u8, currency: ?[]const u8, condition: []const u8, threshold: f64) anyerror!i64,
        cancel: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!CancelResult,
        /// Same "sink formats its own listing" reasoning as
        /// `ReminderSink.VTable.listPending`.
        listPending: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
    };

    pub fn create(self: AlertSink, allocator: std.mem.Allocator, kind: []const u8, subject: []const u8, currency: ?[]const u8, condition: []const u8, threshold: f64) !i64 {
        return self.vtable.create(self.ptr, allocator, kind, subject, currency, condition, threshold);
    }

    pub fn cancel(self: AlertSink, allocator: std.mem.Allocator, id: i64) !CancelResult {
        return self.vtable.cancel(self.ptr, allocator, id);
    }

    pub fn listPending(self: AlertSink, allocator: std.mem.Allocator) ![]const u8 {
        return self.vtable.listPending(self.ptr, allocator);
    }
};

/// Same ptr+vtable shape as `ReminderSink`/`AlertSink`, for the `set_note`
/// tool.
pub const NoteSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const DeleteResult = enum { deleted, not_found, not_authorized };

    pub const VTable = struct {
        create: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!i64,
        delete: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!DeleteResult,
        /// Same "sink formats its own listing" reasoning as
        /// `ReminderSink.VTable.listPending`.
        listAll: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
    };

    pub fn create(self: NoteSink, allocator: std.mem.Allocator, text: []const u8) !i64 {
        return self.vtable.create(self.ptr, allocator, text);
    }

    pub fn delete(self: NoteSink, allocator: std.mem.Allocator, id: i64) !DeleteResult {
        return self.vtable.delete(self.ptr, allocator, id);
    }

    pub fn listAll(self: NoteSink, allocator: std.mem.Allocator) ![]const u8 {
        return self.vtable.listAll(self.ptr, allocator);
    }
};

/// Same ptr+vtable shape as `NoteSink`, for the `set_expense` tool
///.
pub const max_expense_cents: i64 = 100_000_000_000_000;

pub const ExpenseSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const DeleteResult = enum { deleted, not_found, not_authorized };

    pub const VTable = struct {
        create: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, amount_cents: i64, category: []const u8, description: ?[]const u8) anyerror!i64,
        delete: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!DeleteResult,
        /// Same "sink formats its own listing" reasoning as
        /// `ReminderSink.VTable.listPending`.
        listAll: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
    };

    pub fn create(self: ExpenseSink, allocator: std.mem.Allocator, amount_cents: i64, category: []const u8, description: ?[]const u8) !i64 {
        return self.vtable.create(self.ptr, allocator, amount_cents, category, description);
    }

    pub fn delete(self: ExpenseSink, allocator: std.mem.Allocator, id: i64) !DeleteResult {
        return self.vtable.delete(self.ptr, allocator, id);
    }

    pub fn listAll(self: ExpenseSink, allocator: std.mem.Allocator) ![]const u8 {
        return self.vtable.listAll(self.ptr, allocator);
    }
};

pub const MemorySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ForgetResult = enum { forgotten, not_found, not_authorized };

    pub const VTable = struct {
        /// May itself make an embeddings API call before persisting — see
        /// `main.zig`'s `MemoryToolAdapter`, the actual implementation behind this
        /// vtable slot.
        create: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!i64,
        forget: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!ForgetResult,
        /// Same "sink formats its own listing" reasoning as
        /// `ReminderSink.VTable.listPending`.
        listAll: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
    };

    pub fn create(self: MemorySink, allocator: std.mem.Allocator, text: []const u8) !i64 {
        return self.vtable.create(self.ptr, allocator, text);
    }

    pub fn forget(self: MemorySink, allocator: std.mem.Allocator, id: i64) !ForgetResult {
        return self.vtable.forget(self.ptr, allocator, id);
    }

    pub fn listAll(self: MemorySink, allocator: std.mem.Allocator) ![]const u8 {
        return self.vtable.listAll(self.ptr, allocator);
    }
};

/// Callback surface the `begin_file_conversion` tool uses to kick off the
/// interactive multi-stage `/convert` flow.
pub const ConvertFlowSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginAwaitingFile: *const fn (ptr: *anyopaque) anyerror!void,
    };

    pub fn beginAwaitingFile(self: ConvertFlowSink) !void {
        return self.vtable.beginAwaitingFile(self.ptr);
    }
};

/// One match `find_chat_member` can hand back to the model.
pub const MemberMatch = struct {
    display_name: []const u8,
    username: ?[]const u8 = null,
    /// Platform-native user id (Telegram: decimal string) — mirrors
    /// `iface.Message.user_id`'s "never parsed to a native int in shared code"
    /// reasoning.
    native_id: []const u8,
};

/// Callback surface the `find_chat_member` tool uses to fuzzy-search this
/// chat's known participants.
pub const MemberDirectorySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        find: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8) anyerror![]MemberMatch,
    };

    pub fn find(self: MemberDirectorySink, allocator: std.mem.Allocator, query: []const u8) ![]MemberMatch {
        return self.vtable.find(self.ptr, allocator, query);
    }
};

/// Callback surface the `catch_me_up` tool uses to pull this chat's own
/// logged history windowed by time rather than the fixed row count `qa.zig`'s
/// own conversational context uses — same ptr+vtable boundary as
/// `ReminderSink`: `registry.zig` must never depend on the store layer.
pub const ChatHistorySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Already formatted as "who: text" lines, oldest-first, empty string when
        /// nothing falls in the window.
        recentSince: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, hours_ago: i64) anyerror![]const u8,
    };

    pub fn recentSince(self: ChatHistorySink, allocator: std.mem.Allocator, hours_ago: i64) ![]const u8 {
        return self.vtable.recentSince(self.ptr, allocator, hours_ago);
    }
};

/// Backs the personal-account (TDLib) family of LLM tools.
pub const PersonalAccountSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Resolves `chat_query` (a TDLib chat id, or a title substring) and returns
        /// text ready to hand back to the model as the tool result.
        summarizeUnread: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, all: bool) anyerror![]const u8,
        /// Lists known chats, optionally narrowed by a title substring (`null`/empty
        /// means "every chat") — backs `list_personal_chats`.
        listChats: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, query: ?[]const u8) anyerror![]const u8,
        /// Resolves `chat_query` and sends `message` through it — backs
        /// `send_personal_message`.
        sendMessage: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, message: []const u8) anyerror![]const u8,
        /// Resolves `chat_query` and sends `message` as a threaded reply to
        /// `native_message_id` — backs `reply_to_message`.
        sendReply: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, native_message_id: []const u8, message: []const u8) anyerror![]const u8,
    };

    pub fn summarizeUnread(self: PersonalAccountSink, allocator: std.mem.Allocator, chat_query: []const u8, all: bool) ![]const u8 {
        return self.vtable.summarizeUnread(self.ptr, allocator, chat_query, all);
    }

    pub fn listChats(self: PersonalAccountSink, allocator: std.mem.Allocator, query: ?[]const u8) ![]const u8 {
        return self.vtable.listChats(self.ptr, allocator, query);
    }

    pub fn sendMessage(self: PersonalAccountSink, allocator: std.mem.Allocator, chat_query: []const u8, message: []const u8) ![]const u8 {
        return self.vtable.sendMessage(self.ptr, allocator, chat_query, message);
    }

    pub fn sendReply(self: PersonalAccountSink, allocator: std.mem.Allocator, chat_query: []const u8, native_message_id: []const u8, message: []const u8) ![]const u8 {
        return self.vtable.sendReply(self.ptr, allocator, chat_query, native_message_id, message);
    }
};

/// Callback surface the `set_chat_monitoring` tool uses to set (or clear) a
/// personal-account chat's owner-declared monitoring/importance state.
pub const MonitoringSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Resolves `chat_query` (a TDLib chat id, or a title substring) and sets its
        /// monitoring state.
        setImportance: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, importance: []const u8) anyerror![]const u8,
        /// Sets the owner's global monitoring default, applied to every chat with no
        /// override of its own -- backs `set_default_chat_monitoring`.
        setDefaultImportance: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, importance: []const u8) anyerror![]const u8,
    };

    pub fn setImportance(self: MonitoringSink, allocator: std.mem.Allocator, chat_query: []const u8, importance: []const u8) ![]const u8 {
        return self.vtable.setImportance(self.ptr, allocator, chat_query, importance);
    }

    pub fn setDefaultImportance(self: MonitoringSink, allocator: std.mem.Allocator, importance: []const u8) ![]const u8 {
        return self.vtable.setDefaultImportance(self.ptr, allocator, importance);
    }
};

/// Callback surface the `get_bulletin` tool uses to gather raw, id-tagged
/// message text across every monitored personal-account chat.
pub const BulletinSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `hours = null` uses the owner's last-bulletin cursor (or 24h if never run)
        /// and advances that cursor as a side effect; an explicit `hours` is a
        /// stateless ad-hoc probe that never touches the cursor.
        generate: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, hours: ?i64) anyerror![]const u8,
    };

    pub fn generate(self: BulletinSink, allocator: std.mem.Allocator, hours: ?i64) ![]const u8 {
        return self.vtable.generate(self.ptr, allocator, hours);
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
    /// Set for a real inbound message; null for contexts that never run tools
    /// needing reminder persistence.
    reminders: ?ReminderSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `set_alert` tool.
    alerts: ?AlertSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `begin_file_conversion` tool.
    convert_flow: ?ConvertFlowSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `find_chat_member` tool.
    member_directory: ?MemberDirectorySink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `set_note` tool.
    notes: ?NoteSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `remember_memory` tool.
    memory: ?MemorySink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `catch_me_up` tool.
    chat_history: ?ChatHistorySink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `set_expense` tool.
    expenses: ?ExpenseSink = null,
    personal_account: ?PersonalAccountSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `set_chat_monitoring` tool.
    monitoring: ?MonitoringSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `get_bulletin` tool.
    bulletin: ?BulletinSink = null,
    /// Local filesystem path to this message's downloaded attachment (see
    /// `iface.Attachment`), when it has one and `main.zig` successfully
    /// downloaded it.
    attachment_path: ?[]const u8 = null,
    /// Original filename Telegram (or whichever platform) reported for the
    /// attachment, if any.
    attachment_file_name: ?[]const u8 = null,
    attachment_mime: ?[]const u8 = null,
    /// `iface.Attachment.kind` for this message's attachment, if any — see
    /// `llm/attachment_content.zig`'s `imageBlockForAttachment`.
    attachment_kind: ?iface.AttachmentKind = null,
    /// Every configured "ask another model" target for the `ask_delegate`/
    /// `delegate_generate_image` tools.
    delegates: []const delegates_mod.Delegate = &.{},
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
