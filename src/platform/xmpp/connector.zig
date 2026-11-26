const std = @import("std");
const Io = std.Io;
const http = std.http;

const iface = @import("../interface.zig");
const raw = @import("client.zig");
const xml = @import("xml.zig");
const types = @import("types.zig");
const stanza = @import("stanza.zig");
const media = @import("media.zig");
const Identity = @import("../../domain/identity.zig").Identity;
const XmppProfile = @import("../../domain/xmpp_profile.zig").XmppProfile;
const log = @import("../../log.zig").scoped("xmpp");
const llm = @import("../../llm/provider.zig");
const http_util = @import("../../http_util.zig");
const omemo = @import("omemo/engine.zig");
const omemo_store = @import("../../store/omemo.zig");
const PgPool = @import("../../store/pool.zig").PgPool;
const test_support = @import("../../store/test_support.zig");

/// How long a single `pollFn` cycle waits for a stanza before returning an
/// empty slice.
const poll_timeout_ns: u64 = 8 * std.time.ns_per_s;

/// Cooldown after a failed `ensureConnected` before `pollFn` returns —
/// discovered live while adding logging (2026-07-25).
const reconnect_cooldown_ns: u64 = 5 * std.time.ns_per_s;
const poll_check_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// How long the connection can sit with no stanza read, keepalive sent.
const keepalive_idle_seconds: i64 = 60;

/// How long `request` waits for an IQ reply.
const iq_timeout_ns: u64 = 15 * std.time.ns_per_s;
const iq_check_interval_ns: u64 = 25 * std.time.ns_per_ms;

/// How many of our own recently sent message ids are remembered, for
/// recognizing MUC reflections, replies to the bot, and retractions.
const recent_capacity = 512;

/// How long a peer's fetched OMEMO device list is reused.
const device_cache_seconds: i64 = 10 * 60;

/// How `platform/xmpp/client.zig`'s `startTls` verifies the server's
/// certificate.
pub const TlsMode = enum { self_signed, bundle, insecure };

/// Fixed-size ring of owned key -> value strings; the oldest entry is
/// overwritten once full.
const RecentMap = struct {
    keys: [recent_capacity]?[]u8 = @splat(null),
    values: [recent_capacity][]u8 = @splat(&.{}),
    next: usize = 0,

    fn put(self: *RecentMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) void {
        const k = allocator.dupe(u8, key) catch return;
        const v = allocator.dupe(u8, value) catch {
            allocator.free(k);
            return;
        };
        if (self.keys[self.next]) |old| {
            allocator.free(old);
            allocator.free(self.values[self.next]);
        }
        self.keys[self.next] = k;
        self.values[self.next] = v;
        self.next = (self.next + 1) % recent_capacity;
    }

    fn get(self: *const RecentMap, key: []const u8) ?[]const u8 {
        for (self.keys, self.values) |k, v| {
            if (k) |kk| if (std.mem.eql(u8, kk, key)) return v;
        }
        return null;
    }

    fn deinit(self: *RecentMap, allocator: std.mem.Allocator) void {
        for (self.keys, self.values) |k, v| if (k) |kk| {
            allocator.free(kk);
            allocator.free(v);
        };
        self.* = .{};
    }
};

/// One in-flight `request`, resolved by the poll thread when the matching
/// `<iq type='result'/'error'>` arrives.
const PendingIq = struct {
    /// Owned. Null means "our own account or server" (no `to`).
    expect_from: ?[]u8,
    done: std.atomic.Value(bool) = .init(false),
    result: ?xml.ParsedElement = null,
};

