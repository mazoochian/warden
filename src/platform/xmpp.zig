const std = @import("std");
const Io = std.Io;

const iface = @import("interface.zig");
const raw = @import("../xmpp/client.zig");
const xml = @import("../xmpp/xml.zig");
const types = @import("../xmpp/types.zig");
const Identity = @import("../domain/identity.zig").Identity;
const XmppProfile = @import("../domain/xmpp_profile.zig").XmppProfile;
const log = @import("../log.zig").scoped("xmpp");

/// How long a single `pollFn` cycle waits for a stanza before returning an
/// empty slice — bounds the blocking socket read so the round-robin poll
/// loop in `main.zig` (which polls every connector, one after another)
/// stays responsive to Telegram/Matrix even when nothing's happening on
/// XMPP. Shorter than Telegram/Matrix's ~25s HTTP long-poll timeout since
/// XMPP's read has no server-side "nothing happened yet" signal the way
/// long-poll does — it just blocks until bytes arrive. Unlike that read
/// itself, though, this timeout does NOT tear the connection down when it
/// fires — see `pollFn`'s doc comment.
const poll_timeout_ns: u64 = 8 * std.time.ns_per_s;

/// Cooldown after a failed `ensureConnected` before `pollFn` returns —
/// discovered live while adding logging (2026-07-25): a failed connect
/// returns an empty slice, not an error, so `main.zig`'s outer
/// `connectorPollLoop` sees an ordinary successful-but-empty poll and loops
/// straight back into `poll()` with zero delay. Without this, an
/// unreachable/misconfigured XMPP server turns into a genuine busy-retry
/// loop — hundreds of connect attempts and log lines per second, burning a
/// full core for nothing, on every host this connector is enabled on.
const reconnect_cooldown_ns: u64 = 5 * std.time.ns_per_s;
const poll_check_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// How long the connection can sit with no stanza read, keepalive sent, or
/// fresh connect before `pollFn` sends a whitespace ping (`Client.
/// sendKeepalive`) — the simplest way to keep a NAT/reverse-proxy/load
/// balancer from silently reclaiming an idle-looking TCP connection.
/// Arbitrary but conservative: most such idle timeouts are measured in
/// minutes, not seconds.
const keepalive_idle_seconds: i64 = 60;

/// How `xmpp/client.zig`'s `startTls` verifies the server's certificate —
/// mirrors `config.zig`'s `XmppTlsMode` one-for-one; kept as this
/// connector's own type (rather than importing `config.zig`) for the same
/// reason `host`/`port`/`domain`/... below are passed as plain values
/// instead of a whole `XmppConfig`: this layer stays decoupled from
/// config, `main.zig` does the unpacking.
pub const TlsMode = enum { self_signed, bundle, insecure };

