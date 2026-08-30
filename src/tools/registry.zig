const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");
const delegates_mod = @import("../llm/delegates.zig");

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

/// Same ptr+vtable shape as `ReminderSink`, for the `set_alert` tool — kept
/// as its own type (rather than folding into `ReminderSink`) since alerts
/// have a materially different shape (kind/subject/condition/threshold vs.
/// message/due_at) and no shared behavior beyond "persisted, chat-scoped,
/// cancelable thing".
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
/// tool — notes/lists (shopping lists, wishlists, packing lists, etc. are
/// all just this one generic shape, see `store/notes.zig`'s doc comment).
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
/// (ROADMAP.md's Phase 17) -- lets the model log an expense from natural
/// language ("I spent $12 on lunch") or a receipt photo it can already
/// see via Phase 10's vision support, with no separate OCR plumbing
/// needed: the model reads the amount/items off the image itself and
/// calls this like any other expense. `amount_cents` is already
/// converted from the model's dollar-amount input by the tool itself
/// (see `tools/set_expense.zig`), so this sink -- like every store-layer
/// boundary in this file -- only ever deals in the exact integer unit
/// real money is stored as.
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

/// Same ptr+vtable shape as `NoteSink`, for the `remember_memory` tool —
/// see `store/memories.zig`'s doc comment for the "explicit remember/
/// forget, per-identity, not per-chat" scope decision (ROADMAP.md's Phase
/// 12). Unlike `NoteSink.delete` there's no "or the owner" escape hatch on
/// `forget` — a memory is per-identity, never chat-visible, so there's
/// nothing for a chat's/bot's owner to moderate; only the identity that
/// owns a given memory can ever forget it (enforced by the `main.zig`
/// adapter, not this type).
pub const MemorySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ForgetResult = enum { forgotten, not_found, not_authorized };

    pub const VTable = struct {
        /// May itself make an embeddings API call before persisting — see
        /// `main.zig`'s `MemoryToolAdapter`, the actual implementation
        /// behind this vtable slot.
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
/// interactive multi-stage `/convert` flow (see `features/convert_flow.zig`)
/// when the user expresses intent in natural language rather than typing
/// bare `/convert` — same ptr+vtable boundary reasoning as `ReminderSink`/
/// `AlertSink`: `registry.zig` is imported by every tool and must never
/// depend on a specific feature module directly.
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

/// One match `find_chat_member` can hand back to the model — enough to
/// resolve a name to a real handle/id (to @-mention someone, or just refer
/// to them correctly) without exposing internal store row ids.
pub const MemberMatch = struct {
    display_name: []const u8,
    username: ?[]const u8 = null,
    /// Platform-native user id (Telegram: decimal string) — mirrors
    /// `iface.Message.user_id`'s "never parsed to a native int in shared
    /// code" reasoning.
    native_id: []const u8,
};

/// Callback surface the `find_chat_member` tool uses to fuzzy-search this
/// chat's known participants — same ptr+vtable shape as `ReminderSink`/
/// `AlertSink`, for the same "registry.zig must never depend on the store
/// layer" reason (see `ScraperConfig`'s doc comment).
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
/// logged history windowed by time rather than the fixed row count
/// `qa.zig`'s own conversational context uses — same ptr+vtable boundary
/// reasoning as `ReminderSink`/`MemberDirectorySink` (`registry.zig` must
/// never depend on the store layer directly, see `ScraperConfig`'s doc
/// comment). Read-only, so unlike `ReminderSink`/`NoteSink` there's just
/// the one method.
pub const ChatHistorySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Already formatted as "who: text" lines, oldest-first, empty
        /// string when nothing falls in the window — same "sink formats its
        /// own listing" reasoning as `ReminderSink.VTable.listPending`.
        recentSince: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, hours_ago: i64) anyerror![]const u8,
    };

    pub fn recentSince(self: ChatHistorySink, allocator: std.mem.Allocator, hours_ago: i64) ![]const u8 {
        return self.vtable.recentSince(self.ptr, allocator, hours_ago);
    }
};

