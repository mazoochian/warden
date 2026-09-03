const std = @import("std");
const Io = std.Io;
const json = std.json;

const iface = @import("interface.zig");
const Identity = @import("../domain/identity.zig").Identity;
const log = @import("../log.zig").scoped("telegram_user");

const td = @cImport({
    @cInclude("td/telegram/td_json_client.h");
});

/// How long a single `td_receive` call blocks waiting for the next update —
/// same "bounds one connector's slice of the round-robin poll loop" reasoning
/// as `xmpp.zig`'s `poll_timeout_ns`. Short, since `pollFn` also drains a
/// burst of already-buffered updates per call (see `drain_limit` below) and
/// a long per-call block would stall that.
const receive_timeout_seconds: f64 = 3.0;

/// Upper bound on how many updates one `pollFn` call drains before returning
/// — TDLib can hand back updates faster than they can be converted/returned,
/// and an unbounded drain loop would starve every other connector in
/// `main.zig`'s round-robin poll loop. Matches this codebase's existing
/// "bounded work per poll cycle" convention (see e.g. `messages.zig`'s
/// row-count ceilings).
const drain_limit: usize = 50;

/// Upper bound `waitForResponse` blocks a calling thread for a single
/// TDLib request/response round trip (`getChat`/`getChatHistory`/
/// `viewMessages`) — generous for an interactive owner command, not so
/// long a genuinely wedged connector hangs the calling thread indefinitely.
const request_timeout_seconds: f64 = 15.0;

/// TDLib's own authorization-state machine (`updateAuthorizationState`,
/// https://core.telegram.org/tdlib/getting-started#authorization) collapsed
/// to the subset this connector actually branches on. `.ready` is the only
/// state `pollFn` converts updates in; every other state means "waiting on
/// something" — either TDLib itself (`.wait_tdlib_parameters`) or a human
/// (`.wait_phone_number`/`.wait_code`/`.wait_password`, driven by
/// `submitPhoneNumber`/`submitAuthCode`/`submitPassword`).
pub const AuthState = enum {
    none,
    wait_tdlib_parameters,
    wait_phone_number,
    wait_code,
    wait_password,
    ready,
    logging_out,
    closed,
    /// Anything TDLib sent that isn't one of the above (e.g.
    /// `authorizationStateWaitOtherDeviceConfirmation` — QR-code login,
    /// deliberately unsupported since this connector only drives the
    /// phone-number flow). Login can't proceed from here; see `pollFn`'s
    /// log line for what TDLib actually sent.
    unsupported,
};

/// TDLib-backed (MTProto, via TDLib's `tdjson` C interface) implementation of
/// `platform.Connector` for the *owner's own* Telegram account — distinct
/// from `platform/telegram.zig`'s Bot API connector, see `Platform.
/// telegram_user`'s doc comment for why these are separate connectors
/// rather than one with a mode flag.
///
/// Login is inherently a one-time interactive step (phone number -> code
/// Telegram sends to the number's *existing* sessions -> 2FA password if
/// one is set) that TDLib's own state machine drives — this struct exposes
/// that as `authState()` (what's currently being waited on) plus
/// `submitPhoneNumber`/`submitAuthCode`/`submitPassword` (what to call in
/// response), so a caller (the warden-ui login form, or a bot-chat command
/// flow) can drive it without this file needing to know which surface is
/// asking. Once `authState() == .ready`, TDLib persists the session under
/// `session_dir` itself — a later process restart pointed at the same
/// directory reaches `.ready` again with no re-login.
///
/// **Phase A scope, documented rather than silently assumed**: `pollFn`
/// only converts `updateNewMessage` whose content is `messageText` (the
/// common case) into `iface.Message`; photos/documents/voice/replies/
/// group-admin actions are not yet implemented (`sendMessage` is the only
/// outbound vtable method wired up). TDLib's own chat ids are a *different*
/// numbering scheme than the Bot API's for the same real-world chat — this
/// is fine (`store/chats.zig` already keys by `(platform, native_chat_id)`,
/// so `.telegram` and `.telegram_user` rows for "the same" group never
/// collide or need reconciling), but worth knowing before assuming a chat
/// id copied from one connector means anything to the other.
/// One entry in `TelegramUserConnector.known_chats` — just enough to let an
/// owner match a human-readable title back to the native chat id `/sendas`
/// (and eventually anything else keyed on chat id) needs. `chat_id` is a
/// `[]const u8` (not `i64`) for the same reason `iface.Message.chat_id` is:
/// every other chat-id-shaped value in this codebase is a string, and
/// keeping this one consistent avoids a parse/format round trip at every
/// call site that wants to hand it straight to `sendMessage`.
pub const ChatInfo = struct {
    chat_id: []const u8,
    title: []const u8,

    fn dupe(self: ChatInfo, allocator: std.mem.Allocator) !ChatInfo {
        return .{
            .chat_id = try allocator.dupe(u8, self.chat_id),
            .title = try allocator.dupe(u8, self.title),
        };
    }
};