/// XMPP implementation of `platform.Connector`.
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
    tls_mode: TlsMode,
    /// Replaced only by the poll thread, under `client_mu`; worker threads
    /// read it under `client_mu` too.
    client: ?*raw.Client = null,
    client_mu: Io.Mutex = .init,
    bound_jid: ?[]const u8 = null,
    /// Guards `joined_rooms`, `occupants`, `sent_ids` and `muc_stanza_ids`.
    state_mu: Io.Mutex = .init,
    /// Bare room JIDs currently joined — `sendMessageFn` checks membership
    /// here to pick `type='groupchat'` vs `type='chat'`.
    joined_rooms: std.ArrayList([]const u8) = .empty,
    /// Our own recently sent message ids -> the chat they went to.
    sent_ids: RecentMap = .{},
    /// Our own MUC message ids -> the stanza-id the room assigned them.
    muc_stanza_ids: RecentMap = .{},
    pending_mu: Io.Mutex = .init,
    pending_iqs: std.StringHashMapUnmanaged(*PendingIq) = .empty,
    /// The one outstanding background stanza read, kept alive ACROSS `pollFn`
    /// calls rather than respawned every cycle.
    read_thread: ?std.Thread = null,
    read_shared: ?*ReadShared = null,
    /// Wall-clock seconds of the last stanza received, keepalive sent, or fresh
    /// connect.
    last_activity_unix: i64 = 0,
    /// Loaded lazily, once, only when `tls_mode == .bundle` — see
    /// `ensureConnected`.
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_bundle_loaded: bool = false,
    ca_bundle_lock: Io.RwLock = .init,
    /// Occupants of every currently-joined MUC room, keyed by their full occupant
    /// JID.
    occupants: std.StringHashMap(Occupant),
    http_client: http.Client,
    /// HTTP File Upload service, discovered on first use per connection.
    upload_mu: Io.Mutex = .init,
    upload_jid: ?[]u8 = null,
    upload_max_size: ?u64 = null,
    /// Set by `enableOmemo`; 1:1 chats then go encrypted when the peer's do.
    omemo: ?*omemo.Engine = null,
    /// Set by `ensureConnected`; the poll thread then publishes our device.
    omemo_publish_due: bool = false,
    /// The thread `pollFn` runs on, which `request` must never block.
    poll_thread: std.atomic.Value(std.Thread.Id) = .init(0),
    /// Peers' OMEMO device ids, keyed by bare JID (under `state_mu`).
    device_cache: std.StringHashMapUnmanaged(CachedDevices) = .empty,

    const CachedDevices = struct { ids: []i32, fetched_at: i64 };

    const Occupant = struct {
        /// Owned copies of XEP-0045's affiliation ("owner"/"admin"/
        /// "member"/"outcast"/"none") and role ("moderator"/"participant"/
        /// "visitor"/"none") strings.
        affiliation: []const u8,
        role: []const u8,
        real_jid: ?[]const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        host: []const u8,
        port: u16,
        domain: []const u8,
        jid_user: []const u8,
        password: []const u8,
        muc_rooms: []const []const u8,
        tls_mode: TlsMode,
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
            .tls_mode = tls_mode,
            .occupants = std.StringHashMap(Occupant).init(allocator),
            .http_client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *XmppConnector) void {
        if (self.read_shared != null) {
            // A background read may still be blocked on `self.client`'s socket.
            self.read_thread.?.detach();
        } else if (self.client) |c| {
            c.close();
        }
        if (self.bound_jid) |j| self.allocator.free(j);
        self.clearRoomState();
        self.joined_rooms.deinit(self.allocator);
        self.occupants.deinit();
        self.sent_ids.deinit(self.allocator);
        self.muc_stanza_ids.deinit(self.allocator);
        self.failAllPending();
        self.pending_iqs.deinit(self.allocator);
        if (self.upload_jid) |j| self.allocator.free(j);
        self.http_client.deinit();
        var dc = self.device_cache.iterator();
        while (dc.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.ids);
        }
        self.device_cache.deinit(self.allocator);
        if (self.omemo) |e| e.deinit();

        if (self.ca_bundle_loaded) self.ca_bundle.deinit(self.allocator);
    }

    fn freeOccupantEntry(self: *XmppConnector, key: []const u8, value: Occupant) void {
        self.allocator.free(key);
        self.allocator.free(value.affiliation);
        self.allocator.free(value.role);
        if (value.real_jid) |j| self.allocator.free(j);
    }

    /// Forgets joined rooms and their occupants — on reconnect the rooms are
    /// re-joined and presence re-sent from scratch.
    fn clearRoomState(self: *XmppConnector) void {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        for (self.joined_rooms.items) |r| self.allocator.free(r);
        self.joined_rooms.clearRetainingCapacity();
        var it = self.occupants.iterator();
        while (it.next()) |entry| self.freeOccupantEntry(entry.key_ptr.*, entry.value_ptr.*);
        self.occupants.clearRetainingCapacity();
    }

    pub fn connector(self: *XmppConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendMessageReturningId = sendMessageReturningIdFn,
        .editMessage = editMessageFn,
        .deleteMessage = deleteMessageFn,
        .sendPhoto = sendPhotoFn,
        .sendDocument = sendDocumentFn,
        .sendVideo = sendVideoFn,
        .downloadFile = downloadFileFn,
        .selfId = selfIdFn,
        // No `selfUsername`: an XMPP JID's localpart already covers this
        // (`selfId` returns the full bound JID), same as Matrix.
        .muteUser = muteUserFn,
        .unmuteUser = unmuteUserFn,
        .kickUser = kickUserFn,
        .banUser = banUserFn,
        .promoteUser = promoteUserFn,
        .demoteUser = demoteUserFn,
        .isGroupAdmin = isGroupAdminFn,
        // Every other moderation/media/room-metadata slot.
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
        try client.startTls(try self.tlsVerification());

        const features2 = try client.openStream(allocator, self.domain);
        defer {
            for (features2.mechanisms) |m| allocator.free(m);
            allocator.free(features2.mechanisms);
        }
        // Prefer SCRAM whenever the server offers it — PLAIN is the fallback, not the
        // default.
        if (features2.hasMechanism("SCRAM-SHA-256")) {
            try client.authScramSha256(allocator, self.jid_user, self.password);
        } else if (features2.hasMechanism("SCRAM-SHA-1")) {
            try client.authScramSha1(allocator, self.jid_user, self.password);
        } else if (features2.hasMechanism("PLAIN")) {
            try client.authPlain(allocator, self.jid_user, self.password);
        } else {
            return error.NoUsableMechanism;
        }

        const features3 = try client.openStream(allocator, self.domain);
        defer {
            for (features3.mechanisms) |m| allocator.free(m);
            allocator.free(features3.mechanisms);
        }

        const jid = try client.bindResource(allocator, self.resource, features3.session);
        allocator.free(jid); // `client.bound_jid` already holds its own copy.

        // Initial presence: without it the server never routes MUC/1:1
        // presence-dependent traffic or offline messages to this resource.
        try client.sendStanza("<presence/>");

        if (self.bound_jid) |old| self.allocator.free(old);
        self.bound_jid = try self.allocator.dupe(u8, client.bound_jid.?);
        self.clearRoomState();
        self.resetUploadService();
        self.omemo_publish_due = self.omemo != null;
        {
            self.client_mu.lockUncancelable(self.io);
            defer self.client_mu.unlock(self.io);
            self.client = client;
        }
        self.last_activity_unix = Io.Timestamp.now(self.io, .real).toSeconds();

        for (self.muc_rooms) |room| {
            client.joinMuc(allocator, room, self.resource) catch |err| {
                log.warn("failed to join MUC room {s}: {t}", .{ room, err });
                continue;
            };
            const dup = self.allocator.dupe(u8, room) catch continue;
            self.state_mu.lockUncancelable(self.io);
            defer self.state_mu.unlock(self.io);
            self.joined_rooms.append(self.allocator, dup) catch self.allocator.free(dup);
        }

        log.notice("connected as {s}", .{self.bound_jid.?});
    }

    /// Drops the live connection after a read error; every waiting
    /// `request` fails.
    fn dropConnection(self: *XmppConnector) void {
        {
            self.client_mu.lockUncancelable(self.io);
            defer self.client_mu.unlock(self.io);
            if (self.client) |c| c.close();
            self.client = null;
        }
        self.failAllPending();
    }

    /// Builds this connect attempt's `Client.TlsVerification` from
    /// `self.tls_mode`.
    fn tlsVerification(self: *XmppConnector) !raw.Client.TlsVerification {
        return switch (self.tls_mode) {
            .insecure => .insecure,
            .self_signed => .{ .self_signed = .{ .host = self.domain } },
            .bundle => blk: {
                if (!self.ca_bundle_loaded) {
                    try self.ca_bundle.rescan(self.allocator, self.io, Io.Timestamp.now(self.io, .real));
                    self.ca_bundle_loaded = true;
                }
                break :blk .{ .bundle = .{
                    .host = self.domain,
                    .gpa = self.allocator,
                    .io = self.io,
                    .lock = &self.ca_bundle_lock,
                    .bundle = &self.ca_bundle,
                } };
            },
        };
    }

    fn isJoinedRoom(self: *XmppConnector, chat_id: []const u8) bool {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        for (self.joined_rooms.items) |r| if (std.mem.eql(u8, r, chat_id)) return true;
        return false;
    }

    /// Sends one serialized stanza on the live connection.
    fn send(self: *XmppConnector, bytes: []const u8) !void {
        self.client_mu.lockUncancelable(self.io);
        defer self.client_mu.unlock(self.io);
        const client = self.client orelse return error.NotConnected;
        try client.sendStanza(bytes);
    }

    fn newId(self: *XmppConnector, allocator: std.mem.Allocator) ![]const u8 {
        var bytes: [12]u8 = undefined;
        self.io.random(&bytes);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        return std.fmt.allocPrint(allocator, "w{s}", .{&hex});
    }

    /// Sends `<iq type=kind to=to>payload</iq>` and waits for the reply,
    /// which the caller owns. An `<iq type='error'>` reply is returned as
    /// `error.IqError`. Never call from the poll thread: it is the one that
    /// reads the reply.
    pub fn request(self: *XmppConnector, allocator: std.mem.Allocator, kind: []const u8, to: ?[]const u8, payload: []const u8) !xml.ParsedElement {
        if (std.Thread.getCurrentId() == self.poll_thread.load(.acquire)) return error.RequestFromPollThread;
        const id = try self.newId(allocator);
        defer allocator.free(id);

        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<iq type='");
        try out.writer.writeAll(kind);
        if (to) |t| {
            try out.writer.writeAll("' to='");
            try xml.writeEscapedAttr(&out.writer, t);
        }
        try out.writer.writeAll("' id='");
        try out.writer.writeAll(id);
        try out.writer.writeAll("'>");
        try out.writer.writeAll(payload);
        try out.writer.writeAll("</iq>");

        var reply = try self.requestRaw(id, to, out.writer.buffered());
        if (std.mem.eql(u8, reply.element.attr("type") orelse "", "error")) {
            if (reply.element.child("error")) |e| {
                for (e.children) |node| switch (node) {
                    .element => |c| {
                        log.debug("iq error from {s}: {s}", .{ to orelse "server", c.name });
                        break;
                    },
                    .text => {},
                };
            }
            reply.deinit();
            return error.IqError;
        }
        return reply;
    }

    fn requestRaw(self: *XmppConnector, id: []const u8, to: ?[]const u8, bytes: []const u8) !xml.ParsedElement {
        const p = try self.allocator.create(PendingIq);
        p.* = .{ .expect_from = if (to) |t| self.allocator.dupe(u8, t) catch {
            self.allocator.destroy(p);
            return error.OutOfMemory;
        } else null };
        const key = self.allocator.dupe(u8, id) catch {
            if (p.expect_from) |f| self.allocator.free(f);
            self.allocator.destroy(p);
            return error.OutOfMemory;
        };
        {
            self.pending_mu.lockUncancelable(self.io);
            defer self.pending_mu.unlock(self.io);
            self.pending_iqs.put(self.allocator, key, p) catch {
                self.allocator.free(key);
                if (p.expect_from) |f| self.allocator.free(f);
                self.allocator.destroy(p);
                return error.OutOfMemory;
            };
        }

        const send_result = self.send(bytes);
        if (send_result) |_| {
            var waited: u64 = 0;
            while (!p.done.load(.acquire) and waited < iq_timeout_ns) : (waited += iq_check_interval_ns) {
                Io.sleep(self.io, .fromNanoseconds(@intCast(iq_check_interval_ns)), .awake) catch break;
            }
        } else |_| {}

        {
            self.pending_mu.lockUncancelable(self.io);
            defer self.pending_mu.unlock(self.io);
            _ = self.pending_iqs.remove(key);
        }
        self.allocator.free(key);
        const result = p.result;
        const was_done = p.done.load(.acquire);
        if (p.expect_from) |f| self.allocator.free(f);
        self.allocator.destroy(p);

        try send_result;
        if (result) |r| return r;
        return if (was_done) error.NotConnected else error.IqTimeout;
    }

    /// Hands an `<iq type='result'/'error'>` to its waiting `request`.
    /// Returns false (caller keeps ownership) when nothing is waiting for it.
    fn resolvePending(self: *XmppConnector, parsed: xml.ParsedElement) bool {
        const id = parsed.element.attr("id") orelse return false;
        self.pending_mu.lockUncancelable(self.io);
        defer self.pending_mu.unlock(self.io);
        const p = self.pending_iqs.get(id) orelse return false;
        if (!self.replyFromMatches(p.expect_from, parsed.element.attr("from"))) {
            log.warn("ignoring iq reply {s} from an unexpected sender", .{id});
            return false;
        }
        _ = self.pending_iqs.remove(id);
        p.result = parsed;
        p.done.store(true, .release);
        return true;
    }

    fn replyFromMatches(self: *XmppConnector, expected: ?[]const u8, from: ?[]const u8) bool {
        const f = from orelse return expected == null;
        if (expected) |e| return std.ascii.eqlIgnoreCase(e, f);
        if (std.ascii.eqlIgnoreCase(f, self.domain)) return true;
        const own = self.bound_jid orelse return false;
        return std.ascii.eqlIgnoreCase(f, own) or std.ascii.eqlIgnoreCase(f, bareJid(own));
    }

    fn failAllPending(self: *XmppConnector) void {
        self.pending_mu.lockUncancelable(self.io);
        defer self.pending_mu.unlock(self.io);
        var it = self.pending_iqs.valueIterator();
        while (it.next()) |p| p.*.done.store(true, .release);
        self.pending_iqs.clearRetainingCapacity();
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
    /// `std.Thread` rather than `Io.concurrent` + `Future.cancel`.
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));

        self.ensureConnected(allocator) catch |err| {
            log.warn("connect failed, retrying in {d}s: {t}", .{ @divTrunc(reconnect_cooldown_ns, std.time.ns_per_s), err });
            Io.sleep(self.io, .fromNanoseconds(@intCast(reconnect_cooldown_ns)), .awake) catch {};
            return &.{};
        };
        const client = self.client.?;
        self.poll_thread.store(std.Thread.getCurrentId(), .release);
        if (self.omemo_publish_due) {
            self.omemo_publish_due = false;
            self.spawnOmemoPublish(true);
        }

        if (self.read_shared == null) {
            const shared = try self.allocator.create(ReadShared);
            shared.* = .{};
            const thread = std.Thread.spawn(.{}, readElementAndFlag, .{ client, self.allocator, shared }) catch |err| {
                self.allocator.destroy(shared);
                return err;
            };
            self.read_shared = shared;
            self.read_thread = thread;
        }
        const shared = self.read_shared.?;

        var waited_ns: u64 = 0;
        while (!shared.done.load(.acquire) and waited_ns < poll_timeout_ns) {
            const step = @min(poll_check_interval_ns, poll_timeout_ns - waited_ns);
            Io.sleep(self.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
            waited_ns += step;
        }

        if (!shared.done.load(.acquire)) {
            // Still nothing this cycle — leave the same read outstanding for the next
            // `pollFn` call, and consider sending a keepalive.
            self.maybeSendKeepalive();
            return &.{};
        }

        self.read_thread.?.join();
        self.read_thread = null;
        self.read_shared = null;
        defer self.allocator.destroy(shared);

        var parsed = shared.result catch |err| {
            log.warn("connection lost ({t}), will reconnect next cycle", .{err});
            self.dropConnection();
            return &.{};
        };
        var handed_off = false;
        defer if (!handed_off) parsed.deinit();
        self.last_activity_unix = Io.Timestamp.now(self.io, .real).toSeconds();

        if (std.mem.eql(u8, parsed.element.name, "presence")) {
            const chat_left = self.handlePresence(allocator, parsed.element) catch |err| blk: {
                log.warn("failed to handle presence: {t}", .{err});
                break :blk null;
            };
            if (chat_left) |m| {
                const out = try allocator.alloc(iface.Message, 1);
                out[0] = m;
                return out;
            }
            return &.{};
        }

        if (std.mem.eql(u8, parsed.element.name, "iq")) {
            const iq_type = parsed.element.attr("type") orelse "";
            if (std.mem.eql(u8, iq_type, "result") or std.mem.eql(u8, iq_type, "error")) {
                handed_off = self.resolvePending(parsed);
                return &.{};
            }
            self.handleIq(allocator, parsed.element) catch |err| {
                log.warn("failed to handle inbound iq: {t}", .{err});
            };
            return &.{};
        }

        return self.messagesFromElement(allocator, parsed.element) catch |err| {
            log.warn("failed to map an inbound message: {t}", .{err});
            return &.{};
        };
    }

    fn maybeSendKeepalive(self: *XmppConnector) void {
        const client = self.client orelse return;
        const now = Io.Timestamp.now(self.io, .real).toSeconds();
        if (now - self.last_activity_unix < keepalive_idle_seconds) return;
        client.sendKeepalive() catch |err| {
            log.warn("keepalive send failed: {t}", .{err});
            return;
        };
        self.last_activity_unix = now;
    }

    /// Features answered to a disco#info query.
    const disco_features = [_][]const u8{
        "http://jabber.org/protocol/disco#info",
        "urn:xmpp:ping",
        stanza.ns_origin_id,
        stanza.ns_correct,
        stanza.ns_reply,
        stanza.ns_oob,
        stanza.ns_retract,
        omemo.devicelist_node,
        omemo.devicelist_node ++ "+notify",
    };

    /// Replies to a server-initiated `<iq type='get'/'set'>` — RFC 6120 §8.2.3
    /// requires every one get *some* reply.
    fn handleIq(self: *XmppConnector, allocator: std.mem.Allocator, el: xml.Element) !void {
        const iq_type = el.attr("type") orelse return;
        if (!std.mem.eql(u8, iq_type, "get") and !std.mem.eql(u8, iq_type, "set")) return;
        const from = el.attr("from") orelse return;
        const id = el.attr("id") orelse return;
        const client = self.client orelse return;

        if (std.mem.eql(u8, iq_type, "get") and el.child("ping") != null) {
            try client.replyIqPing(allocator, from, id);
            return;
        }
        if (std.mem.eql(u8, iq_type, "get")) {
            if (stanza.childNs(el, "query", media.ns_disco_info)) |q| {
                // A query for a caps node we don't publish still gets our features.
                try self.replyDiscoInfo(allocator, from, id, q.attr("node"));
                return;
            }
        }
        try client.replyIqUnsupported(allocator, from, id);
    }

    fn replyDiscoInfo(self: *XmppConnector, allocator: std.mem.Allocator, to: []const u8, id: []const u8, node: ?[]const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<iq type='result' to='");
        try xml.writeEscapedAttr(&out.writer, to);
        try out.writer.writeAll("' id='");
        try xml.writeEscapedAttr(&out.writer, id);
        try out.writer.writeAll("'><query xmlns='" ++ media.ns_disco_info ++ "'");
        if (node) |n| {
            try out.writer.writeAll(" node='");
            try xml.writeEscapedAttr(&out.writer, n);
            try out.writer.writeAll("'");
        }
        try out.writer.writeAll("><identity category='client' type='bot' name='Warden'/>");
        for (disco_features) |f| {
            try out.writer.writeAll("<feature var='");
            try out.writer.writeAll(f);
            try out.writer.writeAll("'/>");
        }
        try out.writer.writeAll("</query></iq>");
        try self.send(out.writer.buffered());
    }

    /// Auto-accepts subscription requests.
    fn handlePresence(self: *XmppConnector, allocator: std.mem.Allocator, el: xml.Element) !?iface.Message {
        const from = el.attr("from") orelse return null;
        const kind = el.attr("type"); // null (no `type` attribute) means "available".
        const room = bareJid(from);

        if (self.isJoinedRoom(room)) {
            self.updateOccupant(from, kind, mucUserExtension(el)) catch |err| {
                log.warn("failed to update occupant state for {s}: {t}", .{ from, err });
            };
        }

        const kind_str = kind orelse return null;

        if (std.mem.eql(u8, kind_str, "subscribe")) {
            const client = self.client orelse return null;
            try client.acceptSubscription(allocator, bareJid(from));
            return null;
        }

        if (std.mem.eql(u8, kind_str, "unavailable")) {
            if (!self.isJoinedRoom(room)) return null;
            const muc_x = mucUserExtension(el) orelse return null;
            const status = muc_x.child("status") orelse return null;
            const code = status.attr("code") orelse return null;
            if (!std.mem.eql(u8, code, "110")) return null;
            return .{
                .chat_id = try allocator.dupe(u8, room),
                .user_id = self.bound_jid orelse "",
                .chat_left = true,
            };
        }

        return null;
    }

    /// Finds the `<x xmlns='http://jabber.org/protocol/muc#user'>` child among
    /// `el`'s children.
    fn mucUserExtension(el: xml.Element) ?xml.Element {
        return stanza.childNs(el, "x", "http://jabber.org/protocol/muc#user");
    }

    /// Updates (or, on `type="unavailable"`, removes) `self.occupants`' entry for
    /// `from` (a full occupant JID).
    fn updateOccupant(self: *XmppConnector, from: []const u8, kind: ?[]const u8, muc_x: ?xml.Element) !void {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        if (kind) |k| {
            if (std.mem.eql(u8, k, "unavailable")) {
                if (self.occupants.fetchRemove(from)) |old| self.freeOccupantEntry(old.key, old.value);
                return;
            }
        }

        const x = muc_x orelse return;
        const item = x.child("item") orelse return;
        const affiliation = item.attr("affiliation") orelse return;
        const role = item.attr("role") orelse return;
        const real_jid = item.attr("jid");

        const new_value = Occupant{
            .affiliation = try self.allocator.dupe(u8, affiliation),
            .role = try self.allocator.dupe(u8, role),
            .real_jid = if (real_jid) |j| try self.allocator.dupe(u8, j) else null,
        };
        errdefer {
            self.allocator.free(new_value.affiliation);
            self.allocator.free(new_value.role);
            if (new_value.real_jid) |j| self.allocator.free(j);
        }

        if (self.occupants.fetchRemove(from)) |old| self.freeOccupantEntry(old.key, old.value);
        const key = try self.allocator.dupe(u8, from);
        errdefer self.allocator.free(key);
        try self.occupants.put(key, new_value);
    }

    /// An occupant of `room`, found either by its occupant JID or by its real
    /// bare JID. Strings are copied into `allocator`.
    const FoundOccupant = struct {
        occupant_jid: []const u8,
        affiliation: []const u8,
        real_jid: ?[]const u8,
    };

    fn findOccupant(self: *XmppConnector, allocator: std.mem.Allocator, room: []const u8, user_id: []const u8) !?FoundOccupant {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        var it = self.occupants.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.eql(u8, bareJid(key), room)) continue;
            const occ = entry.value_ptr.*;
            const by_key = std.mem.eql(u8, key, user_id);
            const by_real = if (occ.real_jid) |j| std.ascii.eqlIgnoreCase(bareJid(j), user_id) else false;
            if (!by_key and !by_real) continue;
            return .{
                .occupant_jid = try allocator.dupe(u8, key),
                .affiliation = try allocator.dupe(u8, occ.affiliation),
                .real_jid = if (occ.real_jid) |j| try allocator.dupe(u8, bareJid(j)) else null,
            };
        }
        return null;
    }

    fn rememberSent(self: *XmppConnector, id: []const u8, chat_id: []const u8) void {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        self.sent_ids.put(self.allocator, id, chat_id);
    }

    fn isOwnId(self: *XmppConnector, id: []const u8) bool {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        return self.sent_ids.get(id) != null;
    }

    fn messagesFromElement(self: *XmppConnector, allocator: std.mem.Allocator, el: xml.Element) ![]iface.Message {
        if (!std.mem.eql(u8, el.name, "message")) return &.{};
        const msg = (try types.MessageStanza.fromElement(allocator, el)) orelse return &.{};
        const ext = stanza.Inbound.read(el);
        if (ext.is_error) return &.{};

        const is_group = std.mem.eql(u8, msg.type, "groupchat");
        // MUC's `from` is `room@server/nick` — `bareJid` of that is exactly the
        // room's own JID, so this one derivation gives the right `chat_id` for both
        // shapes.
        const chat_id = bareJid(msg.from);
        const nick = resourcePart(msg.from);

        if (is_group) {
            // Room subject changes and status messages come from the bare room JID.
            const n = nick orelse return &.{};
            if (std.mem.eql(u8, n, self.resource) or (if (ext.referenceId()) |r| self.isOwnId(r) else false)) {
                self.recordReflection(ext);
                return &.{};
            }
            if (ext.has_delay) return &.{};
        }
        if (ext.replace_id != null) {
            log.debug("ignoring a message correction from {s}", .{msg.from});
            return &.{};
        }

        var real_jid: ?[]const u8 = null;
        if (is_group) {
            if (try self.findOccupant(allocator, chat_id, msg.from)) |occ| real_jid = occ.real_jid;
        }
        const user_id = if (is_group) (real_jid orelse msg.from) else chat_id;
        const sender_domain: ?[]const u8 = if (is_group) (if (real_jid) |j| domainPart(j) else null) else domainPart(chat_id);

        var body: ?[]const u8 = msg.body;
        var oob_url = ext.oob_url;
        if (ext.encrypted) |enc| {
            if (is_group) {
                log.info("ignoring an OMEMO-encrypted message in {s}: rooms aren't supported", .{chat_id});
                return &.{};
            }
            body = (try self.decryptInbound(allocator, chat_id, enc)) orelse return &.{};
            // An OOB element outside the encryption isn't covered by it.
            oob_url = null;
        } else if (!is_group and msg.body != null) {
            self.noteChatEncryption(chat_id, false);
        }

        var text: ?[]const u8 = body;
        var attachment: ?iface.Attachment = null;
        if (oob_url orelse soleUrl(body)) |url| {
            attachment = try self.attachmentFor(allocator, url, sender_domain);
            if (attachment != null) {
                if (body) |b| if (std.mem.eql(u8, std.mem.trim(u8, b, " \t\r\n"), url)) {
                    text = null;
                };
            }
        }
        if ((text == null or text.?.len == 0) and attachment == null) return &.{};
        if (!is_group and self.omemo != null and text != null and isOmemoCommand(text.?)) {
            self.spawnOmemoCommand(chat_id, text.?);
            return &.{};
        }

        const display_name = if (is_group) (nick orelse chat_id) else chat_id;
        // XMPP MUC has no wire-level "@mention" concept (unlike Telegram's
        // entities/Matrix's `m.mentions`).
        const mentions_me = is_group and text != null and mucMentionsMe(text.?, self.resource);

        const message_id: ?[]const u8 = if (is_group and ext.stanza_id != null and
            std.ascii.eqlIgnoreCase(ext.stanza_id_by orelse "", chat_id)) ext.stanza_id else ext.referenceId();

        var reply_to_is_me = false;
        if (ext.reply_to_id) |rid| reply_to_is_me = self.isOwnId(rid);
        if (ext.reply_to_jid) |rj| {
            if (is_group) {
                if (resourcePart(rj)) |rn| reply_to_is_me = reply_to_is_me or std.mem.eql(u8, rn, self.resource);
            } else if (self.bound_jid) |own| {
                reply_to_is_me = reply_to_is_me or std.ascii.eqlIgnoreCase(bareJid(rj), bareJid(own));
            }
        }

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
            .jid_resource = if (is_group) null else nick,
        };

        const out = try allocator.alloc(iface.Message, 1);
        out[0] = .{
            .chat_id = try allocator.dupe(u8, chat_id),
            .message_id = if (message_id) |m| try allocator.dupe(u8, m) else null,
            .user_id = try allocator.dupe(u8, user_id),
            .username = if (is_group) nick else null,
            .text = if (text) |t| try allocator.dupe(u8, t) else null,
            .reply_to_message_id = if (ext.reply_to_id) |r| try allocator.dupe(u8, r) else null,
            .reply_to_user_id = if (ext.reply_to_jid) |r| try allocator.dupe(u8, r) else null,
            .reply_to_is_me = reply_to_is_me,
            .is_group = is_group,
            .chat_type = if (is_group) "muc" else "chat",
            .mentions_me = mentions_me,
            .identity = identity,
            .xmpp_profile = xmpp_profile,
            .attachment = attachment,
        };
        return out;
    }

    /// Our own MUC message came back: remember the stanza-id the room gave
    /// it, which is what a retraction in that room must reference.
    fn recordReflection(self: *XmppConnector, ext: stanza.Inbound) void {
        const origin = ext.referenceId() orelse return;
        const sid = ext.stanza_id orelse return;
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        self.muc_stanza_ids.put(self.allocator, origin, sid);
    }

    /// `body` when it is nothing but one URL — how clients without OOB
    /// support share an uploaded file.
    fn soleUrl(body: ?[]const u8) ?[]const u8 {
        const b = std.mem.trim(u8, body orelse return null, " \t\r\n");
        if (std.mem.indexOfAny(u8, b, " \t\r\n") != null) return null;
        if (media.isHttpsUrl(b) or media.isAesgcmUrl(b)) return b;
        return null;
    }

    /// An attachment for a shared file URL, or null when the URL's host isn't
    /// the sender's own server or ours.
    fn attachmentFor(self: *XmppConnector, allocator: std.mem.Allocator, url: []const u8, sender_domain: ?[]const u8) !?iface.Attachment {
        const plain_http_ok = self.tls_mode == .insecure and std.ascii.startsWithIgnoreCase(url, "http://");
        const aesgcm_ok = self.omemo != null and media.isAesgcmUrl(url);
        if (!media.isHttpsUrl(url) and !plain_http_ok and !aesgcm_ok) return null;
        var host_buf: [256]u8 = undefined;
        const host = media.urlHost(&host_buf, url) orelse return null;
        const allowed = media.hostBelongsTo(host, self.domain) or
            (if (sender_domain) |d| media.hostBelongsTo(host, d) else false);
        if (!allowed) {
            log.info("not treating a file link on {s} as an attachment: not the sender's server", .{host});
            return null;
        }
        const name = media.urlFileName(url) orelse "file";
        return .{
            .kind = media.kindForName(name),
            .file_id = try allocator.dupe(u8, url),
            .file_name = try allocator.dupe(u8, name),
            .mime_type = media.mimeForName(name),
        };
    }

    fn bareJid(full: []const u8) []const u8 {
        const slash = std.mem.indexOfScalar(u8, full, '/') orelse return full;
        return full[0..slash];
    }

    fn resourcePart(full: []const u8) ?[]const u8 {
        const slash = std.mem.indexOfScalar(u8, full, '/') orelse return null;
        return full[slash + 1 ..];
    }

    fn domainPart(jid: []const u8) []const u8 {
        const bare = bareJid(jid);
        const at = std.mem.indexOfScalar(u8, bare, '@') orelse return bare;
        return bare[at + 1 ..];
    }

    /// Word-boundary-aware, case-insensitive scan for the bot's own MUC nickname
    /// anywhere in `body`.
    fn mucMentionsMe(body: []const u8, nick: []const u8) bool {
        if (nick.len == 0) return false;
        var i: usize = 0;
        while (i + nick.len <= body.len) : (i += 1) {
            if (!std.ascii.eqlIgnoreCase(body[i .. i + nick.len], nick)) continue;
            const before_ok = i == 0 or !isNickBoundaryChar(body[i - 1]);
            const after = i + nick.len;
            const after_ok = after >= body.len or !isNickBoundaryChar(body[after]);
            if (before_ok and after_ok) return true;
        }
        return false;
    }

    fn isNickBoundaryChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    const SendOpts = struct {
        body: ?[]const u8 = null,
        replace_id: ?[]const u8 = null,
        reply_to_id: ?[]const u8 = null,
        oob_url: ?[]const u8 = null,
        retract_id: ?[]const u8 = null,
    };

    /// Sends one `<message>` to `chat_id` and returns its id (owned by
    /// `allocator`).
    fn sendOut(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, opts: SendOpts) ![]const u8 {
        const is_group = self.isJoinedRoom(chat_id);
        var encrypted: ?[]u8 = null;
        defer if (encrypted) |e| allocator.free(e);
        if (!is_group and opts.retract_id == null and self.chatIsEncrypted(chat_id)) {
            if (opts.body) |b| {
                encrypted = self.encryptFor(allocator, chat_id, b) catch |err| {
                    log.warn("not sending to {s}: OMEMO encryption failed: {t}", .{ chat_id, err });
                    self.sendPlainNotice(allocator, chat_id, "🔒 I couldn't encrypt my reply to you, so I didn't send it. Make sure your client trusts my OMEMO device.");
                    return error.OmemoEncryptFailed;
                };
            }
        }
        const id = try self.newId(allocator);
        errdefer allocator.free(id);
        const bytes = try stanza.messageToOwned(allocator, .{
            .to = chat_id,
            .kind = if (is_group) "groupchat" else "chat",
            .id = id,
            .body = if (encrypted != null) null else opts.body,
            .replace_id = opts.replace_id,
            // Threading every 1:1 answer under its prompt is just noise.
            .reply_to_id = if (is_group) opts.reply_to_id else null,
            // An OOB link would leak the file's location past the encryption.
            .oob_url = if (encrypted != null) null else opts.oob_url,
            .retract_id = opts.retract_id,
            .encrypted_xml = encrypted,
        });
        defer allocator.free(bytes);
        try self.send(bytes);
        self.rememberSent(id, chat_id);
        return id;
    }

    fn renderText(allocator: std.mem.Allocator, text: []const u8) []const u8 {
        // Same reasoning as the Matrix connector: no rich equivalent here, but the
        // chain-of-thought markers are control bytes and must not reach a client raw.
        return llm.renderThinkingPlain(allocator, text) catch text;
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        const id = self.sendOut(allocator, chat_id, .{ .body = renderText(allocator, text), .reply_to_id = reply_to_message_id }) catch |err| {
            if (err == error.NotConnected) {
                log.warn("dropped message to {s}, not connected: {s}", .{ chat_id, text });
            } else {
                log.warn("failed to send message to {s}: {t}", .{ chat_id, err });
            }
            return;
        };
        allocator.free(id);
    }

    fn sendMessageReturningIdFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) anyerror![]const u8 {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.sendOut(allocator, chat_id, .{ .body = renderText(allocator, text), .reply_to_id = reply_to_message_id });
    }

    /// XEP-0308 correction; `message_id` must be the original message's id,
    /// not an earlier correction's.
    fn editMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8) anyerror!void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        const id = try self.sendOut(allocator, chat_id, .{ .body = renderText(allocator, text), .replace_id = message_id });
        allocator.free(id);
    }

    /// Our own messages are retracted (XEP-0424); someone else's in a room
    /// are moderated (XEP-0425), which needs moderator standing there.
    fn deleteMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        if (self.isOwnId(message_id)) {
            const target = blk: {
                self.state_mu.lockUncancelable(self.io);
                defer self.state_mu.unlock(self.io);
                const sid = self.muc_stanza_ids.get(message_id) orelse break :blk try allocator.dupe(u8, message_id);
                break :blk try allocator.dupe(u8, sid);
            };
            defer allocator.free(target);
            // In a room the retraction must name the room's stanza-id; 1:1
            // retractions name our own origin-id.
            const ref = if (self.isJoinedRoom(chat_id)) target else message_id;
            const id = try self.sendOut(allocator, chat_id, .{ .retract_id = ref });
            allocator.free(id);
            return;
        }
        if (!self.isJoinedRoom(chat_id)) return error.Unsupported;
        try self.moderate(allocator, chat_id, message_id);
    }

    fn moderate(self: *XmppConnector, allocator: std.mem.Allocator, room: []const u8, stanza_id: []const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<moderate xmlns='urn:xmpp:message-moderate:1' id='");
        try xml.writeEscapedAttr(&out.writer, stanza_id);
        try out.writer.writeAll("'><retract xmlns='" ++ stanza.ns_retract ++ "'/></moderate>");
        if (self.request(allocator, "set", room, out.writer.buffered())) |reply| {
            var r = reply;
            r.deinit();
            return;
        } else |err| if (err != error.IqError) return err;

        // Servers that only implement the fastening-based draft.
        out.clearRetainingCapacity();
        try out.writer.writeAll("<apply-to xmlns='" ++ stanza.ns_fasten ++ "' id='");
        try xml.writeEscapedAttr(&out.writer, stanza_id);
        try out.writer.writeAll("'><moderate xmlns='urn:xmpp:message-moderate:0'><retract xmlns='" ++ stanza.ns_retract_legacy ++ "'/></moderate></apply-to>");
        var reply = try self.request(allocator, "set", room, out.writer.buffered());
        reply.deinit();
    }

    // --- OMEMO -------------------------------------------------------------

    /// Turns OMEMO on: loads or creates the bot's device. Call once, before
    /// polling starts.
    pub fn enableOmemo(self: *XmppConnector, pool: *PgPool, secret: []const u8) !void {
        const jid = try std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ self.jid_user, self.domain });
        defer self.allocator.free(jid);
        const engine = try omemo.Engine.init(self.allocator, self.io, pool, secret, jid);
        self.omemo = engine;
        const fp = try engine.fingerprint(self.allocator);
        defer self.allocator.free(fp);
        log.notice("OMEMO device {d}, fingerprint {s}", .{ engine.device_id, fp });
    }

    /// Publishing waits on IQ replies, so it runs off the poll thread.
    fn spawnOmemoPublish(self: *XmppConnector, with_devicelist: bool) void {
        const t = std.Thread.spawn(.{}, publishOmemoThread, .{ self, with_devicelist }) catch |err| {
            log.warn("failed to start OMEMO publishing: {t}", .{err});
            return;
        };
        t.detach();
    }

    fn publishOmemoThread(self: *XmppConnector, with_devicelist: bool) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (with_devicelist) self.publishDeviceList(a) catch |err| log.warn("failed to publish our OMEMO device list: {t}", .{err});
        self.publishBundle(a) catch |err| log.warn("failed to publish our OMEMO bundle: {t}", .{err});
    }

    const ns_pubsub = "http://jabber.org/protocol/pubsub";
    const open_access_options = "<publish-options><x xmlns='jabber:x:data' type='submit'>" ++
        "<field var='FORM_TYPE' type='hidden'><value>http://jabber.org/protocol/pubsub#publish-options</value></field>" ++
        "<field var='pubsub#access_model'><value>open</value></field></x></publish-options>";

    /// Publishes `payload` as item `current` of our own PEP `node`, readable
    /// by anyone (peers fetch our bundle before they've added us).
    fn pepPublish(self: *XmppConnector, a: std.mem.Allocator, node: []const u8, payload: []const u8) !void {
        const with_opts = try std.fmt.allocPrint(a, "<pubsub xmlns='" ++ ns_pubsub ++ "'><publish node='{s}'><item id='current'>{s}</item></publish>" ++ open_access_options ++ "</pubsub>", .{ node, payload });
        if (self.request(a, "set", null, with_opts)) |reply| {
            var r = reply;
            r.deinit();
            return;
        } else |err| if (err != error.IqError) return err;
        // Servers without publish-options support.
        const plain = try std.fmt.allocPrint(a, "<pubsub xmlns='" ++ ns_pubsub ++ "'><publish node='{s}'><item id='current'>{s}</item></publish></pubsub>", .{ node, payload });
        var r = try self.request(a, "set", null, plain);
        r.deinit();
    }

    /// `jid` null means our own account.
    fn fetchDeviceIds(self: *XmppConnector, a: std.mem.Allocator, jid: ?[]const u8) ![]i32 {
        var reply = self.request(a, "get", jid, "<pubsub xmlns='" ++ ns_pubsub ++ "'><items node='" ++ omemo.devicelist_node ++ "'/></pubsub>") catch |err| {
            // No such node: the account has never published an OMEMO device.
            if (err == error.IqError) return &.{};
            return err;
        };
        defer reply.deinit();
        const list = omemo.pubsubPayload(reply.element, "list") orelse return &.{};
        return omemo.parseDeviceList(a, list);
    }

    fn publishDeviceList(self: *XmppConnector, a: std.mem.Allocator) !void {
        const engine = self.omemo orelse return;
        const own: i32 = @intCast(engine.device_id);
        const ids = try self.fetchDeviceIds(a, null);
        for (ids) |id| if (id == own) return;

        var out: Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("<list xmlns='" ++ omemo.ns ++ "'>");
        for (ids) |id| try out.writer.print("<device id='{d}'/>", .{id});
        try out.writer.print("<device id='{d}'/></list>", .{own});
        try self.pepPublish(a, omemo.devicelist_node, out.writer.buffered());
        log.info("added OMEMO device {d} to our device list", .{own});
    }

    fn publishBundle(self: *XmppConnector, a: std.mem.Allocator) !void {
        const engine = self.omemo orelse return;
        const bundle = try engine.bundleXml(a);
        const node = try std.fmt.allocPrint(a, omemo.bundles_node_prefix ++ "{d}", .{engine.device_id});
        try self.pepPublish(a, node, bundle);
        log.info("published OMEMO bundle for device {d}", .{engine.device_id});
    }

    /// A peer's device ids (copied into `a`), from cache when fresh.
    fn peerDevices(self: *XmppConnector, a: std.mem.Allocator, jid: []const u8) ![]i32 {
        const now = Io.Timestamp.now(self.io, .real).toSeconds();
        {
            self.state_mu.lockUncancelable(self.io);
            defer self.state_mu.unlock(self.io);
            if (self.device_cache.get(jid)) |c| {
                if (now - c.fetched_at < device_cache_seconds) return a.dupe(i32, c.ids);
            }
        }
        const ids = try self.fetchDeviceIds(a, jid);
        const owned_ids = try self.allocator.dupe(i32, ids);
        errdefer self.allocator.free(owned_ids);
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        if (self.device_cache.fetchRemove(jid)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.ids);
        }
        const key = try self.allocator.dupe(u8, jid);
        errdefer self.allocator.free(key);
        try self.device_cache.put(self.allocator, key, .{ .ids = owned_ids, .fetched_at = now });
        return ids;
    }

    fn forgetPeerDevices(self: *XmppConnector, jid: []const u8) void {
        self.state_mu.lockUncancelable(self.io);
        defer self.state_mu.unlock(self.io);
        if (self.device_cache.fetchRemove(jid)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.ids);
        }
    }

    /// A message from a device we didn't know about means our cached list
    /// is stale.
    fn noteDeviceSeen(self: *XmppConnector, jid: []const u8, device_id: i32) void {
        const stale = blk: {
            self.state_mu.lockUncancelable(self.io);
            defer self.state_mu.unlock(self.io);
            const c = self.device_cache.get(jid) orelse break :blk false;
            for (c.ids) |id| if (id == device_id) break :blk false;
            break :blk true;
        };
        if (stale) self.forgetPeerDevices(jid);
    }

    fn ensureSession(self: *XmppConnector, a: std.mem.Allocator, engine: *omemo.Engine, jid: []const u8, device_id: i32) !void {
        if (engine.hasSession(jid, device_id)) return;
        const payload = try std.fmt.allocPrint(a, "<pubsub xmlns='" ++ ns_pubsub ++ "'><items node='" ++ omemo.bundles_node_prefix ++ "{d}' max_items='1'/></pubsub>", .{device_id});
        var reply = try self.request(a, "get", jid, payload);
        defer reply.deinit();
        const bundle = omemo.pubsubPayload(reply.element, "bundle") orelse return error.NoBundle;
        try engine.processBundle(jid, device_id, bundle);
    }

    /// The `<encrypted>` element carrying `body` to every device of `jid`.
    fn encryptFor(self: *XmppConnector, allocator: std.mem.Allocator, jid: []const u8, body: []const u8) ![]u8 {
        const engine = self.omemo orelse return error.OmemoOff;
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const ids = try self.peerDevices(a, jid);
            var targets: std.ArrayList(omemo.Target) = .empty;
            for (ids) |id| {
                self.ensureSession(a, engine, jid, id) catch |err| {
                    log.warn("no OMEMO session with {s} device {d}: {t}", .{ jid, id, err });
                    continue;
                };
                try targets.append(a, .{ .jid = jid, .device_id = id });
            }
            return engine.encrypt(allocator, targets.items, body) catch |err| {
                // One retry with a freshly fetched device list.
                if (err == error.NoSessions and attempt == 0) {
                    self.forgetPeerDevices(jid);
                    continue;
                }
                return err;
            };
        }
    }

    /// Decrypts an inbound 1:1 OMEMO message; null when there's nothing to
    /// hand on (key transport, or a failure already reported to the sender).
    fn decryptInbound(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, enc: xml.Element) !?[]const u8 {
        const engine = self.omemo orelse {
            self.sendPlainNotice(allocator, chat_id, "🔒 I can't read OMEMO-encrypted messages on this server. Please turn encryption off for this chat.");
            return null;
        };
        const d = engine.decrypt(allocator, chat_id, enc) catch |err| {
            log.warn("failed to decrypt an OMEMO message from {s}: {t}", .{ chat_id, err });
            const has_payload = enc.child("payload") != null;
            if (err == error.NotEncryptedForThisDevice) {
                if (has_payload) {
                    const notice = std.fmt.allocPrint(allocator, "🔒 That message wasn't encrypted for my device ({d}). Your client may not have my device yet — please trust it and send again.", .{engine.device_id}) catch return null;
                    self.sendPlainNotice(allocator, chat_id, notice);
                }
            } else if (err != error.DuplicateMessage and has_payload) {
                const notice = std.fmt.allocPrint(allocator, "🔒 I couldn't decrypt that message ({t}).", .{err}) catch return null;
                self.sendPlainNotice(allocator, chat_id, notice);
            }
            return null;
        };
        if (engine.takeRepublishNeeded()) self.spawnOmemoPublish(false);
        self.noteDeviceSeen(chat_id, d.sender_device);
        self.noteChatEncryption(chat_id, true);
        return d.plaintext;
    }

    fn isOmemoCommand(text: []const u8) bool {
        const t = std.mem.trim(u8, text, " \t\r\n");
        return std.mem.eql(u8, t, "/omemo") or std.mem.startsWith(u8, t, "/omemo ");
    }

    /// `/omemo` answers may need IQs (device lists), so they run off the
    /// poll thread.
    fn spawnOmemoCommand(self: *XmppConnector, chat_id: []const u8, text: []const u8) void {
        const jid = self.allocator.dupe(u8, chat_id) catch return;
        const args = self.allocator.dupe(u8, std.mem.trim(u8, std.mem.trim(u8, text, " \t\r\n")["/omemo".len..], " \t")) catch {
            self.allocator.free(jid);
            return;
        };
        const t = std.Thread.spawn(.{}, omemoCommandThread, .{ self, jid, args }) catch {
            self.allocator.free(jid);
            self.allocator.free(args);
            return;
        };
        t.detach();
    }

    fn omemoCommandThread(self: *XmppConnector, jid: []u8, args: []u8) void {
        defer self.allocator.free(jid);
        defer self.allocator.free(args);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const reply = self.omemoCommandReply(a, jid, args) catch |err| std.fmt.allocPrint(a, "/omemo failed: {t}", .{err}) catch return;
        const id = self.sendOut(a, jid, .{ .body = reply }) catch return;
        _ = id;
    }

    /// `/omemo` shows our fingerprint and the sender's devices;
    /// `/omemo reset <device id>` forgets one of the sender's devices so a
    /// reinstalled client's new key is accepted.
    fn omemoCommandReply(self: *XmppConnector, a: std.mem.Allocator, jid: []const u8, args: []const u8) ![]const u8 {
        const engine = self.omemo orelse return error.OmemoOff;
        if (std.mem.startsWith(u8, args, "reset")) {
            const id_text = std.mem.trim(u8, args["reset".len..], " \t");
            const device_id = std.fmt.parseInt(i32, id_text, 10) catch return "Usage: /omemo reset <device id>";
            try omemo_store.resetDevice(engine.pool, engine.own_jid, jid, device_id);
            self.forgetPeerDevices(jid);
            return std.fmt.allocPrint(a, "Forgot your device {d}. Its key will be trusted again the next time it writes to me.", .{device_id});
        }
        if (args.len > 0) return "Usage: /omemo, or /omemo reset <device id>";

        var out: Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.print("My OMEMO device: {d}\nFingerprint: {s}\n\nYour devices:", .{ engine.device_id, try engine.fingerprint(a) });
        const known = try omemo_store.listIdentities(engine.pool, a, engine.own_jid, jid);
        self.forgetPeerDevices(jid);
        const published = self.peerDevices(a, jid) catch &.{};
        for (published) |id| {
            const fp: []const u8 = for (known) |k| {
                if (k.device_id == id) break try omemo.Engine.formatFingerprint(a, try omemo.decodeB64(a, k.identity_key));
            } else "(not seen yet)";
            try w.print("\n• {d}: {s}", .{ id, fp });
        }
        if (published.len == 0) try w.writeAll("\n(none published)");
        return out.toOwnedSlice();
    }

    fn chatIsEncrypted(self: *XmppConnector, jid: []const u8) bool {
        const engine = self.omemo orelse return false;
        return omemo_store.isChatEncrypted(engine.pool, engine.own_jid, jid) catch false;
    }

    /// Mirrors the peer: encrypted when their last message was.
    fn noteChatEncryption(self: *XmppConnector, jid: []const u8, encrypted: bool) void {
        const engine = self.omemo orelse return;
        if (self.chatIsEncrypted(jid) == encrypted) return;
        omemo_store.setChatEncrypted(engine.pool, engine.own_jid, jid, encrypted) catch |err| {
            log.warn("failed to record OMEMO state for {s}: {t}", .{ jid, err });
            return;
        };
        log.info("{s} is now {s}", .{ jid, if (encrypted) "OMEMO-encrypted" else "plaintext" });
    }

    /// An unencrypted 1:1 notice that never goes through OMEMO (safe from
    /// the poll thread).
    fn sendPlainNotice(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8) void {
        const id = self.newId(allocator) catch return;
        defer allocator.free(id);
        const bytes = stanza.messageToOwned(allocator, .{ .to = chat_id, .kind = "chat", .id = id, .body = text }) catch return;
        defer allocator.free(bytes);
        self.send(bytes) catch |err| log.warn("failed to send a notice to {s}: {t}", .{ chat_id, err });
    }

    /// XEP-0454: AES-256-GCM over the file, key and IV in the URL fragment.
    fn uploadEncrypted(self: *XmppConnector, allocator: std.mem.Allocator, bytes: []const u8, file_name: []const u8) ![]const u8 {
        var key: [32]u8 = undefined;
        var iv: [12]u8 = undefined;
        self.io.random(&key);
        self.io.random(&iv);
        defer std.crypto.secureZero(u8, &key);
        const sealed = try allocator.alloc(u8, bytes.len + 16);
        defer allocator.free(sealed);
        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(sealed[0..bytes.len], sealed[bytes.len..][0..16], bytes, "", iv, key);
        const url = try self.upload(allocator, sealed, file_name, "application/octet-stream");
        defer allocator.free(url);
        const rest = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else return error.MalformedUploadSlot;
        const iv_hex = std.fmt.bytesToHex(iv, .lower);
        const key_hex = std.fmt.bytesToHex(key, .lower);
        return std.fmt.allocPrint(allocator, "aesgcm://{s}#{s}{s}", .{ rest, &iv_hex, &key_hex });
    }

    fn downloadEncrypted(self: *XmppConnector, allocator: std.mem.Allocator, url: []const u8) ![]u8 {
        const hash = std.mem.lastIndexOfScalar(u8, url, '#') orelse return error.MalformedAesgcmUrl;
        const frag = url[hash + 1 ..];
        // 12-byte IV + 32-byte key; the 16-byte-IV legacy form isn't GCM-standard.
        if (frag.len != 88) return error.UnsupportedAesgcmUrl;
        var iv: [12]u8 = undefined;
        var key: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&iv, frag[0..24]) catch return error.MalformedAesgcmUrl;
        _ = std.fmt.hexToBytes(&key, frag[24..88]) catch return error.MalformedAesgcmUrl;
        defer std.crypto.secureZero(u8, &key);
        const rest = url["aesgcm://".len..hash];

        // aesgcm:// stands for https://; only the insecure (test) mode also
        // reaches plain-HTTP upload services.
        const https_url = try std.fmt.allocPrint(allocator, "https://{s}", .{rest});
        defer allocator.free(https_url);
        const data = if (self.tls_mode == .insecure) blk: {
            const http_url = try std.fmt.allocPrint(allocator, "http://{s}", .{rest});
            defer allocator.free(http_url);
            break :blk http_util.get(&self.http_client, allocator, http_url) catch
                try http_util.get(&self.http_client, allocator, https_url);
        } else try http_util.get(&self.http_client, allocator, https_url);
        defer allocator.free(data);
        if (data.len < 16) return error.MalformedEncryptedFile;
        const n = data.len - 16;
        const out = try allocator.alloc(u8, n);
        errdefer allocator.free(out);
        std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, data[0..n], data[n..][0..16].*, "", iv, key) catch return error.FileAuthenticationFailed;
        return out;
    }

    fn resetUploadService(self: *XmppConnector) void {
        self.upload_mu.lockUncancelable(self.io);
        defer self.upload_mu.unlock(self.io);
        if (self.upload_jid) |j| self.allocator.free(j);
        self.upload_jid = null;
        self.upload_max_size = null;
    }

    /// Finds the server's HTTP File Upload component (disco#items on our
    /// domain, then disco#info on each item). Cached per connection.
    fn uploadServiceJid(self: *XmppConnector, allocator: std.mem.Allocator) ![]const u8 {
        self.upload_mu.lockUncancelable(self.io);
        defer self.upload_mu.unlock(self.io);
        if (self.upload_jid) |j| return allocator.dupe(u8, j);

        var candidates: std.ArrayList([]const u8) = .empty;
        defer candidates.deinit(allocator);
        try candidates.append(allocator, self.domain);
        var items_reply = try self.request(allocator, "get", self.domain, "<query xmlns='" ++ media.ns_disco_items ++ "'/>");
        defer items_reply.deinit();
        const items = try media.discoItems(allocator, items_reply.element);
        defer allocator.free(items);
        try candidates.appendSlice(allocator, items);

        for (candidates.items) |jid| {
            var info = self.request(allocator, "get", jid, "<query xmlns='" ++ media.ns_disco_info ++ "'/>") catch continue;
            defer info.deinit();
            const svc = media.uploadServiceFromInfo(info.element) orelse continue;
            self.upload_jid = try self.allocator.dupe(u8, jid);
            self.upload_max_size = svc.max_file_size;
            log.info("using HTTP upload service {s}", .{jid});
            return allocator.dupe(u8, jid);
        }
        return error.NoUploadService;
    }

    /// Uploads `bytes` (XEP-0363) and returns the public GET URL.
    fn upload(self: *XmppConnector, allocator: std.mem.Allocator, bytes: []const u8, file_name: []const u8, content_type: []const u8) ![]const u8 {
        const service = try self.uploadServiceJid(allocator);
        defer allocator.free(service);
        if (self.upload_max_size) |max| if (bytes.len > max) return error.FileTooLarge;

        const safe_name = try media.sanitizeFileName(allocator, file_name);
        defer allocator.free(safe_name);

        var req: Io.Writer.Allocating = .init(allocator);
        defer req.deinit();
        try req.writer.writeAll("<request xmlns='" ++ media.ns_upload ++ "' filename='");
        try xml.writeEscapedAttr(&req.writer, safe_name);
        try req.writer.print("' size='{d}' content-type='", .{bytes.len});
        try xml.writeEscapedAttr(&req.writer, content_type);
        try req.writer.writeAll("'/>");

        var reply = try self.request(allocator, "get", service, req.writer.buffered());
        defer reply.deinit();
        const slot = media.parseSlot(reply.element) orelse return error.MalformedUploadSlot;
        if (!media.isHttpsUrl(slot.put_url) and self.tls_mode != .insecure) return error.InsecureUploadSlot;

        var headers: [3]http.Header = undefined;
        var n: usize = 0;
        if (slot.authorization) |v| {
            headers[n] = .{ .name = "Authorization", .value = v };
            n += 1;
        }
        if (slot.cookie) |v| {
            headers[n] = .{ .name = "Cookie", .value = v };
            n += 1;
        }
        if (slot.expires) |v| {
            headers[n] = .{ .name = "Expires", .value = v };
            n += 1;
        }
        const body = try http_util.putRaw(&self.http_client, allocator, slot.put_url, content_type, headers[0..n], bytes);
        allocator.free(body);
        return allocator.dupe(u8, slot.get_url);
    }

    /// Uploads a file and shares its link, then the caption as its own
    /// message. Failures are reported in the chat, since the caller can't.
    fn shareFile(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, bytes: []const u8, file_name: []const u8, content_type: []const u8, caption: ?[]const u8) void {
        const encrypt = !self.isJoinedRoom(chat_id) and self.chatIsEncrypted(chat_id);
        const url = (if (encrypt) self.uploadEncrypted(allocator, bytes, file_name) else self.upload(allocator, bytes, file_name, content_type)) catch |err| {
            log.warn("failed to upload {s} ({d} bytes) for {s}: {t}", .{ file_name, bytes.len, chat_id, err });
            const notice = std.fmt.allocPrint(allocator, "⚠️ Couldn't send {s}: {t}", .{ file_name, err }) catch return;
            defer allocator.free(notice);
            sendMessageFn(self, allocator, chat_id, notice, null);
            return;
        };
        defer allocator.free(url);
        const id = self.sendOut(allocator, chat_id, .{ .body = url, .oob_url = url }) catch |err| {
            log.warn("failed to share an uploaded file with {s}: {t}", .{ chat_id, err });
            return;
        };
        allocator.free(id);
        if (caption) |c| if (c.len > 0) sendMessageFn(self, allocator, chat_id, c, null);
    }

    fn imageFileName(bytes: []const u8) struct { name: []const u8, mime: []const u8 } {
        if (std.mem.startsWith(u8, bytes, "\x89PNG")) return .{ .name = "image.png", .mime = "image/png" };
        if (std.mem.startsWith(u8, bytes, "\xff\xd8")) return .{ .name = "image.jpg", .mime = "image/jpeg" };
        if (std.mem.startsWith(u8, bytes, "GIF8")) return .{ .name = "image.gif", .mime = "image/gif" };
        if (bytes.len >= 12 and std.mem.eql(u8, bytes[8..12], "WEBP")) return .{ .name = "image.webp", .mime = "image/webp" };
        return .{ .name = "image.png", .mime = "image/png" };
    }

    fn sendPhotoFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, image_bytes: []const u8, caption: ?[]const u8) void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        const info = imageFileName(image_bytes);
        self.shareFile(allocator, chat_id, image_bytes, info.name, info.mime, caption);
    }

    fn sendDocumentFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, file_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        self.shareFile(allocator, chat_id, file_bytes, file_name, media.mimeForName(file_name), caption);
    }

    fn sendVideoFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, video_bytes: []const u8, file_name: []const u8, caption: ?[]const u8) void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        self.shareFile(allocator, chat_id, video_bytes, file_name, media.mimeForName(file_name), caption);
    }

    /// `file_id` is the shared URL (see `attachmentFor`).
    fn downloadFileFn(ptr: *anyopaque, allocator: std.mem.Allocator, file_id: []const u8) anyerror![]u8 {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        if (media.isAesgcmUrl(file_id)) return self.downloadEncrypted(allocator, file_id);
        const plain_http_ok = self.tls_mode == .insecure and std.ascii.startsWithIgnoreCase(file_id, "http://");
        if (!media.isHttpsUrl(file_id) and !plain_http_ok) return error.UnsupportedUrl;
        return http_util.get(&self.http_client, allocator, file_id);
    }

    /// The occupant nickname a MUC role change addresses, from either an
    /// occupant JID or a real JID.
    fn occupantNick(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, user_id, chat_id) and user_id.len > chat_id.len and user_id[chat_id.len] == '/') {
            return allocator.dupe(u8, user_id[chat_id.len + 1 ..]);
        }
        const occ = (try self.findOccupant(allocator, chat_id, user_id)) orelse return error.NotMucOccupant;
        return allocator.dupe(u8, resourcePart(occ.occupant_jid) orelse return error.NotMucOccupant);
    }

    /// Shared body for `muteUserFn`/`unmuteUserFn`/`kickUserFn` — all three are
    /// XEP-0045 role changes, addressed by nickname.
    fn setRole(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, role: []const u8) !void {
        if (self.client == null) return error.NotConnected;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const nick = try self.occupantNick(arena.allocator(), chat_id, user_id);
        self.client_mu.lockUncancelable(self.io);
        defer self.client_mu.unlock(self.io);
        const client = self.client orelse return error.NotConnected;
        try client.setMucRole(allocator, chat_id, nick, role);
    }

    /// Shared body for `banUserFn`/`promoteUserFn`/`demoteUserFn` — all three are
    /// XEP-0045 affiliation changes, addressed by the occupant's real bare JID.
    fn setAffiliation(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, affiliation: []const u8) !void {
        if (self.client == null) return error.NotConnected;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const real_jid = blk: {
            if (try self.findOccupant(arena.allocator(), chat_id, user_id)) |occ| {
                break :blk occ.real_jid orelse return error.RealJidUnknown;
            }
            // Not an occupant: a bare real JID can still be banned/granted.
            if (std.mem.indexOfScalar(u8, user_id, '/') == null and std.mem.indexOfScalar(u8, user_id, '@') != null) break :blk user_id;
            return error.UnknownOccupant;
        };
        self.client_mu.lockUncancelable(self.io);
        defer self.client_mu.unlock(self.io);
        const client = self.client orelse return error.NotConnected;
        try client.setMucAffiliation(allocator, chat_id, real_jid, affiliation);
    }

    fn muteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, until_unix_time: i64) anyerror!void {
        _ = until_unix_time; // XEP-0045 roles have no expiry -- same note as Matrix's muteUserFn.
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.setRole(allocator, chat_id, user_id, "visitor");
    }

    fn unmuteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.setRole(allocator, chat_id, user_id, "participant");
    }

    fn kickUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.setRole(allocator, chat_id, user_id, "none");
    }

    fn banUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.setAffiliation(allocator, chat_id, user_id, "outcast");
    }

    fn promoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.setAffiliation(allocator, chat_id, user_id, "admin");
    }

    fn demoteUserFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!void {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        return self.setAffiliation(allocator, chat_id, user_id, "member");
    }

    /// Reads `self.occupants` — no I/O.
    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const occ = (try self.findOccupant(arena.allocator(), chat_id, user_id)) orelse return false;
        return std.mem.eql(u8, occ.affiliation, "owner") or std.mem.eql(u8, occ.affiliation, "admin");
    }
};