/// XMPP implementation of `platform.Connector` — 1:1 chat + MUC group chat
/// (with real kick/ban/mute/promote/demote admin actions, XEP-0045 §9),
/// SASL SCRAM-SHA-256/-SHA-1/PLAIN, and configurable TLS verification. See
/// README's "XMPP" section for what's still out of scope (OMEMO, file
/// transfer, roster UI, `/permission`'s granular bitmask, `/tag`) — same
/// spirit as `matrix.zig`'s doc comment on its own scope cuts.
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
    tls_mode: TlsMode,
    client: ?*raw.Client = null,
    bound_jid: ?[]const u8 = null,
    /// Bare room JIDs currently joined — `sendMessageFn` checks membership
    /// here to pick `type='groupchat'` vs `type='chat'`.
    joined_rooms: std.ArrayList([]const u8) = .empty,
    /// The one outstanding background stanza read, kept alive ACROSS
    /// `pollFn` calls rather than respawned every cycle — see `pollFn`'s
    /// doc comment for the reconnect-storm bug this replaces.
    read_thread: ?std.Thread = null,
    read_shared: ?*ReadShared = null,
    /// Wall-clock seconds of the last stanza received, keepalive sent, or
    /// fresh connect — `pollFn` compares against this to decide whether an
    /// idle connection needs a keepalive.
    last_activity_unix: i64 = 0,
    /// Loaded lazily, once, only when `tls_mode == .bundle` — see
    /// `ensureConnected`. `std.crypto.tls.Client.Options.ca`'s `.bundle`
    /// variant requires a lock even though this connector only ever drives
    /// one TLS handshake at a time; `ca_bundle_lock` exists to satisfy that
    /// shape, not because real concurrent access happens here.
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_bundle_loaded: bool = false,
    ca_bundle_lock: Io.RwLock = .init,
    /// Occupants of every currently-joined MUC room, keyed by their full
    /// occupant JID (`room@server/nick` — exactly `Message.user_id` for a
    /// MUC sender, see `messagesFromElement`). Populated from every
    /// presence stanza a joined room sends (`handlePresence` ->
    /// `updateOccupant`), since that's the only channel MUC exposes
    /// affiliation/role/real-JID information on. Backs `isGroupAdminFn`
    /// and resolves the real JID `setAffiliation` (ban/promote/demote)
    /// needs.
    occupants: std.StringHashMap(Occupant),

    const Occupant = struct {
        /// Owned copies of XEP-0045's affiliation ("owner"/"admin"/
        /// "member"/"outcast"/"none") and role ("moderator"/"participant"/
        /// "visitor"/"none") strings, and the occupant's real bare JID —
        /// present only if the room discloses it to this bot (moderators
        /// always see it; a non-anonymous room discloses it to everyone;
        /// a semi-anonymous room with the bot as an ordinary participant
        /// never does).
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
        };
    }

    pub fn deinit(self: *XmppConnector) void {
        if (self.read_shared != null) {
            // A background read may still be blocked on `self.client`'s
            // socket — closing/freeing it here would race a thread that
            // might still be touching that memory. Same "abandon rather
            // than risk a use-after-free" tradeoff `pollFn`'s timeout path
            // used to make every ~8s of idle time before this fix; here it
            // only applies once, at process shutdown.
            self.read_thread.?.detach();
        } else if (self.client) |c| {
            c.close();
        }
        if (self.bound_jid) |j| self.allocator.free(j);
        for (self.joined_rooms.items) |r| self.allocator.free(r);
        self.joined_rooms.deinit(self.allocator);

        var it = self.occupants.iterator();
        while (it.next()) |entry| self.freeOccupantEntry(entry.key_ptr.*, entry.value_ptr.*);
        self.occupants.deinit();

        if (self.ca_bundle_loaded) self.ca_bundle.deinit(self.allocator);
    }

    fn freeOccupantEntry(self: *XmppConnector, key: []const u8, value: Occupant) void {
        self.allocator.free(key);
        self.allocator.free(value.affiliation);
        self.allocator.free(value.role);
        if (value.real_jid) |j| self.allocator.free(j);
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
        .muteUser = muteUserFn,
        .unmuteUser = unmuteUserFn,
        .kickUser = kickUserFn,
        .banUser = banUserFn,
        .promoteUser = promoteUserFn,
        .demoteUser = demoteUserFn,
        .isGroupAdmin = isGroupAdminFn,
        // Every other moderation/media/room-metadata slot (restrictChat-
        // MemberPermissions, setChatAdminTitle, setChatTitle/Description/
        // Photo, pin/unpin, delete, sendDocument, ...) has no XMPP MUC
        // primitive to map onto and stays unset -> `error.Unsupported`,
        // matching the pre-existing stub's behavior for anything it didn't
        // implement either. See README's "XMPP" section.
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
        // Prefer SCRAM whenever the server offers it — PLAIN is the
        // fallback, not the default, since a bare-metal password exchange
        // (even TLS-wrapped) is weaker than SCRAM's salted-challenge
        // exchange. Deliberately doesn't consider "-PLUS" variants: this
        // connector never offers channel binding (see `Client.authScram`'s
        // doc comment), and `hasMechanism`'s exact-string match already
        // excludes them.
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

        if (self.bound_jid) |old| self.allocator.free(old);
        self.bound_jid = try self.allocator.dupe(u8, client.bound_jid.?);
        self.client = client;
        self.last_activity_unix = Io.Timestamp.now(self.io, .real).toSeconds();

        for (self.muc_rooms) |room| {
            client.joinMuc(allocator, room, self.resource) catch |err| {
                log.warn("failed to join MUC room {s}: {t}", .{ room, err });
                continue;
            };
            const dup = self.allocator.dupe(u8, room) catch continue;
            self.joined_rooms.append(self.allocator, dup) catch self.allocator.free(dup);
        }

        log.notice("connected as {s}", .{self.bound_jid.?});
    }

    /// Builds this connect attempt's `Client.TlsVerification` from
    /// `self.tls_mode` — lazily loads the system CA trust store on first
    /// use of `.bundle` (rescanning on every reconnect would be wasteful
    /// and, per `Certificate.Bundle.rescan`'s own contract, isn't needed:
    /// the store doesn't change during one process's lifetime in any way
    /// this connector needs to react to).
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
    /// cancellation point, so `cancel()` could never actually interrupt it.
    ///
    /// Unlike that HTTP fix, though, a timeout here does NOT abandon the
    /// read or the connection — `self.read_shared`/`self.read_thread` stay
    /// set, and the *same* background read keeps being checked across
    /// however many `pollFn` calls it takes to actually complete. This
    /// replaces an earlier version of this function that spawned a fresh
    /// thread every call and abandoned it (leaking both the thread and the
    /// still-open socket) on every timeout — harmless-looking for a chat
    /// that's constantly active, but on any XMPP deployment idle for more
    /// than `poll_timeout_ns` at a stretch (i.e. nearly all of them), that
    /// meant a full reconnect/re-authenticate storm and an unbounded
    /// thread+socket leak every ~8 idle seconds, forever. Since a stanza
    /// read is only ever issued from this one persistent thread per
    /// connection now, there's also no risk of two reads racing the same
    /// socket the way abandoning-and-respawning could.
    ///
    /// `readElement`'s allocations go through `self.allocator` (long-lived,
    /// owned by this connector) rather than the caller's per-poll-cycle
    /// arena — required so an abandoned thread that eventually does finish
    /// writing into `shared` never touches memory the caller may have
    /// already freed (same reasoning as `http_util.zig`'s `FetchShared`).
    /// That case is now rare (only a genuinely wedged socket, e.g. a
    /// black-holed connection the OS never reports as dead) rather than
    /// the common one, but the same safety margin still applies.
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));

        self.ensureConnected(allocator) catch |err| {
            log.warn("connect failed, retrying in {d}s: {t}", .{ @divTrunc(reconnect_cooldown_ns, std.time.ns_per_s), err });
            Io.sleep(self.io, .fromNanoseconds(@intCast(reconnect_cooldown_ns)), .awake) catch {};
            return &.{};
        };
        const client = self.client.?;

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
            // Still nothing this cycle — leave the same read outstanding
            // for the next `pollFn` call, and consider sending a
            // keepalive. Writing here while the background thread is
            // still reading is the same "write from one thread, read from
            // another, on the same socket" pattern `sendMessageFn` already
            // relies on (a reply can be sent while a poll is blocked
            // waiting on the next inbound stanza) — not new concurrency
            // this connector didn't already depend on.
            self.maybeSendKeepalive();
            return &.{};
        }

        self.read_thread.?.join();
        self.read_thread = null;
        self.read_shared = null;
        defer self.allocator.destroy(shared);

        var parsed = shared.result catch |err| {
            log.warn("connection lost ({t}), will reconnect next cycle", .{err});
            client.close();
            self.client = null;
            return &.{};
        };
        defer parsed.deinit();
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

    /// Replies to a server-initiated `<iq type='get'/'set'>` — RFC 6120
    /// §8.2.3 requires every one get *some* reply. XEP-0199 ping gets a
    /// real result (proving liveness is basically free); everything else
    /// (disco#info/#items, vCard fetches, ...) gets a spec-compliant
    /// `feature-not-implemented` error, which XEP-0199 §4 notes is just as
    /// good as a real result for proving the connection is alive, without
    /// this connector needing to implement every namespace a peer might
    /// probe. `type='result'/'error'` IQs (answers to requests *we* sent,
    /// e.g. `setMucRole`/`setMucAffiliation`) are deliberately not replied
    /// to here — those are terminal per RFC 6120, and this connector
    /// doesn't correlate its own outgoing IQ ids to read their results
    /// anyway (see `Client.setMucRole`'s doc comment).
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
        try client.replyIqUnsupported(allocator, from, id);
    }

    /// Auto-accepts subscription requests (see this file's module doc
    /// comment on why that's this connector's whole roster story for now),
    /// tracks MUC occupant affiliation/role/real-JID from every presence a
    /// joined room sends (`updateOccupant` — backs `isGroupAdminFn`/
    /// `setAffiliation`), and detects the bot's own departure from a
    /// joined MUC room — `type="unavailable"` self-presence (the standard
    /// MUC status code 110 marker, inside an `<x xmlns='...muc#user'>`
    /// child) covers leaving voluntarily, being kicked, being banned, or
    /// the room being destroyed alike; XMPP doesn't distinguish these in
    /// the stanza either. Returns a synthetic `chat_left` message in that
    /// case, `null` otherwise.
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

    /// Finds the `<x xmlns='http://jabber.org/protocol/muc#user'>` child
    /// among `el`'s children — namespace-checked (unlike most lookups in
    /// this connector, see `xml.zig`'s module doc on treating `xmlns` as
    /// an ordinary attribute) because a presence stanza can carry more
    /// than one `<x>` extension (e.g. some servers also add `vcard-temp:
    /// x:update` for avatar hashes), and `Element.child` only ever returns
    /// the first match by tag name alone.
    fn mucUserExtension(el: xml.Element) ?xml.Element {
        for (el.children) |node| switch (node) {
            .element => |e| if (std.mem.eql(u8, e.name, "x") and
                std.mem.eql(u8, e.attr("xmlns") orelse "", "http://jabber.org/protocol/muc#user")) return e,
            .text => {},
        };
        return null;
    }

    /// Updates (or, on `type="unavailable"`, removes) `self.occupants`'
    /// entry for `from` (a full occupant JID). A departure clears tracked
    /// state even when the room didn't include a muc#user extension on the
    /// `unavailable` presence — the occupant is gone either way, and stale
    /// affiliation/role data is worse than none.
    fn updateOccupant(self: *XmppConnector, from: []const u8, kind: ?[]const u8, muc_x: ?xml.Element) !void {
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
        // XMPP MUC has no wire-level "@mention" concept (unlike Telegram's
        // entities/Matrix's `m.mentions`) — the closest equivalent is
        // scanning for the bot's own in-room nickname, IRC-style.
        const mentions_me = is_group and mucMentionsMe(body, self.resource);

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
            .mentions_me = mentions_me,
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

    /// Word-boundary-aware, case-insensitive scan for the bot's own MUC
    /// nickname anywhere in `body` — the closest XMPP equivalent to
    /// Telegram's `@username` mention/Matrix's `m.mentions`, neither of
    /// which XMPP has a wire-level concept of. Matches a bare nick as well
    /// as an `@`-prefixed one ("warden, ..." and "@warden ..." both count)
    /// since MUC clients don't agree on a convention.
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

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = reply_to_message_id; // No reply-threading concept this connector uses yet.
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        const client = self.client orelse {
            log.warn("dropped message to {s}, not connected: {s}", .{ chat_id, text });
            return;
        };
        const kind = if (self.isJoinedRoom(chat_id)) "groupchat" else "chat";
        client.sendMessage(allocator, chat_id, kind, text) catch |err| {
            log.warn("failed to send message to {s}: {t}", .{ chat_id, err });
        };
    }

    /// Shared body for `muteUserFn`/`unmuteUserFn`/`kickUserFn` — all
    /// three are XEP-0045 role changes, addressed by nickname (see
    /// `Client.setMucRole`'s doc comment on why role, unlike affiliation,
    /// never needs a real JID).
    fn setRole(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, role: []const u8) !void {
        const client = self.client orelse return error.NotConnected;
        const nick = resourcePart(user_id) orelse return error.NotMucOccupant;
        try client.setMucRole(allocator, chat_id, nick, role);
    }

    /// Shared body for `banUserFn`/`promoteUserFn`/`demoteUserFn` — all
    /// three are XEP-0045 affiliation changes, addressed by the occupant's
    /// real bare JID. That JID has to already be tracked in `self.
    /// occupants` (populated from presence — see `updateOccupant`); if
    /// this bot has never seen it disclosed (a semi-anonymous room and the
    /// bot isn't a moderator), this fails rather than guessing.
    fn setAffiliation(self: *XmppConnector, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, affiliation: []const u8) !void {
        const client = self.client orelse return error.NotConnected;
        const occupant = self.occupants.get(user_id) orelse return error.UnknownOccupant;
        const real_jid = occupant.real_jid orelse return error.RealJidUnknown;
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

    /// Reads `self.occupants` — no I/O, so unlike `setRole`/`setAffiliation`
    /// this never fails; an occupant this bot hasn't seen presence for
    /// yet defaults to "not an admin" rather than erroring, matching how
    /// callers already treat a failed `isGroupAdmin` (see `auth.zig`'s
    /// `checkGroupAdminAccess` and `group_admin.zig`'s promote/demote,
    /// both of which `catch` it into a plain bool anyway).
    fn isGroupAdminFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) anyerror!bool {
        _ = allocator;
        _ = chat_id;
        const self: *XmppConnector = @ptrCast(@alignCast(ptr));
        const occupant = self.occupants.get(user_id) orelse return false;
        return std.mem.eql(u8, occupant.affiliation, "owner") or std.mem.eql(u8, occupant.affiliation, "admin");
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
/// tree's storage rides `return`'s result-location semantics all the way
/// out to the caller — same shape as `statusCode110Presence` below. A
/// local `var` slice pointing at this function's own stack frame would
/// dangle the moment it returned.
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

// Full connect -> TLS `self_signed` verification -> MUC join -> real
// server presence round trip — gated on `WARDEN_TEST_XMPP_HOST` (same
// convention as `client.zig`'s "Client stages 1-4" test). Confirms two
// things the hand-built fixtures above can't: that `.self_signed` TLS
// verification (this connector's new default, replacing the old
// `.no_verification`) actually completes a handshake against a real
// server's self-signed cert, and that `updateOccupant` correctly parses a
// *real* server's muc#user presence extension shape, not just the tests'
// own fixtures. Point it at the `prosody` compose service, same as
// `client.zig`'s test.
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
    // creator the owner -- confirms real affiliation/role attributes made
    // it through parsing, not just that *an* item element was present.
    const occupant = conn.occupants.get(self_occupant_jid).?;
    try testing.expect(std.mem.eql(u8, occupant.affiliation, "owner") or std.mem.eql(u8, occupant.affiliation, "admin"));
}

