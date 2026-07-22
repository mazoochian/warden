const std = @import("std");
const Io = std.Io;

const iface = @import("interface.zig");
const raw = @import("../xmpp/client.zig");
const xml = @import("../xmpp/xml.zig");
const types = @import("../xmpp/types.zig");
const Identity = @import("../domain/identity.zig").Identity;
const XmppProfile = @import("../domain/xmpp_profile.zig").XmppProfile;

/// How long a single `pollFn` cycle waits for a stanza before returning an
/// empty slice — bounds the blocking socket read so the round-robin poll
/// loop in `main.zig` (which polls every connector, one after another)
/// stays responsive to Telegram/Matrix even when nothing's happening on
/// XMPP. Shorter than Telegram/Matrix's ~25s HTTP long-poll timeout since
/// XMPP's read has no server-side "nothing happened yet" signal the way
/// long-poll does — it just blocks until bytes arrive.
const poll_timeout_ns: u64 = 8 * std.time.ns_per_s;
const poll_check_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// XMPP implementation of `platform.Connector` — MVP scope (1:1 chat +
/// MUC group chat, SASL PLAIN only, no E2EE/OMEMO, no file transfer, no
/// roster UI beyond auto-accepting subscriptions): see README's "XMPP"
/// section for the full list of documented simplifications, same spirit as
/// `matrix.zig`'s doc comment on its own scope cuts.
///
/// Unlike Telegram/Matrix's stateless HTTP long-poll, XMPP is a persistent
/// socket: `ensureConnected` drives the full connect/STARTTLS/SASL/bind/
/// MUC-join sequence lazily on first `poll()` and again after any
/// connection loss, since a dropped socket needs a real reconnect, not
/// just a retried request.
pub const XmppConnector = struct {
    allocator: std.mem.Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    domain: []const u8,
    jid_user: []const u8,
    password: []const u8,
    resource: []const u8,
    muc_rooms: []const []const u8,
    client: ?*raw.Client = null,
    bound_jid: ?[]const u8 = null,
    /// Bare room JIDs currently joined — `sendMessageFn` checks membership
    /// here to pick `type='groupchat'` vs `type='chat'`.
    joined_rooms: std.ArrayList([]const u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        domain: []const u8,
        jid_user: []const u8,
        password: []const u8,
        muc_rooms: []const []const u8,
    ) XmppConnector {
        return .{
            .allocator = allocator,
            .io = io,
            .host = host,
            .port = port,
            .domain = domain,
            .jid_user = jid_user,
            .password = password,
            .resource = "warden",
            .muc_rooms = muc_rooms,
        };
    }

    pub fn deinit(self: *XmppConnector) void {
        if (self.client) |c| c.close();
        if (self.bound_jid) |j| self.allocator.free(j);
        for (self.joined_rooms.items) |r| self.allocator.free(r);
        self.joined_rooms.deinit(self.allocator);
    }

    pub fn connector(self: *XmppConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .selfId = selfIdFn,
        // No `selfUsername`: an XMPP JID's localpart already covers this
        // (`selfId` returns the full bound JID), same as Matrix.
        // No moderation/media vtable slots: out of scope for tonight's MVP
        // (see README) — every one of those falls back to
        // `error.Unsupported`, matching the pre-existing stub's behavior
        // for anything it didn't implement either.
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .xmpp;
    }

    fn selfIdFn(ptr: *anyopaque) ?[]const u8 {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.bound_jid;
    }

    fn ensureConnected(self: *XmppConnector, allocator: std.mem.Allocator) !void {
        if (self.client != null) return;

        const client = try raw.Client.connect(self.allocator, self.io, self.host, self.port);
        errdefer client.close();

        _ = try client.openStream(allocator, self.domain);
        try client.startTls();

        const features2 = try client.openStream(allocator, self.domain);
        defer {
            for (features2.mechanisms) |m| allocator.free(m);
            allocator.free(features2.mechanisms);
        }
        if (!features2.hasMechanism("PLAIN")) return error.NoUsablePlainMechanism;
        try client.authPlain(allocator, self.jid_user, self.password);

        const features3 = try client.openStream(allocator, self.domain);
        defer {
            for (features3.mechanisms) |m| allocator.free(m);
            allocator.free(features3.mechanisms);
        }

        const jid = try client.bindResource(allocator, self.resource, features3.session);
        allocator.free(jid); // `client.bound_jid` already holds its own copy.

        if (self.bound_jid) |old| self.allocator.free(old);
        self.bound_jid = try self.allocator.dupe(u8, client.bound_jid.?);
        self.client = client;

        for (self.muc_rooms) |room| {
            client.joinMuc(allocator, room, self.resource) catch |err| {
                std.log.warn("xmpp: failed to join MUC room {s}: {t}", .{ room, err });
                continue;
            };
            const dup = self.allocator.dupe(u8, room) catch continue;
            self.joined_rooms.append(self.allocator, dup) catch self.allocator.free(dup);
        }

        std.log.info("xmpp: connected as {s}", .{self.bound_jid.?});
    }

    fn isJoinedRoom(self: *XmppConnector, chat_id: []const u8) bool {
        for (self.joined_rooms.items) |r| if (std.mem.eql(u8, r, chat_id)) return true;
        return false;
    }

    const ReadShared = struct {
        done: std.atomic.Value(bool) = .init(false),
        result: anyerror!xml.ParsedElement = undefined,
    };

    fn readElementAndFlag(client: *raw.Client, allocator: std.mem.Allocator, shared: *ReadShared) void {
        shared.result = client.readElement(allocator);
        shared.done.store(true, .release);
    }

    /// Blocks up to `poll_timeout_ns` for one stanza, on a real detachable
    /// `std.Thread` rather than `Io.concurrent` + `Future.cancel` — mirrors
    /// `http_util.zig`'s `fetchWithTimeout` fix (see its module doc for the
    /// full story): the underlying socket read (`Client.readElement` /
    /// `fillMore`) is a plain blocking call with no `Io`-native
    /// cancellation point, so `cancel()` could never actually interrupt it —
    /// confirmed by the exact same failure mode `8dcbcd8` fixed for HTTP,
    /// just not yet applied here: a black-holed connection left `cancel()`
    /// blocked waiting forever for a task to unwind that never would,
    /// freezing this connector's poll loop (and, per `main.zig`'s
    /// `WorkerPool`/`Heartbeat` doc comments, everything downstream of it)
    /// permanently.
    ///
    /// `readElement`'s allocations go through `self.allocator` (long-lived,
    /// owned by this connector) rather than the caller's per-poll-cycle
    /// arena — required so an abandoned thread that eventually does finish
    /// writing into `shared` never touches memory the caller may have
    /// already freed (same reasoning as `http_util.zig`'s `FetchShared`).
    ///
    /// On timeout this detaches and abandons the thread — a small, bounded
    /// leak (the read's eventual result, if it ever arrives) — and, unlike
    /// a one-shot HTTP request, also gives up this connector's `Client`
    /// entirely (`self.client = null`, never `client.close()`'d: that would
    /// free/close state the abandoned thread might still be touching,
    /// trading a leak for a use-after-free). `Client.readElement` isn't
    /// safe for two threads to call concurrently, so once one read might
    /// still be in flight in the background, the only safe way to poll
    /// again is a brand-new connection instead of reusing this one.
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));

        self.ensureConnected(allocator) catch |err| {
            std.log.warn("xmpp: connect failed, will retry next cycle: {t}", .{err});
            return &.{};
        };
        const client = self.client.?;

        const shared = try self.allocator.create(ReadShared);
        shared.* = .{};
        const thread = std.Thread.spawn(.{}, readElementAndFlag, .{ client, self.allocator, shared }) catch |err| {
            self.allocator.destroy(shared);
            return err;
        };

        var waited_ns: u64 = 0;
        while (!shared.done.load(.acquire) and waited_ns < poll_timeout_ns) {
            const step = @min(poll_check_interval_ns, poll_timeout_ns - waited_ns);
            Io.sleep(self.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
            waited_ns += step;
        }

        if (!shared.done.load(.acquire)) {
            // Deliberately not joined, not freed, and `client` deliberately
            // not closed — see this function's doc comment.
            thread.detach();
            self.client = null;
            return &.{};
        }
        thread.join();
        defer self.allocator.destroy(shared);

        var parsed = shared.result catch |err| {
            std.log.warn("xmpp: connection lost ({t}), will reconnect next cycle", .{err});
            client.close();
            self.client = null;
            return &.{};
        };
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.element.name, "presence")) {
            self.handlePresence(allocator, parsed.element) catch |err| {
                std.log.warn("xmpp: failed to handle presence: {t}", .{err});
            };
            return &.{};
        }

        return self.messagesFromElement(allocator, parsed.element) catch |err| {
            std.log.warn("xmpp: failed to map an inbound message: {t}", .{err});
            return &.{};
        };
    }

    /// Auto-accepts subscription requests — see this file's module doc
    /// comment on why that's this connector's whole roster story for now.
    fn handlePresence(self: *XmppConnector, allocator: std.mem.Allocator, el: xml.Element) !void {
        const from = el.attr("from") orelse return;
        const kind = el.attr("type") orelse return;
        if (!std.mem.eql(u8, kind, "subscribe")) return;
        const client = self.client orelse return;
        try client.acceptSubscription(allocator, bareJid(from));
    }

    fn messagesFromElement(self: *XmppConnector, allocator: std.mem.Allocator, el: xml.Element) ![]iface.Message {
        if (!std.mem.eql(u8, el.name, "message")) return &.{};
        const stanza = (try types.MessageStanza.fromElement(allocator, el)) orelse return &.{};
        const body = stanza.body orelse return &.{};
        if (body.len == 0) return &.{};

        const is_group = std.mem.eql(u8, stanza.type, "groupchat");
        // MUC's `from` is `room@server/nick` — `bareJid` of that is exactly
        // the room's own JID, so this one derivation gives the right
        // `chat_id` for both shapes: the room for MUC, the sender for 1:1.
        const chat_id = bareJid(stanza.from);
        // 1:1 uses the bare JID (stable across a user's devices, matching
        // Matrix's `@user:server`); MUC has no stabler identity to offer
        // than `room@server/nick` (semi-anonymous by default), so its
        // `user_id` stays resource-qualified.
        const user_id = if (is_group) stanza.from else chat_id;
        const display_name = if (is_group) (resourcePart(stanza.from) orelse chat_id) else chat_id;

        const now = Io.Timestamp.now(self.io, .real).toSeconds();
        const identity = Identity{
            .platform = .xmpp,
            .native_id = try allocator.dupe(u8, user_id),
            .display_name = try allocator.dupe(u8, display_name),
            .is_bot = false,
            .first_seen = now,
            .last_seen = now,
        };
        const xmpp_profile = XmppProfile{
            .identity = identity,
            .jid_resource = if (is_group) null else resourcePart(stanza.from),
        };

        const out = try allocator.alloc(iface.Message, 1);
        out[0] = .{
            .chat_id = try allocator.dupe(u8, chat_id),
            .user_id = try allocator.dupe(u8, user_id),
            .text = try allocator.dupe(u8, body),
            .is_group = is_group,
            .chat_type = if (is_group) "muc" else "chat",
            .identity = identity,
            .xmpp_profile = xmpp_profile,
        };
        return out;
    }

    fn bareJid(full: []const u8) []const u8 {
        const slash = std.mem.indexOfScalar(u8, full, '/') orelse return full;
        return full[0..slash];
    }

    fn resourcePart(full: []const u8) ?[]const u8 {
        const slash = std.mem.indexOfScalar(u8, full, '/') orelse return null;
        return full[slash + 1 ..];
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = reply_to_message_id; // No reply-threading concept this connector uses yet.
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        const client = self.client orelse {
            std.log.warn("xmpp: dropped message to {s}, not connected: {s}", .{ chat_id, text });
            return;
        };
        const kind = if (self.isJoinedRoom(chat_id)) "groupchat" else "chat";
        client.sendMessage(allocator, chat_id, kind, text) catch |err| {
            std.log.warn("xmpp: failed to send message to {s}: {t}", .{ chat_id, err });
        };
    }
};