const testing = std.testing;

fn testConnector() XmppConnector {
    return XmppConnector.init(testing.allocator, testing.io, "localhost", 5222, "localhost", "warden", "secret", &.{}, .self_signed);
}

test "bareJid strips a resource, resourcePart extracts it" {
    try testing.expectEqualStrings("room@conference.example.org", XmppConnector.bareJid("room@conference.example.org/nick"));
    try testing.expectEqualStrings("alice@example.org", XmppConnector.bareJid("alice@example.org"));
    try testing.expectEqualStrings("nick", XmppConnector.resourcePart("room@conference.example.org/nick").?);
    try testing.expectEqual(@as(?[]const u8, null), XmppConnector.resourcePart("alice@example.org"));
}

test "mucMentionsMe matches a bare or @-prefixed nick at a word boundary, case-insensitively" {
    try testing.expect(XmppConnector.mucMentionsMe("hey @Warden can you help", "warden"));
    try testing.expect(XmppConnector.mucMentionsMe("warden: what's up", "warden"));
    try testing.expect(!XmppConnector.mucMentionsMe("wardenship is a word", "warden"));
    try testing.expect(!XmppConnector.mucMentionsMe("no mention here", "warden"));
    try testing.expect(!XmppConnector.mucMentionsMe("anything", ""));
}