pub const TelegramUserConnector = struct {
    allocator: std.mem.Allocator,
    io: Io,
    api_id: i32,
    api_hash: []const u8,
    session_dir: []const u8,
    client_id: ?c_int = null,
    auth_state: AuthState = .none,
    /// Raw `@type` string of an `.unsupported` auth state, for logging —
    /// duped onto `allocator` since the JSON it came from is only valid
    /// until the next `td_receive`/`td_execute` call.
    unsupported_auth_type: ?[]const u8 = null,
    self_user_id: ?[]const u8 = null,
    self_username: ?[]const u8 = null,
    /// Chat id -> title, built up from `updateNewChat`/`updateChatTitle`
    /// updates as `pollFn` sees them (TDLib sends a burst of `updateNewChat`
    /// for every chat it knows about shortly after login, unprompted — no
    /// explicit `getChats` request needed to populate this). Exists purely
    /// so an owner can find a chat's id via `/tdchats` without needing to
    /// already know it, then pass it to `/sendas`.
    ///
    /// Guarded by `known_chats_mu` rather than only ever touched from one
    /// thread: `pollFn` (the poll-loop thread) writes to it, `knownChats`
    /// (called from a `MessageWorkerPool` command-handler thread, e.g.
    /// `/tdchats`) reads it — genuinely two different threads, unlike
    /// `client_id`/`auth_state`/etc., which only `pollFn` ever touches
    /// (unless a command handler is mid-`submitX`, but those are simple
    /// fire-and-forget `td_send` calls with no shared mutable state to
    /// race on).
    known_chats: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Same primitive/lock idiom `features/group_admin.zig`'s
    /// `PendingConfirmations` and `worker_pool.zig` already use — an
    /// `Io`-aware mutex, not `std.Thread.Mutex` (this Zig version's `Io`
    /// rewrite folded thread synchronization into `Io` itself; see
    /// `lockUncancelable`'s call sites here for why the "uncancelable"
    /// variant: this critical section is a plain in-memory map mutation/
    /// read with no cancellation point inside it, so there's nothing
    /// meaningful to cancel out of mid-lock).
    known_chats_mu: Io.Mutex = .init,
    /// Every outbound request `send()` makes is fire-and-forget — TDLib's
    /// `tdjson` stream mixes unprompted updates and request responses
    /// together with no separate channel, and `pollFn` used to just ignore
    /// anything it didn't recognize as an update (see the "silently
    /// ignored" comment at its tail). `chat_summary.zig` needs real
    /// request/response calls (`getChat`, `getChatHistory`, `viewMessages`)
    /// to fetch and mark unread messages read, so this is the minimal
    /// correlation mechanism for that: a request tags itself with an
    /// integer `@extra`, TDLib echoes that verbatim on its response, and
    /// `pollFn` (see its `@extra` branch) diverts anything carrying one
    /// into this map instead of treating it as an update. Keyed by extra
    /// id -> the whole raw JSON response text, `self.allocator`-duped
    /// (survives past the arena `pollFn`'s caller frees each cycle).
    ///
    /// Known, accepted leak: a response for a request whose waiter already
    /// gave up on timeout (`waitForResponse`) is never evicted — for an
    /// interactive, owner-only command at human request rates this is at
    /// worst a few hundred bytes sitting until the next process restart,
    /// not worth a TTL sweep for.
    pending_responses: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    pending_responses_mu: Io.Mutex = .init,
    next_extra_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn init(allocator: std.mem.Allocator, io: Io, api_id: i32, api_hash: []const u8, session_dir: []const u8) TelegramUserConnector {
        return .{
            .allocator = allocator,
            .io = io,
            .api_id = api_id,
            .api_hash = api_hash,
            .session_dir = session_dir,
        };
    }

    /// Duped copies of every currently-known (chat id, title) pair, in no
    /// particular order — caller owns the returned slice and every string
    /// in it. Safe to call from any thread (see `known_chats`'s doc
    /// comment).
    pub fn knownChats(self: *TelegramUserConnector, allocator: std.mem.Allocator) ![]ChatInfo {
        self.known_chats_mu.lockUncancelable(self.io);
        defer self.known_chats_mu.unlock(self.io);

        var out = try std.ArrayList(ChatInfo).initCapacity(allocator, self.known_chats.count());
        errdefer out.deinit(allocator);
        var it = self.known_chats.iterator();
        while (it.next()) |entry| {
            const info = try (ChatInfo{ .chat_id = entry.key_ptr.*, .title = entry.value_ptr.* }).dupe(allocator);
            out.appendAssumeCapacity(info);
        }
        return out.toOwnedSlice(allocator);
    }

    /// This chat's title from the `updateNewChat`/`updateChatTitle` cache,
    /// duped onto `allocator`, or `null` if TDLib hasn't told us about the
    /// chat yet. Cache-only by design: `convertNewMessage` calls this on the
    /// poll loop's hot path, where a blocking `getChat` round trip per
    /// inbound message would be exactly the stall `markSeenFireAndForget`
    /// goes out of its way to avoid.
    fn knownChatTitle(self: *TelegramUserConnector, allocator: std.mem.Allocator, chat_id: []const u8) ?[]const u8 {
        self.known_chats_mu.lockUncancelable(self.io);
        defer self.known_chats_mu.unlock(self.io);

        const title = self.known_chats.get(chat_id) orelse return null;
        return allocator.dupe(u8, title) catch null;
    }

    fn setKnownChatTitle(self: *TelegramUserConnector, chat_id: []const u8, title: []const u8) void {
        self.known_chats_mu.lockUncancelable(self.io);
        defer self.known_chats_mu.unlock(self.io);

        if (self.known_chats.getEntry(chat_id)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = self.allocator.dupe(u8, title) catch return;
            return;
        }
        const owned_id = self.allocator.dupe(u8, chat_id) catch return;
        const owned_title = self.allocator.dupe(u8, title) catch {
            self.allocator.free(owned_id);
            return;
        };
        self.known_chats.put(self.allocator, owned_id, owned_title) catch {
            self.allocator.free(owned_id);
            self.allocator.free(owned_title);
        };
    }

    pub fn connector(self: *TelegramUserConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .selfId = selfIdFn,
        .selfUsername = selfUsernameFn,
        // No moderation/media vtable slots yet — see the struct doc
        // comment's "Phase A scope" note. Every one of those falls back to
        // `error.Unsupported`/the plain-text fallback, same as any other
        // connector that doesn't implement an optional method.
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .telegram_user;
    }

    fn selfIdFn(ptr: *anyopaque) ?[]const u8 {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        return self.self_user_id;
    }

    fn selfUsernameFn(ptr: *anyopaque) ?[]const u8 {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        return self.self_username;
    }

    pub fn authState(self: *const TelegramUserConnector) AuthState {
        return self.auth_state;
    }

    fn ensureClient(self: *TelegramUserConnector) void {
        if (self.client_id != null) return;
        self.client_id = td.td_create_client_id();
        // Kicks the state machine — TDLib won't send its first
        // `updateAuthorizationState` (`authorizationStateWaitTdlibParameters`)
        // until something is sent to it.
        self.send(.{ .@"@type" = "getAuthorizationState" });
    }

    /// Sends a request built from an anonymous struct literal, JSON-encoded
    /// via `json.Stringify` (every field here is plain typed data — no raw-
    /// JSON splicing the way `llm/toolcall.zig`'s tool-schema handling
    /// needs, so `Stringify.value` on the struct directly is the right tool,
    /// not a hand-built writer).
    fn send(self: *TelegramUserConnector, request: anytype) void {
        var out: Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        json.Stringify.value(request, .{}, &out.writer) catch |err| {
            log.err("send: failed to encode request: {t}", .{err});
            return;
        };
        const body = out.writer.buffered();
        const body_z = self.allocator.dupeZ(u8, body) catch return;
        defer self.allocator.free(body_z);
        td.td_send(self.client_id.?, body_z.ptr);
    }

    fn nextExtraId(self: *TelegramUserConnector) u64 {
        return self.next_extra_id.fetchAdd(1, .monotonic);
    }

    fn storePendingResponse(self: *TelegramUserConnector, io: Io, extra_id: u64, raw: []const u8) void {
        const owned = self.allocator.dupe(u8, raw) catch return;
        self.pending_responses_mu.lockUncancelable(io);
        defer self.pending_responses_mu.unlock(io);
        self.pending_responses.put(self.allocator, extra_id, owned) catch self.allocator.free(owned);
    }

    /// Blocks the calling thread (never the poll-loop thread itself — a
    /// request/response round trip is always initiated from a command
    /// handler or tool-call thread, fulfilled by `pollFn`'s `@extra` branch
    /// running concurrently on its own thread) polling for `extra_id`'s
    /// response, up to `timeout_seconds`. Plain bounded `Io.sleep` polling
    /// rather than an `Io.Condition` wait — matches this codebase's own
    /// existing idiom for "wait on another thread's async result"
    /// (`main.zig`'s video-download/transcription progress tickers), and
    /// avoids needing per-request condvars for what's an infrequent,
    /// interactive-latency operation. Returns the caller-`allocator`-owned
    /// raw JSON response text, or `null` on timeout.
    fn waitForResponse(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, extra_id: u64, timeout_seconds: f64) !?[]const u8 {
        const poll_interval_ms = 50;
        const timeout_ms: usize = @intFromFloat(timeout_seconds * 1000.0);
        var waited_ms: usize = 0;
        while (waited_ms < timeout_ms) : (waited_ms += poll_interval_ms) {
            self.pending_responses_mu.lockUncancelable(io);
            const found = self.pending_responses.fetchRemove(extra_id);
            self.pending_responses_mu.unlock(io);
            if (found) |entry| {
                defer self.allocator.free(entry.value);
                return try allocator.dupe(u8, entry.value);
            }
            Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake) catch break;
        }
        return null;
    }

    /// One chat's freshly-fetched unread state — `chat_summary.zig`'s
    /// starting point for "what's unread in this chat right now" (asked of
    /// TDLib directly rather than trusted from a locally cached counter,
    /// since staleness here would mean either re-summarizing already-read
    /// messages or, worse, marking unseen ones read without ever showing
    /// them).
    pub const ChatMeta = struct {
        title: []const u8,
        unread_count: i64,
        /// The chat's newest message id, if TDLib reports one (`getChat`'s
        /// `last_message` field — absent for a brand new chat with no
        /// messages yet). Since Telegram's read state is a single
        /// forward-moving cursor per chat (see `markMessagesRead`'s doc
        /// comment), this one id is all `fetchUnread` needs to mark an
        /// entire unread backlog read -- no need to enumerate every unread
        /// message individually.
        last_message_id: ?i64,
    };

    /// `getChat` — resolves `chat_id` to its current title + unread count.
    /// `null` on timeout/parse failure/TDLib error (logged); the caller
    /// treats that the same as "couldn't reach the personal account right
    /// now".
    pub fn requestChatMeta(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64) !?ChatMeta {
        const extra_id = self.nextExtraId();
        self.send(.{ .@"@type" = "getChat", .chat_id = chat_id, .@"@extra" = extra_id });
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("requestChatMeta: getChat timed out for chat {d}", .{chat_id});
            return null;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("requestChatMeta: failed to parse getChat response: {t}", .{err});
            return null;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return null,
        };
        if (obj.get("@type")) |v| if (v == .string and std.mem.eql(u8, v.string, "error")) {
            log.warn("requestChatMeta: getChat error for chat {d}: {s}", .{ chat_id, raw });
            return null;
        };
        const title = switch (obj.get("title") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        const unread_count = switch (obj.get("unread_count") orelse return null) {
            .integer => |n| n,
            else => return null,
        };
        const last_message_id: ?i64 = if (obj.get("last_message")) |lm_v| switch (lm_v) {
            .object => |lm| switch (lm.get("id") orelse json.Value{ .null = {} }) {
                .integer => |n| n,
                else => null,
            },
            else => null,
        } else null;
        return .{
            .title = try allocator.dupe(u8, title),
            .unread_count = unread_count,
            .last_message_id = last_message_id,
        };
    }

    /// Same `viewMessages` request as `markMessagesRead`, for exactly one
    /// message, but never waits for (or even tags) a response — no `@extra`
    /// means `pollFn` never diverts TDLib's answer anywhere special, it
    /// just falls through the update-type dispatch below and is silently
    /// ignored, the same as any other update type this connector doesn't
    /// act on. Used by `convertNewMessage` to mark every inbound message
    /// read as it arrives, where confirming success isn't worth a blocking
    /// round trip on the poll loop's hot path (unlike `fetchUnread`'s
    /// deliberate, owner-initiated mark-read, which reports failure back to
    /// the owner) — a transient failure here just leaves that one message
    /// unread, no different from a read receipt a human might miss.
    fn markSeenFireAndForget(self: *TelegramUserConnector, chat_id: i64, message_id: i64) void {
        self.send(.{
            .@"@type" = "viewMessages",
            .chat_id = chat_id,
            .message_ids = &[_]i64{message_id},
            .force_read = true,
        });
    }

    /// `viewMessages(chat_id, message_ids, force_read=true)` — marks
    /// exactly the given messages viewed. Per Telegram's own read-state
    /// model this is a single forward-moving cursor per chat, not a
    /// per-message flag: viewing the newest message in a contiguous unread
    /// run implicitly marks everything older than it read too. Callers
    /// (see `chat_summary.zig`'s capped-fetch handling) must account for
    /// that themselves — this function does exactly what it's told and
    /// nothing more. Returns `true` on a clean `ok` response, `false` on
    /// timeout/error (logged either way).
    pub fn markMessagesRead(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64, message_ids: []const i64) !bool {
        if (message_ids.len == 0) return true;
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "viewMessages",
            .chat_id = chat_id,
            .message_ids = message_ids,
            .force_read = true,
            .@"@extra" = extra_id,
        });
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("markMessagesRead: viewMessages timed out for chat {d}", .{chat_id});
            return false;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("markMessagesRead: failed to parse viewMessages response: {t}", .{err});
            return false;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        const type_str = switch (obj.get("@type") orelse return false) {
            .string => |s| s,
            else => return false,
        };
        if (!std.mem.eql(u8, type_str, "ok")) {
            log.warn("markMessagesRead: viewMessages error for chat {d}: {s}", .{ chat_id, raw });
            return false;
        }
        return true;
    }

    /// Reads whatever is currently sitting in `chat_id`'s Telegram composer
    /// — the per-chat draft Telegram itself syncs across the account's
    /// devices (`getChat` -> `draft_message.input_message_text.text.text`).
    /// `null` for an empty composer, a non-text draft (a draft photo
    /// caption, say — nothing this connector should be second-guessing), or
    /// any failure; the caller treats all three the same way, as "nothing of
    /// the owner's to preserve here".
    ///
    /// Deliberately a separate round trip rather than a field bolted onto
    /// `requestChatMeta`'s `ChatMeta`: that one is called on the
    /// summarize/unread path where the draft is irrelevant, and this one on
    /// the draft path where the unread count is.
    pub fn fetchComposerDraft(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64) !?[]const u8 {
        const extra_id = self.nextExtraId();
        self.send(.{ .@"@type" = "getChat", .chat_id = chat_id, .@"@extra" = extra_id });
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("fetchComposerDraft: getChat timed out for chat {d}", .{chat_id});
            return null;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("fetchComposerDraft: failed to parse getChat response: {t}", .{err});
            return null;
        };
        defer parsed.deinit();

        // getChat -> chat.draft_message.input_message_text.text.text, with
        // every level optional: no draft at all, a draft whose content isn't
        // `inputMessageText`, or an `error` response all land on `null`.
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return null,
        };
        const draft = switch (obj.get("draft_message") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const input = switch (draft.get("input_message_text") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        if (input.get("@type")) |v| if (!(v == .string and std.mem.eql(u8, v.string, "inputMessageText"))) return null;
        const formatted = switch (input.get("text") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const text = switch (formatted.get("text") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (text.len == 0) return null;
        return try allocator.dupe(u8, text);
    }

    /// Writes `text` into `chat_id`'s Telegram composer as a draft, so
    /// opening that chat in any Telegram client shows it already typed and
    /// ready to edit or send. This is real Telegram draft sync — it
    /// propagates to the account's phone and desktop, not just wherever
    /// Warden happens to run.
    ///
    /// Every field TDLib defaults sensibly is omitted rather than spelled
    /// out (`reply_to`, `link_preview_options`, `clear_draft`, `entities`,
    /// `message_thread_id`): td_json fills in defaults for absent fields,
    /// and the codebase already sends partial request objects everywhere
    /// else (`getChat` above sends two fields).
    ///
    /// Returns whether TDLib acknowledged it. Waits for that answer rather
    /// than firing and forgetting (unlike `markSeenFireAndForget`) because
    /// this one is user-visible: the owner is about to be told "there's a
    /// draft waiting in that chat", and being wrong about that is worse
    /// than a missed read receipt.
    pub fn setChatDraft(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64, text: []const u8, date: i64) bool {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "setChatDraftMessage",
            .chat_id = chat_id,
            .draft_message = .{
                .@"@type" = "draftMessage",
                .date = @as(i32, @truncate(date)),
                .input_message_text = .{
                    .@"@type" = "inputMessageText",
                    .text = .{ .@"@type" = "formattedText", .text = text },
                },
            },
            .@"@extra" = extra_id,
        });
        return self.awaitOk(allocator, io, extra_id, "setChatDraftMessage", chat_id);
    }

    /// Empties `chat_id`'s Telegram composer (`draft_message: null`) — used
    /// once an AI draft has been approved and sent, or discarded, so the
    /// text doesn't linger in the composer where it could be sent a second
    /// time by accident.
    pub fn clearChatDraft(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, chat_id: i64) bool {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "setChatDraftMessage",
            .chat_id = chat_id,
            .draft_message = @as(?u8, null),
            .@"@extra" = extra_id,
        });
        return self.awaitOk(allocator, io, extra_id, "setChatDraftMessage(clear)", chat_id);
    }

    /// Shared tail of the two composer-draft writes: waits for `extra_id`'s
    /// response and reports whether it was a plain `ok`, logging anything
    /// else. Same response shape `markMessagesRead` checks by hand.
    fn awaitOk(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, extra_id: u64, what: []const u8, chat_id: i64) bool {
        const raw = (self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) catch |err| {
            log.warn("{s}: waiting for a response failed for chat {d}: {t}", .{ what, chat_id, err });
            return false;
        }) orelse {
            log.warn("{s}: timed out for chat {d}", .{ what, chat_id });
            return false;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("{s}: failed to parse response for chat {d}: {t}", .{ what, chat_id, err });
            return false;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        const type_str = switch (obj.get("@type") orelse return false) {
            .string => |s| s,
            else => return false,
        };
        if (!std.mem.eql(u8, type_str, "ok")) {
            log.warn("{s}: error for chat {d}: {s}", .{ what, chat_id, raw });
            return false;
        }
        return true;
    }

    /// Answers `authorizationStateWaitPhoneNumber`. `phone_number` is the
    /// full international-format number (e.g. "+15551234567").
    /// What answering an auth step (`submitPhoneNumber`/`submitAuthCode`/
    /// `submitPassword`) actually did — unlike the state machine's own
    /// `updateAuthorizationState` stream, this is specifically for
    /// reporting a *rejected* step (wrong code, wrong 2FA password, ...)
    /// back to whoever's driving the login, since TDLib answers those with
    /// a request-level `error` response, not an update — nothing in
    /// `pollFn`'s update-type dispatch would otherwise ever see it (see
    /// `awaitAuthStep`'s doc comment for the mechanics).
    pub const AuthStepOutcome = union(enum) {
        /// TDLib accepted the step; the real confirmation is whatever
        /// `updateAuthorizationState` fires next (e.g.
        /// `authorizationStateWaitPassword`, or `authorizationStateReady`
        /// once every step has passed).
        ok,
        /// TDLib rejected the step outright — the human-readable reason it
        /// gave (e.g. "PASSWORD_HASH_INVALID"), duped onto the caller's
        /// allocator. The auth state does *not* advance; the same step can
        /// just be retried.
        rejected: []const u8,
        /// No response arrived within `request_timeout_seconds` (already
        /// logged). Unlike `rejected`, this doesn't mean TDLib said no —
        /// it might still be mid-flight; safest to check `/tdlogin status`
        /// before retrying.
        timed_out,
    };

    /// Shared response wait+classify for the three auth-step submissions
    /// below — each sends its own request shape tagged with `extra_id`,
    /// then hands off here rather than duplicating the parse/branch logic
    /// `markMessagesRead`'s own ok/error check already established.
    fn awaitAuthStep(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, extra_id: u64, what: []const u8) !AuthStepOutcome {
        const raw = try self.waitForResponse(allocator, io, extra_id, request_timeout_seconds) orelse {
            log.warn("{s}: timed out waiting for a response", .{what});
            return .timed_out;
        };
        defer allocator.free(raw);

        var parsed = json.parseFromSlice(json.Value, allocator, raw, .{}) catch |err| {
            log.warn("{s}: failed to parse response: {t}", .{ what, err });
            return .timed_out;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .timed_out,
        };
        const type_str = switch (obj.get("@type") orelse return .timed_out) {
            .string => |s| s,
            else => return .timed_out,
        };
        if (!std.mem.eql(u8, type_str, "error")) return .ok;

        const message = switch (obj.get("message") orelse json.Value{ .null = {} }) {
            .string => |s| s,
            else => "unknown error",
        };
        log.warn("{s}: rejected: {s}", .{ what, message });
        return .{ .rejected = try allocator.dupe(u8, message) };
    }

    /// Answers `authorizationStateWaitPhoneNumber`. Waits for TDLib's
    /// response (unlike this connector's other simple `send()`-and-forget
    /// requests) so a rejected phone number can be reported back to
    /// whoever's driving the login instead of leaving them watching a
    /// state that silently never advances — see `AuthStepOutcome`'s doc
    /// comment for why this needed its own request/response handling.
    pub fn submitPhoneNumber(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, phone_number: []const u8) !AuthStepOutcome {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "setAuthenticationPhoneNumber",
            .phone_number = phone_number,
            .@"@extra" = extra_id,
        });
        return self.awaitAuthStep(allocator, io, extra_id, "submitPhoneNumber");
    }

    /// Answers `authorizationStateWaitCode`. `code` is whatever the caller
    /// resolved the login code down to — callers accepting it from a
    /// Telegram chat (rather than warden-ui's web form) are responsible for
    /// stripping whatever obfuscation they asked the owner to type it with
    /// (see `platform/interface.zig`'s `Platform.telegram_user` doc comment
    /// and README's login-flow section) *before* calling this; this
    /// function sends exactly the digits it's given. See
    /// `submitPhoneNumber`'s doc comment for why this waits for a response.
    pub fn submitAuthCode(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, code: []const u8) !AuthStepOutcome {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "checkAuthenticationCode",
            .code = code,
            .@"@extra" = extra_id,
        });
        return self.awaitAuthStep(allocator, io, extra_id, "submitAuthCode");
    }

    /// Answers `authorizationStateWaitPassword` (2FA). See
    /// `submitPhoneNumber`'s doc comment for why this waits for a response
    /// — this is the step that motivated adding it: a wrong password
    /// previously failed with no feedback at all (2026-08-26, direct owner
    /// report after a real login attempt silently stalled here).
    pub fn submitPassword(self: *TelegramUserConnector, allocator: std.mem.Allocator, io: Io, password: []const u8) !AuthStepOutcome {
        const extra_id = self.nextExtraId();
        self.send(.{
            .@"@type" = "checkAuthenticationPassword",
            .password = password,
            .@"@extra" = extra_id,
        });
        return self.awaitAuthStep(allocator, io, extra_id, "submitPassword");
    }

    /// TDLib's `logOut` — clears the account's session both locally
    /// (`session_dir` on disk) and server-side, same as removing the
    /// device from Telegram's own "active sessions" list. Fire-and-forget
    /// (unlike `submitPhoneNumber`/`submitAuthCode`/`submitPassword`
    /// above): no `@extra` correlation needed, since the result shows up
    /// through the normal `updateAuthorizationState` stream this connector
    /// already handles -- `authorizationStateClosed` (already wired in
    /// `handleAuthorizationState`) resets `client_id` to `null`, so the
    /// very next `pollFn` cycle's `ensureClient()` call transparently spins
    /// up a fresh client, which (session data now cleared) lands back on
    /// `authorizationStateWaitPhoneNumber` -- ready for a normal
    /// `/tdlogin phone <number>` with no separate "re-init" step needed.
    pub fn logOut(self: *TelegramUserConnector) void {
        self.send(.{ .@"@type" = "logOut" });
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        _ = allocator;
        const chat_id_int = std.fmt.parseInt(i64, chat_id, 10) catch {
            log.err("sendMessageFn: chat_id '{s}' isn't a valid integer", .{chat_id});
            return;
        };
        const reply_id_int: i64 = if (reply_to_message_id) |r| std.fmt.parseInt(i64, r, 10) catch 0 else 0;
        self.send(.{
            .@"@type" = "sendMessage",
            .chat_id = chat_id_int,
            .reply_to = if (reply_id_int != 0) .{ .@"@type" = "inputMessageReplyToMessage", .message_id = reply_id_int } else null,
            .input_message_content = .{
                .@"@type" = "inputMessageText",
                .text = .{ .@"@type" = "formattedText", .text = text },
            },
        });
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *TelegramUserConnector = @ptrCast(@alignCast(ptr));
        self.ensureClient();

        var out: std.ArrayList(iface.Message) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < drain_limit) : (i += 1) {
            const timeout = if (i == 0) receive_timeout_seconds else 0.0;
            const raw_result = td.td_receive(timeout);
            if (raw_result == null) break;
            const raw_slice = std.mem.span(raw_result);

            var parsed = json.parseFromSlice(json.Value, allocator, raw_slice, .{}) catch |err| {
                log.warn("pollFn: failed to parse update as JSON: {t}", .{err});
                continue;
            };
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const type_name = if (obj.get("@type")) |v| switch (v) {
                .string => |s| s,
                else => continue,
            } else continue;

            // A response to a request `send()` tagged with `.@"@extra"`
            // (see `requestChatMeta`/`markMessagesRead`) — TDLib echoes it
            // back verbatim on
            // whatever object answers that request (including error
            // responses), indistinguishable from an unprompted update by
            // `@type` alone. Diverted to `pending_responses` instead of
            // falling into the update-type dispatch below; every other
            // request this connector sends (`getAuthorizationState`,
            // `setTdlibParameters`, `loadChats`, `sendMessage`, ...) never
            // sets `@extra`, so this branch never fires for them.
            if (obj.get("@extra")) |extra_v| if (extra_v == .integer) {
                self.storePendingResponse(self.io, @intCast(extra_v.integer), raw_slice);
                continue;
            };

            if (std.mem.eql(u8, type_name, "updateAuthorizationState")) {
                self.handleAuthorizationState(obj);
                continue;
            }
            if (std.mem.eql(u8, type_name, "updateNewMessage")) {
                if (try self.convertNewMessage(allocator, obj)) |msg| {
                    try out.append(allocator, msg);
                }
                continue;
            }
            if (std.mem.eql(u8, type_name, "updateNewChat")) {
                self.handleUpdateNewChat(obj);
                continue;
            }
            if (std.mem.eql(u8, type_name, "updateChatTitle")) {
                self.handleUpdateChatTitle(obj);
                continue;
            }
            // Every other update type (typing indicators, read receipts,
            // ...) is silently ignored for now — Phase A scope, see the
            // struct doc comment.
        }

        return try out.toOwnedSlice(allocator);
    }

    fn handleUpdateNewChat(self: *TelegramUserConnector, update: json.ObjectMap) void {
        const chat = switch (update.get("chat") orelse return) {
            .object => |o| o,
            else => return,
        };
        const chat_id = switch (chat.get("id") orelse return) {
            .integer => |n| n,
            else => return,
        };
        const title = switch (chat.get("title") orelse return) {
            .string => |s| s,
            else => return,
        };
        if (title.len == 0) return; // e.g. a not-yet-resolved private chat
        var buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&buf, "{d}", .{chat_id}) catch return;
        self.setKnownChatTitle(id_str, title);
    }

    fn handleUpdateChatTitle(self: *TelegramUserConnector, update: json.ObjectMap) void {
        const chat_id = switch (update.get("chat_id") orelse return) {
            .integer => |n| n,
            else => return,
        };
        const title = switch (update.get("title") orelse return) {
            .string => |s| s,
            else => return,
        };
        var buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&buf, "{d}", .{chat_id}) catch return;
        self.setKnownChatTitle(id_str, title);
    }

    fn handleAuthorizationState(self: *TelegramUserConnector, update: json.ObjectMap) void {
        const state_obj = switch (update.get("authorization_state") orelse return) {
            .object => |o| o,
            else => return,
        };
        const state_type = switch (state_obj.get("@type") orelse return) {
            .string => |s| s,
            else => return,
        };

        if (std.mem.eql(u8, state_type, "authorizationStateWaitTdlibParameters")) {
            self.auth_state = .wait_tdlib_parameters;
            self.sendTdlibParameters();
        } else if (std.mem.eql(u8, state_type, "authorizationStateWaitPhoneNumber")) {
            self.auth_state = .wait_phone_number;
            log.info("waiting for the owner's phone number — call submitPhoneNumber()", .{});
        } else if (std.mem.eql(u8, state_type, "authorizationStateWaitCode")) {
            self.auth_state = .wait_code;
            log.info("waiting for the login code Telegram just sent — call submitAuthCode()", .{});
        } else if (std.mem.eql(u8, state_type, "authorizationStateWaitPassword")) {
            self.auth_state = .wait_password;
            log.info("waiting for the account's 2FA password — call submitPassword()", .{});
        } else if (std.mem.eql(u8, state_type, "authorizationStateReady")) {
            self.auth_state = .ready;
            log.info("personal-account connector authenticated and ready", .{});
            self.send(.{ .@"@type" = "getMe" });
            // Without an explicit request, TDLib only proactively pushes
            // `updateNewChat` for however many chats it decides to eagerly
            // load on its own (observed live: groups/channels with recent
            // activity, but not most private chats, and not secret chats
            // at all) -- `loadChats` is the real "load N more chats into
            // memory" request (each one still arrives as its own
            // `updateNewChat`, same as the ones TDLib sends unprompted;
            // this just makes sure *all* of them eventually do, not only
            // whichever subset TDLib would have picked on its own). Sent
            // for both the main list and archive so `/tdchats` covers
            // archived chats too, not just the visible chat list. A
            // secret chat is still a regular `Chat` with
            // `type = secretChat` from this API's point of view, so no
            // separate request is needed for those specifically -- they
            // load (and populate `known_chats`) the same way once their
            // parent chat list is loaded.
            self.send(.{ .@"@type" = "loadChats", .chat_list = .{ .@"@type" = "chatListMain" }, .limit = 200 });
            self.send(.{ .@"@type" = "loadChats", .chat_list = .{ .@"@type" = "chatListArchive" }, .limit = 200 });
        } else if (std.mem.eql(u8, state_type, "authorizationStateLoggingOut")) {
            self.auth_state = .logging_out;
        } else if (std.mem.eql(u8, state_type, "authorizationStateClosed")) {
            self.auth_state = .closed;
            self.client_id = null; // next ensureClient() call creates a fresh instance
        } else {
            self.auth_state = .unsupported;
            if (self.unsupported_auth_type) |old| self.allocator.free(old);
            self.unsupported_auth_type = self.allocator.dupe(u8, state_type) catch null;
            log.err("unsupported authorization state '{s}' — login can't proceed from here (QR-code/other-device login isn't implemented, only the phone-number flow)", .{state_type});
        }
    }

    fn sendTdlibParameters(self: *TelegramUserConnector) void {
        self.send(.{
            .@"@type" = "setTdlibParameters",
            .database_directory = self.session_dir,
            .use_message_database = true,
            .use_secret_chats = false,
            .api_id = self.api_id,
            .api_hash = self.api_hash,
            .system_language_code = "en",
            .device_model = "Warden",
            .application_version = "1.0",
        });
    }

    /// `updateNewMessage.message` -> `iface.Message`, or `null` for a
    /// message shape this pass doesn't handle (non-text content, or one
    /// missing fields it needs) — same "skip, don't crash the poll loop
    /// over one unusual message" posture every other connector already
    /// takes on malformed/unexpected input.
    fn convertNewMessage(self: *TelegramUserConnector, allocator: std.mem.Allocator, update: json.ObjectMap) !?iface.Message {
        const message = switch (update.get("message") orelse return null) {
            .object => |o| o,
            else => return null,
        };

        // Echo of the account's own outgoing message (e.g. sent from
        // another device) — not an inbound message to react to.
        if (message.get("is_outgoing")) |v| if (v == .bool and v.bool) return null;

        const chat_id = switch (message.get("chat_id") orelse return null) {
            .integer => |n| n,
            else => return null,
        };

        // The owner reads every message through Warden, so it's already
        // been "seen" the moment it arrives here -- mark it read on
        // Telegram immediately rather than waiting for an explicit
        // /tdsummary or summarize_unread_chat call to do it as a side
        // effect (2026-08-26, direct owner request). Every message type
        // gets this, not just the text ones this pass actually converts
        // below -- a photo/sticker/etc. was still seen. Fire-and-forget
        // (see `markSeenFireAndForget`'s own doc comment) so this never
        // blocks the poll loop on a round trip.
        if (message.get("id")) |id_v| if (id_v == .integer) {
            self.markSeenFireAndForget(chat_id, id_v.integer);
        };

        const content = switch (message.get("content") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const content_type = switch (content.get("@type") orelse return null) {
            .string => |s| s,
            else => return null,
        };
        if (!std.mem.eql(u8, content_type, "messageText")) return null; // Phase A scope
        const formatted_text = switch (content.get("text") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const text = switch (formatted_text.get("text") orelse return null) {
            .string => |s| s,
            else => return null,
        };

        const sender = switch (message.get("sender_id") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const sender_user_id: ?i64 = switch (sender.get("user_id") orelse json.Value{ .null = {} }) {
            .integer => |n| n,
            else => null,
        };
        const user_id = sender_user_id orelse return null; // messages sent as a channel/anonymous admin — not attributable to a user, skip for now

        const message_id: ?i64 = switch (message.get("id") orelse json.Value{ .null = {} }) {
            .integer => |n| n,
            else => null,
        };

        const chat_id_str = try std.fmt.allocPrint(allocator, "{d}", .{chat_id});
        return .{
            .chat_id = chat_id_str,
            .message_id = if (message_id) |m| try std.fmt.allocPrint(allocator, "{d}", .{m}) else null,
            .user_id = try std.fmt.allocPrint(allocator, "{d}", .{user_id}),
            .text = try allocator.dupe(u8, text),
            // Left null before this, which meant everything downstream fell
            // back to the raw numeric chat id -- a `reply_autonomy = .draft`
            // notification read "Chat: -100123... (-100123...)" instead of
            // naming the person. TDLib volunteers `updateNewChat` for every
            // chat it knows shortly after login, so the cache is populated
            // by the time real messages arrive; `null` here just restores
            // the old fallback for the rare chat it hasn't mentioned yet.
            .chat_title = self.knownChatTitle(allocator, chat_id_str),
            // Private-chat vs. group/channel isn't distinguished yet — see
            // the struct doc comment's Phase A scope note. Always reported
            // as a 1:1 chat for now, meaning every message gets treated as
            // addressed to the owner, which is at least the safe direction
            // to be wrong in (never silently ignoring a real DM).
            .is_group = false,
            .identity = .{
                .platform = .telegram_user,
                .native_id = try std.fmt.allocPrint(allocator, "{d}", .{user_id}),
                .display_name = try std.fmt.allocPrint(allocator, "{d}", .{user_id}), // resolving a real name needs a getUser call — not made yet, see Phase A scope
                .first_seen = 0,
                .last_seen = 0,
            },
        };
    }
};

/// Best-effort "empty this chat's Telegram composer", tolerant of every
/// reason it might not be possible: no personal-account connector configured
/// on this deployment, or a `native_chat_id` that isn't a TDLib chat id.
/// Shared by every place a draft stops being pending — the Approve/Discard
/// buttons, `/approve`//`/discard`, and the web API's own two handlers — so
/// the composer never keeps text the owner has already acted on.
///
/// Deliberately silent about failure beyond a log line: the draft has
/// already been sent or discarded by the time this runs, and telling the
/// owner "…but I couldn't clear the composer" would be noise about
/// something they're about to see for themselves.
pub fn clearComposerDraftFor(conn: ?*TelegramUserConnector, allocator: std.mem.Allocator, io: Io, native_chat_id: []const u8) void {
    const c = conn orelse return;
    const chat_id = std.fmt.parseInt(i64, native_chat_id, 10) catch {
        log.warn("clearComposerDraftFor: not a numeric TDLib chat id: {s}", .{native_chat_id});
        return;
    };
    _ = c.clearChatDraft(allocator, io, chat_id);
}

const testing = std.testing;

test "AuthState starts at .none before ensureClient runs" {
    var conn = TelegramUserConnector.init(testing.allocator, testing.io, 1, "hash", "/tmp/warden-tdlib-test");
    try testing.expectEqual(AuthState.none, conn.authState());
    try testing.expectEqual(@as(?[]const u8, null), conn.self_user_id);
}

test "platformFn reports .telegram_user" {
    var conn = TelegramUserConnector.init(testing.allocator, testing.io, 1, "hash", "/tmp/warden-tdlib-test");
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.telegram_user, c.platform());
}