const testing = std.testing;

test "bareJid strips a resource, resourcePart extracts it" {
    try testing.expectEqualStrings("room@conference.example.org", XmppConnector.bareJid("room@conference.example.org/nick"));
    try testing.expectEqualStrings("alice@example.org", XmppConnector.bareJid("alice@example.org"));
    try testing.expectEqualStrings("nick", XmppConnector.resourcePart("room@conference.example.org/nick").?);
    try testing.expectEqual(@as(?[]const u8, null), XmppConnector.resourcePart("alice@example.org"));
}

test "XmppConnector reports its platform" {
    var conn = XmppConnector.init(testing.allocator, testing.io, "localhost", 5222, "localhost", "warden", "secret", &.{});
    defer conn.deinit();
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.xmpp, c.platform());
}

test "XmppConnector reports Unsupported for every moderation action (no vtable entries set)" {
    var conn = XmppConnector.init(testing.allocator, testing.io, "localhost", 5222, "localhost", "warden", "secret", &.{});
    defer conn.deinit();
    const c = conn.connector();
    try testing.expectError(error.Unsupported, c.isGroupAdmin(testing.allocator, "1", "2"));
    try testing.expectError(error.Unsupported, c.kickUser(testing.allocator, "1", "2"));
}

test "XmppConnector.sendMessage drops the message and logs when not connected" {
    var conn = XmppConnector.init(testing.allocator, testing.io, "localhost", 5222, "localhost", "warden", "secret", &.{});
    defer conn.deinit();
    const c = conn.connector();
    // Not connected (no live server dialed) — must not crash, just drop.
    c.sendMessage(testing.allocator, "alice@example.org", "hi", null);
}