test "XmppConnector reports its platform" {
    var conn = testConnector();
    defer conn.deinit();
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.xmpp, c.platform());
}

test "XmppConnector reports Unsupported for actions with no XMPP MUC primitive" {
    var conn = testConnector();
    defer conn.deinit();
    const c = conn.connector();
    try testing.expectError(error.Unsupported, c.restrictChatMemberPermissions(testing.allocator, "1", "2", 0, 0));
    try testing.expectError(error.Unsupported, c.setChatAdminTitle(testing.allocator, "1", "2", "title"));
}

test "XmppConnector.sendMessage drops the message and logs when not connected" {
    var conn = testConnector();
    defer conn.deinit();
    const c = conn.connector();
    // Not connected (no live server dialed) — must not crash, just drop.
    c.sendMessage(testing.allocator, "alice@example.org", "hi", null);
}

test "kickUser/muteUser/banUser/promoteUser fail with NotConnected rather than crashing when no client is live" {
    var conn = testConnector();
    defer conn.deinit();
    const c = conn.connector();
    try testing.expectError(error.NotConnected, c.kickUser(testing.allocator, "room@conf.example.org", "room@conf.example.org/alice"));
    try testing.expectError(error.NotConnected, c.muteUser(testing.allocator, "room@conf.example.org", "room@conf.example.org/alice", 0));
    try testing.expectError(error.NotConnected, c.banUser(testing.allocator, "room@conf.example.org", "room@conf.example.org/alice"));
    try testing.expectError(error.NotConnected, c.promoteUser(testing.allocator, "room@conf.example.org", "room@conf.example.org/alice"));
}