// Regression test for the exact bug `pollFn`'s doc comment describes:
// before this fix, every `poll_timeout_ns` (8s) of silence tore the whole
// connection down and reconnected from scratch, leaking a thread+socket
// each time. Two full idle cycles (>16s) here is well past that old
// trigger point; a pointer-identity check on `conn.client` is a direct,
// unambiguous way to prove no reconnect happened (a reconnect would
// `create` a new `Client` at a different address).
test "XmppConnector.poll keeps the same connection alive across multiple idle poll_timeout cycles" {
    const host_z = std.c.getenv("WARDEN_TEST_XMPP_HOST") orelse return error.SkipZigTest;
    const port: u16 = if (std.c.getenv("WARDEN_TEST_XMPP_PORT")) |p| try std.fmt.parseInt(u16, std.mem.span(p), 10) else 5222;
    const domain = if (std.c.getenv("WARDEN_TEST_XMPP_DOMAIN")) |d| std.mem.span(d) else "localhost";
    const user = if (std.c.getenv("WARDEN_TEST_XMPP_USER")) |u| std.mem.span(u) else "test";
    const password = if (std.c.getenv("WARDEN_TEST_XMPP_PASSWORD")) |p| std.mem.span(p) else "testpass123";

    // `page_allocator`, not `testing.allocator`, for the connector itself:
    // this test's very last `poll()` deliberately ends with a background
    // read still outstanding (nothing ever arrives to complete it), so
    // `conn.deinit()` takes the documented "abandon rather than risk a
    // use-after-free" path and never frees the `Client`'s buffers — a real,
    // intentional leak in this one abandoned-on-shutdown case (see
    // `pollFn`'s doc comment), not a bug this test should fail on.
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