/// Backs the personal-account (TDLib) family of LLM tools --
/// `summarize_unread_chat`, `list_personal_chats`, `send_personal_message`
/// -- not this Bot-API chat's own history (that's `ChatHistorySink`
/// above). One sink rather than three: all three operate on the same
/// underlying connector and share the same "not configured"/"not logged
/// in yet" preconditions, so a single adapter implementation (see
/// `main.zig`'s `PersonalAccountToolAdapter`) covers all of them. Null
/// whenever the personal-account connector isn't configured/logged in,
/// same nullability convention as every other optional sink here.
pub const PersonalAccountSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Resolves `chat_query` (a TDLib chat id, or a title substring)
        /// and returns text ready to hand back to the model as the tool
        /// result — already covers "no such chat"/"ambiguous, pick one"/
        /// "N unread: <lines>", same "sink formats its own listing"
        /// convention `ChatHistorySink`/`ReminderSink` already follow.
        /// `all = true` summarizes the last 100 messages regardless of
        /// read state instead of just unread ones (no mark-as-read side
        /// effect in that mode) — see `chat_summary.fetchRecent`.
        summarizeUnread: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, all: bool) anyerror![]const u8,
        /// Lists known chats, optionally narrowed by a title substring
        /// (`null`/empty means "every chat") — backs `list_personal_chats`.
        /// Formatted "id — title" lines, same as `/tdchats`/`/tdsearch`.
        listChats: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, query: ?[]const u8) anyerror![]const u8,
        /// Resolves `chat_query` and sends `message` through it — backs
        /// `send_personal_message`. Returns a confirmation (naming which
        /// chat it actually sent to) or, for `.none`/`.ambiguous`, the same
        /// kind of "didn't send, here's why" text `summarizeUnread`
        /// returns for its own unresolvable cases — never silently drops a
        /// message the caller thought was sent.
        sendMessage: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, message: []const u8) anyerror![]const u8,
        /// Resolves `chat_query` and sends `message` as a threaded reply to
        /// `native_message_id` — backs `reply_to_message`. Same
        /// resolution/confirmation shape as `sendMessage` above.
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

/// Callback surface the `set_chat_monitoring` tool uses to set (or clear)
/// a personal-account chat's owner-declared monitoring/importance state --
/// same ptr+vtable boundary reasoning as `ReminderSink`/`ChatHistorySink`
/// (`registry.zig` must never depend on the store layer directly, see
/// `ScraperConfig`'s doc comment). `importance` is a raw string (one of
/// "low"/"normal"/"high"/"off", matching the tool's own JSON schema enum)
/// rather than a typed enum, so this file has no need to mirror
/// `chat_settings.MonitorImportance` locally -- the real adapter
/// (`main.zig`) parses/validates it against the store layer's own enum.
pub const MonitoringSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Resolves `chat_query` (a TDLib chat id, or a title substring) and
        /// sets its monitoring state -- covers "no such chat"/"ambiguous,
        /// pick one"/confirmation the same way `PersonalAccountSink.
        /// sendMessage` already does for its own unresolvable cases.
        setImportance: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, chat_query: []const u8, importance: []const u8) anyerror![]const u8,
        /// Sets the owner's global monitoring default, applied to every
        /// chat with no override of its own -- backs
        /// `set_default_chat_monitoring`. No chat to resolve, so this is
        /// just a confirmation string, same "off" sentinel convention as
        /// `setImportance`.
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
/// message text across every monitored personal-account chat -- same
/// ptr+vtable boundary reasoning as the sinks above.
pub const BulletinSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `hours = null` uses the owner's last-bulletin cursor (or 24h if
        /// never run) and advances that cursor as a side effect; an
        /// explicit `hours` is a stateless ad-hoc probe that never touches
        /// the cursor -- see `features/bulletin.zig`'s doc comment.
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
    /// Set for a real inbound message; null for contexts that never run
    /// tools needing reminder persistence (e.g. digest generation, which
    /// always passes an empty tool list anyway).
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
    /// `remember_memory` tool — also null (regardless of a real message
    /// being processed) whenever `WARDEN_EMBEDDINGS_URL` isn't configured,
    /// see `config.zig`'s `embeddings_url` doc comment.
    memory: ?MemorySink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `catch_me_up` tool.
    chat_history: ?ChatHistorySink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `set_expense` tool.
    expenses: ?ExpenseSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `summarize_unread_chat`/`list_personal_chats`/`send_personal_message`/
    /// `reply_to_message` tools.
    personal_account: ?PersonalAccountSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `set_chat_monitoring` tool.
    monitoring: ?MonitoringSink = null,
    /// Same lifetime/nullability reasoning as `reminders` above, for the
    /// `get_bulletin` tool.
    bulletin: ?BulletinSink = null,
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
    /// `iface.Attachment.kind` for this message's attachment, if any — see
    /// `llm/attachment_content.zig`'s `imageBlockForAttachment`, which needs
    /// this specifically because a Telegram photo never reports a
    /// `mime_type` at all (see `platform/telegram.zig`'s
    /// `attachmentFromMessage`), so `kind == .photo` is the only reliable
    /// "this is an image" signal for that case.
    attachment_kind: ?iface.AttachmentKind = null,
    /// Every configured "ask another model" target for the `ask_delegate`/
    /// `delegate_generate_image` tools — see `llm/delegates.zig`'s
    /// `Delegate` doc comment and `config.zig`'s `Config.delegates`. Empty
    /// (the default) rather than those tools joining `active_tools` at all
    /// when nothing's configured — see `main.zig`'s tool-list construction.
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