test "isGroupAdmin reads tracked occupant affiliation, defaults to false when unknown" {
    var conn = testConnector();
    defer conn.deinit();
    const c = conn.connector();

    try testing.expectEqual(false, try c.isGroupAdmin(testing.allocator, "room@conf.example.org", "room@conf.example.org/alice"));

    try conn.occupants.put(
        try testing.allocator.dupe(u8, "room@conf.example.org/alice"),
        .{ .affiliation = try testing.allocator.dupe(u8, "admin"), .role = try testing.allocator.dupe(u8, "moderator"), .real_jid = null },
    );
    try conn.occupants.put(
        try testing.allocator.dupe(u8, "room@conf.example.org/bob"),
        .{ .affiliation = try testing.allocator.dupe(u8, "member"), .role = try testing.allocator.dupe(u8, "participant"), .real_jid = null },
    );

    try testing.expectEqual(true, try c.isGroupAdmin(testing.allocator, "room@conf.example.org", "room@conf.example.org/alice"));
    try testing.expectEqual(false, try c.isGroupAdmin(testing.allocator, "room@conf.example.org", "room@conf.example.org/bob"));
}

test "banUser fails with RealJidUnknown for a tracked occupant whose real JID was never disclosed" {
    var conn = testConnector();
    defer conn.deinit();
    conn.client = @ptrFromInt(@as(usize, 0x10)); // Non-null sentinel: setAffiliation only checks `orelse`, never dereferences it before failing on the occupant lookup.
    defer conn.client = null; // Never a real Client -- deinit must not try to close() it.

    try conn.occupants.put(
        try testing.allocator.dupe(u8, "room@conf.example.org/alice"),
        .{ .affiliation = try testing.allocator.dupe(u8, "member"), .role = try testing.allocator.dupe(u8, "participant"), .real_jid = null },
    );

    const c = conn.connector();
    try testing.expectError(error.RealJidUnknown, c.banUser(testing.allocator, "room@conf.example.org", "room@conf.example.org/alice"));
    try testing.expectError(error.UnknownOccupant, c.banUser(testing.allocator, "room@conf.example.org", "room@conf.example.org/carol"));
}

/// Each branch is one self-contained inline literal tree (rather than
/// building attrs up imperatively in a local `var`) so the whole `Element`
/// tree's storage rides `return`'s result-location semantics all the way out
/// to the caller — same shape as `statusCode110Presence` below.
fn availableMucPresence(from: []const u8, affiliation: []const u8, role: []const u8, real_jid: ?[]const u8) xml.Element {
    if (real_jid) |j| return .{
        .name = "presence",
        .attrs = &.{.{ .name = "from", .value = from }},
        .children = &.{.{ .element = .{
            .name = "x",
            .attrs = &.{.{ .name = "xmlns", .value = "http://jabber.org/protocol/muc#user" }},
            .children = &.{.{ .element = .{
                .name = "item",
                .attrs = &.{ .{ .name = "affiliation", .value = affiliation }, .{ .name = "role", .value = role }, .{ .name = "jid", .value = j } },
                .children = &.{},
            } }},
        } }},
    };
    return .{
        .name = "presence",
        .attrs = &.{.{ .name = "from", .value = from }},
        .children = &.{.{ .element = .{
            .name = "x",
            .attrs = &.{.{ .name = "xmlns", .value = "http://jabber.org/protocol/muc#user" }},
            .children = &.{.{ .element = .{
                .name = "item",
                .attrs = &.{ .{ .name = "affiliation", .value = affiliation }, .{ .name = "role", .value = role } },
                .children = &.{},
            } }},
        } }},
    };
}

fn unavailableMucPresence(from: []const u8) xml.Element {
    return .{
        .name = "presence",
        .attrs = &.{ .{ .name = "from", .value = from }, .{ .name = "type", .value = "unavailable" } },
        .children = &.{.{ .element = .{
            .name = "x",
            .attrs = &.{.{ .name = "xmlns", .value = "http://jabber.org/protocol/muc#user" }},
            .children = &.{},
        } }},
    };
}

test "handlePresence tracks occupant affiliation/role/jid from available presence in a joined room" {
    var conn = testConnector();
    defer conn.deinit();
    try conn.joined_rooms.append(testing.allocator, try testing.allocator.dupe(u8, "room@conference.example.org"));

    const el = availableMucPresence("room@conference.example.org/alice", "admin", "moderator", "alice@example.org");
    try testing.expectEqual(@as(?iface.Message, null), try conn.handlePresence(testing.allocator, el));

    const occ = conn.occupants.get("room@conference.example.org/alice").?;
    try testing.expectEqualStrings("admin", occ.affiliation);
    try testing.expectEqualStrings("moderator", occ.role);
    try testing.expectEqualStrings("alice@example.org", occ.real_jid.?);
}

test "handlePresence ignores occupant presence for a room we haven't joined" {
    var conn = testConnector();
    defer conn.deinit();

    const el = availableMucPresence("someother@conference.example.org/alice", "admin", "moderator", "alice@example.org");
    try testing.expectEqual(@as(?iface.Message, null), try conn.handlePresence(testing.allocator, el));
    try testing.expectEqual(@as(usize, 0), conn.occupants.count());
}

test "handlePresence clears tracked occupant state on unavailable (departure)" {
    var conn = testConnector();
    defer conn.deinit();
    try conn.joined_rooms.append(testing.allocator, try testing.allocator.dupe(u8, "room@conference.example.org"));
    try conn.occupants.put(
        try testing.allocator.dupe(u8, "room@conference.example.org/alice"),
        .{ .affiliation = try testing.allocator.dupe(u8, "member"), .role = try testing.allocator.dupe(u8, "participant"), .real_jid = null },
    );

    const el = unavailableMucPresence("room@conference.example.org/alice");
    _ = try conn.handlePresence(testing.allocator, el);
    try testing.expectEqual(@as(?XmppConnector.Occupant, null), conn.occupants.get("room@conference.example.org/alice"));
}

test "handlePresence reports chat_left for a joined room's self-presence (status code 110) unavailable" {
    var conn = testConnector();
    defer conn.deinit(); // frees every joined_rooms entry itself -- don't also free conn.joined_rooms.items[0] here.
    try conn.joined_rooms.append(testing.allocator, try testing.allocator.dupe(u8, "room@conference.example.org"));

    const el = statusCode110Presence("room@conference.example.org/warden");
    const m = (try conn.handlePresence(testing.allocator, el)).?;
    defer testing.allocator.free(m.chat_id);
    try testing.expect(m.chat_left);
    try testing.expectEqualStrings("room@conference.example.org", m.chat_id);
}

fn statusCode110Presence(from: []const u8) xml.Element {
    return .{
        .name = "presence",
        .attrs = &.{ .{ .name = "from", .value = from }, .{ .name = "type", .value = "unavailable" } },
        .children = &.{.{ .element = .{
            .name = "x",
            .attrs = &.{.{ .name = "xmlns", .value = "http://jabber.org/protocol/muc#user" }},
            .children = &.{.{ .element = .{
                .name = "status",
                .attrs = &.{.{ .name = "code", .value = "110" }},
                .children = &.{},
            } }},
        } }},
    };
}

test "handlePresence ignores unavailable presence for a room we never joined" {
    var conn = testConnector();
    defer conn.deinit();

    const el = statusCode110Presence("someother@conference.example.org/warden");
    try testing.expectEqual(@as(?iface.Message, null), try conn.handlePresence(testing.allocator, el));
}

// Full connect -> TLS `self_signed` verification -> MUC join -> real server
// presence round trip.
test "XmppConnector.ensureConnected connects with self_signed TLS, joins a MUC room, and tracks its own occupant presence" {
    const host_z = std.c.getenv("WARDEN_TEST_XMPP_HOST") orelse return error.SkipZigTest;
    const port: u16 = if (std.c.getenv("WARDEN_TEST_XMPP_PORT")) |p| try std.fmt.parseInt(u16, std.mem.span(p), 10) else 5222;
    const domain = if (std.c.getenv("WARDEN_TEST_XMPP_DOMAIN")) |d| std.mem.span(d) else "localhost";
    const user = if (std.c.getenv("WARDEN_TEST_XMPP_USER")) |u| std.mem.span(u) else "test";
    const password = if (std.c.getenv("WARDEN_TEST_XMPP_PASSWORD")) |p| std.mem.span(p) else "testpass123";
    const room = if (std.c.getenv("WARDEN_TEST_XMPP_MUC_ROOM")) |r| std.mem.span(r) else "wardentest@conference.localhost";

    var conn = XmppConnector.init(testing.allocator, testing.io, std.mem.span(host_z), port, domain, user, password, &.{room}, .self_signed);
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try conn.ensureConnected(arena.allocator());
    try testing.expect(conn.bound_jid != null);
    try testing.expectEqual(@as(usize, 1), conn.joined_rooms.items.len);

    const client = conn.client.?;
    const self_occupant_jid = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ room, conn.resource });

    var found_self_presence = false;
    var attempts: usize = 0;
    while (!found_self_presence and attempts < 10) : (attempts += 1) {
        var parsed = try client.readElement(arena.allocator());
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.element.name, "presence")) continue;
        _ = try conn.handlePresence(arena.allocator(), parsed.element);
        if (conn.occupants.contains(self_occupant_jid)) found_self_presence = true;
    }
    try testing.expect(found_self_presence);

    // A freshly (or previously, MAM-persisted) self-created room makes its
    // creator the owner.
    const occupant = conn.occupants.get(self_occupant_jid).?;
    try testing.expect(std.mem.eql(u8, occupant.affiliation, "owner") or std.mem.eql(u8, occupant.affiliation, "admin"));
}

// Regression: an idle poll used to tear the connection down every cycle.
test "XmppConnector.poll keeps the same connection alive across multiple idle poll_timeout cycles" {
    const host_z = std.c.getenv("WARDEN_TEST_XMPP_HOST") orelse return error.SkipZigTest;
    const port: u16 = if (std.c.getenv("WARDEN_TEST_XMPP_PORT")) |p| try std.fmt.parseInt(u16, std.mem.span(p), 10) else 5222;
    const domain = if (std.c.getenv("WARDEN_TEST_XMPP_DOMAIN")) |d| std.mem.span(d) else "localhost";
    const user = if (std.c.getenv("WARDEN_TEST_XMPP_USER")) |u| std.mem.span(u) else "test";
    const password = if (std.c.getenv("WARDEN_TEST_XMPP_PASSWORD")) |p| std.mem.span(p) else "testpass123";

    // `page_allocator`, not `testing.allocator`, for the connector itself.
    var conn = XmppConnector.init(std.heap.page_allocator, testing.io, std.mem.span(host_z), port, domain, user, password, &.{}, .self_signed);
    defer conn.deinit();
    const c = conn.connector();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = try c.poll(arena.allocator());
    _ = arena.reset(.retain_capacity);
    const first_client = conn.client.?;
    const first_bound_jid = conn.bound_jid.?;

    var i: usize = 0;
    while (i < 2) : (i += 1) {
        _ = try c.poll(arena.allocator());
        _ = arena.reset(.retain_capacity);
    }

    try testing.expectEqual(first_client, conn.client.?);
    try testing.expectEqualStrings(first_bound_jid, conn.bound_jid.?);
}

test "handlePresence ignores an ordinary subscribe presence (no self-leave reported)" {
    var conn = testConnector();
    defer conn.deinit();

    const el = xml.Element{
        .name = "presence",
        .attrs = &.{ .{ .name = "from", .value = "alice@example.org" }, .{ .name = "type", .value = "subscribe" } },
        .children = &.{},
    };
    // Not connected -- acceptSubscription is a no-op via the `self.client
    // orelse return null` early-out, so this must not crash either.
    try testing.expectEqual(@as(?iface.Message, null), try conn.handlePresence(testing.allocator, el));
}

fn parseOwned(text: []const u8) !xml.ParsedElement {
    return xml.parseElement(testing.allocator, text);
}

test "RecentMap overwrites its oldest entry once full" {
    var m: RecentMap = .{};
    defer m.deinit(testing.allocator);
    var buf: [16]u8 = undefined;
    for (0..recent_capacity + 1) |i| {
        const k = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        m.put(testing.allocator, k, "v");
    }
    try testing.expectEqual(@as(?[]const u8, null), m.get("k0"));
    try testing.expectEqualStrings("v", m.get("k1").?);
}

test "messagesFromElement drops our own MUC reflection and records its stanza-id" {
    var conn = testConnector();
    defer conn.deinit();
    try conn.joined_rooms.append(testing.allocator, try testing.allocator.dupe(u8, "room@conf.example.org"));
    conn.rememberSent("w1", "room@conf.example.org");

    var parsed = try parseOwned("<message from='room@conf.example.org/warden' type='groupchat' id='w1'><body>hi</body><origin-id xmlns='urn:xmpp:sid:0' id='w1'/><stanza-id xmlns='urn:xmpp:sid:0' id='S9' by='room@conf.example.org'/></message>");
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try conn.messagesFromElement(arena.allocator(), parsed.element);
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expectEqualStrings("S9", conn.muc_stanza_ids.get("w1").?);
}

test "messagesFromElement uses the occupant's real JID as the MUC sender and the room stanza-id as message id" {
    var conn = testConnector();
    defer conn.deinit();
    try conn.joined_rooms.append(testing.allocator, try testing.allocator.dupe(u8, "room@conf.example.org"));
    _ = try conn.handlePresence(testing.allocator, availableMucPresence("room@conf.example.org/alice", "member", "participant", "alice@example.org/phone"));
    conn.rememberSent("w7", "room@conf.example.org");

    var parsed = try parseOwned("<message from='room@conf.example.org/alice' type='groupchat' id='a1'><body>warden: hello</body><stanza-id xmlns='urn:xmpp:sid:0' id='S1' by='room@conf.example.org'/><reply xmlns='urn:xmpp:reply:0' id='w7'/></message>");
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try conn.messagesFromElement(arena.allocator(), parsed.element);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("alice@example.org", out[0].user_id);
    try testing.expectEqualStrings("alice", out[0].username.?);
    try testing.expectEqualStrings("S1", out[0].message_id.?);
    try testing.expect(out[0].mentions_me);
    try testing.expect(out[0].reply_to_is_me);
    try testing.expect(out[0].is_group);
}

test "messagesFromElement turns a shared upload link into an attachment, and ignores corrections" {
    var conn = testConnector();
    defer conn.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var parsed = try parseOwned("<message from='alice@example.org/phone' type='chat' id='m1'><body>https://upload.example.org/abc/rec.m4a</body><x xmlns='jabber:x:oob'><url>https://upload.example.org/abc/rec.m4a</url></x></message>");
    defer parsed.deinit();
    const out = try conn.messagesFromElement(arena.allocator(), parsed.element);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(?[]const u8, null), out[0].text);
    const att = out[0].attachment.?;
    try testing.expectEqual(iface.AttachmentKind.voice, att.kind);
    try testing.expectEqualStrings("https://upload.example.org/abc/rec.m4a", att.file_id);
    try testing.expectEqualStrings("alice@example.org", out[0].user_id);

    // A link on some unrelated host stays plain text.
    var foreign = try parseOwned("<message from='alice@example.org/phone' type='chat' id='m2'><body>https://evil.net/x.m4a</body></message>");
    defer foreign.deinit();
    const out2 = try conn.messagesFromElement(arena.allocator(), foreign.element);
    try testing.expectEqual(@as(?iface.Attachment, null), out2[0].attachment);
    try testing.expectEqualStrings("https://evil.net/x.m4a", out2[0].text.?);

    var corr = try parseOwned("<message from='alice@example.org/phone' type='chat' id='m3'><body>fixed</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/></message>");
    defer corr.deinit();
    try testing.expectEqual(@as(usize, 0), (try conn.messagesFromElement(arena.allocator(), corr.element)).len);
}

test "resolvePending hands a matching reply to its waiter and rejects a spoofed sender" {
    var conn = testConnector();
    defer conn.deinit();
    const p = try testing.allocator.create(PendingIq);
    defer testing.allocator.destroy(p);
    p.* = .{ .expect_from = try testing.allocator.dupe(u8, "upload.example.org") };
    defer testing.allocator.free(p.expect_from.?);
    try conn.pending_iqs.put(testing.allocator, "q1", p);

    var spoofed = try parseOwned("<iq type='result' id='q1' from='mallory@evil.net'/>");
    try testing.expect(!conn.resolvePending(spoofed));
    spoofed.deinit();
    try testing.expect(!p.done.load(.acquire));

    const good = try parseOwned("<iq type='result' id='q1' from='upload.example.org'/>");
    try testing.expect(conn.resolvePending(good));
    try testing.expect(p.done.load(.acquire));
    var r = p.result.?;
    r.deinit();
    try testing.expectEqual(@as(usize, 0), conn.pending_iqs.count());
}

test "deleteMessage of someone else's message in a 1:1 chat is unsupported" {
    var conn = testConnector();
    defer conn.deinit();
    try testing.expectError(error.Unsupported, conn.connector().deleteMessage(testing.allocator, "alice@example.org", "m1"));
}

const LiveEnv = struct {
    host: []const u8,
    port: u16,
    domain: []const u8,

    fn get() ?LiveEnv {
        const host_z = std.c.getenv("WARDEN_TEST_XMPP_HOST") orelse return null;
        return .{
            .host = std.mem.span(host_z),
            .port = if (std.c.getenv("WARDEN_TEST_XMPP_PORT")) |p| std.fmt.parseInt(u16, std.mem.span(p), 10) catch 5222 else 5222,
            .domain = if (std.c.getenv("WARDEN_TEST_XMPP_DOMAIN")) |d| std.mem.span(d) else "localhost",
        };
    }
};

/// Polls `conn` on its own thread (so `request` replies get routed) until
/// `stop` is set, keeping every message it maps.
const PollDriver = struct {
    conn: *XmppConnector,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    mu: Io.Mutex = .init,
    received: std.ArrayList(iface.Message) = .empty,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    fn run(self: *PollDriver) void {
        while (!self.stop.load(.acquire)) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const msgs = self.conn.connector().poll(arena.allocator()) catch continue;
            self.mu.lockUncancelable(testing.io);
            defer self.mu.unlock(testing.io);
            for (msgs) |m| {
                const copy = m.dupe(self.arena.allocator()) catch continue;
                self.received.append(self.arena.allocator(), copy) catch {};
            }
        }
    }

    /// Waits up to `seconds` for a received message satisfying `pred`.
    fn await(self: *PollDriver, seconds: u64, ctx: anytype, comptime pred: fn (@TypeOf(ctx), iface.Message) bool) !iface.Message {
        var waited: u64 = 0;
        while (waited < seconds * 10) : (waited += 1) {
            {
                self.mu.lockUncancelable(testing.io);
                defer self.mu.unlock(testing.io);
                for (self.received.items) |m| if (pred(ctx, m)) return m;
            }
            Io.sleep(testing.io, .fromMilliseconds(100), .awake) catch {};
        }
        return error.TestExpectedMessageNeverArrived;
    }

    fn start(self: *PollDriver) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn finish(self: *PollDriver) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
    }
};

/// Polls `conn` from the calling thread until a message satisfying `pred`
/// arrives, or `tries` poll cycles pass.
fn awaitMessage(conn: *XmppConnector, arena: std.mem.Allocator, tries: usize, ctx: anytype, comptime pred: fn (@TypeOf(ctx), iface.Message) bool) !iface.Message {
    for (0..tries) |_| {
        const msgs = try conn.connector().poll(arena);
        for (msgs) |m| if (pred(ctx, m)) return m;
    }
    return error.TestExpectedMessageNeverArrived;
}

// Bot uploads a file to the peer over HTTP File Upload; the peer sees an
// attachment and downloads the same bytes. Exercises disco, IQ routing,
// slot request, PUT, OOB, inbound mapping and download.
test "live: sendDocument uploads via XEP-0363 and the peer downloads the same bytes" {
    const env = LiveEnv.get() orelse return error.SkipZigTest;
    const pa = std.heap.page_allocator;
    var bot = XmppConnector.init(pa, testing.io, env.host, env.port, env.domain, "test", "testpass123", &.{}, .insecure);
    defer bot.deinit();
    var peer = XmppConnector.init(pa, testing.io, env.host, env.port, env.domain, "peer", "testpass123", &.{}, .insecure);
    defer peer.deinit();

    var arena_state = std.heap.ArenaAllocator.init(pa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try peer.ensureConnected(arena);
    var driver: PollDriver = .{ .conn = &bot };
    try bot.ensureConnected(arena);
    try driver.start();
    defer driver.finish();

    const peer_jid = try std.fmt.allocPrint(arena, "peer@{s}", .{env.domain});
    const sent_id = try bot.connector().sendMessageReturningId(arena, peer_jid, "hello from warden", null);
    const text_msg = try awaitMessage(&peer, arena, 6, sent_id.?, struct {
        fn f(id: []const u8, m: iface.Message) bool {
            return m.message_id != null and std.mem.eql(u8, m.message_id.?, id);
        }
    }.f);
    try testing.expectEqualStrings("hello from warden", text_msg.text.?);

    const payload = "warden upload test\n";
    bot.connector().sendDocument(arena, peer_jid, payload, "notes.txt", null);
    const file_msg = try awaitMessage(&peer, arena, 6, {}, struct {
        fn f(_: void, m: iface.Message) bool {
            return m.attachment != null;
        }
    }.f);
    try testing.expectEqualStrings("notes.txt", file_msg.attachment.?.file_name.?);
    const got = try peer.connector().downloadFile(arena, file_msg.attachment.?.file_id);
    try testing.expectEqualStrings(payload, got);
}

fn textIs(want: []const u8, m: iface.Message) bool {
    return m.text != null and std.mem.eql(u8, m.text.?, want);
}

// Bot and peer, both with OMEMO, on the live server: devices get published
// over PEP, sessions are built from fetched bundles, and text plus an
// aesgcm:// file travel encrypted in both directions.
test "live: OMEMO messages and files between two connectors" {
    const env = LiveEnv.get() orelse return error.SkipZigTest;
    var db = try test_support.openTestDb(testing.allocator) orelse return error.SkipZigTest;
    defer db.close();
    var pool = try PgPool.wrapForTest(testing.allocator, testing.io, &db);
    defer pool.deinitTestWrap();

    const pa = std.heap.page_allocator;
    var bot = XmppConnector.init(pa, testing.io, env.host, env.port, env.domain, "test", "testpass123", &.{}, .insecure);
    defer bot.deinit();
    var peer = XmppConnector.init(pa, testing.io, env.host, env.port, env.domain, "peer", "testpass123", &.{}, .insecure);
    defer peer.deinit();
    try bot.enableOmemo(&pool, "bot-test-key");
    try peer.enableOmemo(&pool, "peer-test-key");

    var bot_driver: PollDriver = .{ .conn = &bot };
    var peer_driver: PollDriver = .{ .conn = &peer };
    try bot_driver.start();
    defer bot_driver.finish();
    try peer_driver.start();
    defer peer_driver.finish();

    var arena_state = std.heap.ArenaAllocator.init(pa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const peer_jid = try std.fmt.allocPrint(a, "peer@{s}", .{env.domain});
    const bot_jid = try std.fmt.allocPrint(a, "test@{s}", .{env.domain});

    // Both sides publish asynchronously after connecting; wait until the
    // bot can see the peer's current device (earlier runs leave stale ones).
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        bot.forgetPeerDevices(peer_jid);
        if (bot.client != null and peer.client != null) {
            const ids = bot.peerDevices(a, peer_jid) catch &.{};
            if (std.mem.indexOfScalar(i32, ids, @intCast(peer.omemo.?.device_id)) != null) break;
        }
        Io.sleep(testing.io, .fromMilliseconds(200), .awake) catch {};
    }
    // The peer's bundle publish may trail its device list slightly.
    Io.sleep(testing.io, .fromMilliseconds(500), .awake) catch {};

    try omemo_store.setChatEncrypted(&pool, bot.omemo.?.own_jid, peer_jid, true);
    bot.connector().sendMessage(a, peer_jid, "secret hello", null);
    const got = try peer_driver.await(15, @as([]const u8, "secret hello"), textIs);
    try testing.expectEqualStrings(bot_jid, got.user_id);
    // Receiving it encrypted switched the peer's side of the chat to OMEMO.
    try testing.expect(peer.chatIsEncrypted(bot_jid));

    peer.connector().sendMessage(a, bot_jid, "secret reply", null);
    _ = try bot_driver.await(15, @as([]const u8, "secret reply"), textIs);

    const payload = "encrypted file body\n";
    bot.connector().sendDocument(a, peer_jid, payload, "secret.txt", null);
    const file_msg = try peer_driver.await(15, {}, struct {
        fn f(_: void, m: iface.Message) bool {
            return m.attachment != null and std.mem.startsWith(u8, m.attachment.?.file_id, "aesgcm://");
        }
    }.f);
    const downloaded = try peer.connector().downloadFile(a, file_msg.attachment.?.file_id);
    try testing.expectEqualStrings(payload, downloaded);
}
