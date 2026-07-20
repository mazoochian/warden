const std = @import("std");
const Io = std.Io;

const xml = @import("xml.zig");
const types = @import("types.zig");

/// The raw-socket and TLS-record buffers are all sized to
/// `std.crypto.tls.Client.min_buffer_len` (~16.5KB, the minimum the TLS
/// layer needs for one maximum-size ciphertext record) — mirrors how
/// `std.http.Client` sizes its own `tls_buffer_size` (see its `Tls.create`,
/// which this connection-upgrade path is modeled on).
const buffer_size = std.crypto.tls.Client.min_buffer_len;

/// A raw XMPP (RFC 6120) client-to-server connection: TCP + STARTTLS + SASL
/// PLAIN + resource binding, then `<message>`/`<presence>` stanzas. No
/// XML/SASL/socket library exists anywhere else in this codebase — Matrix
/// and Telegram are both plain REST+JSON over HTTPS via `std.http.Client`,
/// so this is genuinely new territory (see README's "XMPP" section for the
/// resulting scope limits: PLAIN-only, no E2EE, no MUC admin features).
///
/// Heap-allocated and never moved after `connect()` returns, unlike
/// `matrix/client.zig`'s `Client` (a plain value type `MatrixConnector`
/// embeds by field) — `std.crypto.tls.Client`'s `.reader`/`.writer` fields
/// close over their own address via `@fieldParentPtr`, and `input`/`output`
/// point at `stream_reader`/`stream_writer`'s fields, so this whole struct
/// must stay at a fixed address for the rest of the connection's lifetime
/// once TLS is established. `platform/xmpp.zig`'s `XmppConnector` holds a
/// `*Client`, never a `Client`, for exactly this reason.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    stream_reader: Io.net.Stream.Reader,
    stream_writer: Io.net.Stream.Writer,
    tls_read_buf: []u8,
    tls_write_buf: []u8,
    tls_client: ?std.crypto.tls.Client = null,
    /// Points at `&stream_reader.interface` before STARTTLS, `&tls_client.
    /// ?.reader` after — every stanza read goes through this, so the rest
    /// of the state machine doesn't need to know which phase it's in.
    reader: *Io.Reader,
    writer: *Io.Writer,
    bound_jid: ?[]const u8 = null,

    /// Opens a TCP connection to `host:port` — a plain hostname/IP the
    /// socket actually dials, which may differ from the XMPP `domain`
    /// `openStream`/SASL authenticate against (e.g. a compose service name
    /// like "prosody" vs. a JID's "localhost" domain part).
    pub fn connect(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        const host_name = try Io.net.HostName.init(host);
        const stream = try host_name.connect(io, port, .{ .mode = .stream });
        errdefer stream.close(io);

        const raw_read_buf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(raw_read_buf);
        const raw_write_buf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(raw_write_buf);
        const tls_read_buf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(tls_read_buf);
        const tls_write_buf = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(tls_write_buf);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .stream_reader = stream.reader(io, raw_read_buf),
            .stream_writer = stream.writer(io, raw_write_buf),
            .tls_read_buf = tls_read_buf,
            .tls_write_buf = tls_write_buf,
            .reader = undefined,
            .writer = undefined,
        };
        self.reader = &self.stream_reader.interface;
        self.writer = &self.stream_writer.interface;
        return self;
    }

    /// Best-effort clean shutdown: sends the closing stream tag before
    /// tearing the socket down. Errors sending it are ignored — the socket
    /// close below is what actually matters.
    pub fn close(self: *Client) void {
        self.writer.writeAll("</stream:stream>") catch {};
        self.writer.flush() catch {};
        self.deinit();
    }

    pub fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.allocator.free(self.stream_reader.interface.buffer);
        self.allocator.free(self.stream_writer.interface.buffer);
        self.allocator.free(self.tls_read_buf);
        self.allocator.free(self.tls_write_buf);
        if (self.bound_jid) |j| self.allocator.free(j);
        self.allocator.destroy(self);
    }

    /// `self.writer.flush()` alone is not enough once TLS is active:
    /// `std.crypto.tls.Client`'s own `flush` only encrypts buffered
    /// plaintext into the *raw* writer's buffer (`output.advance(...)`) —
    /// confirmed by reading `crypto/tls/Client.zig`'s `flush` — it never
    /// flushes that raw writer on to the actual socket. Without this
    /// second flush, every post-STARTTLS stanza sits encrypted in memory
    /// and never reaches the server (found live: `openStream`'s second
    /// call would hang forever waiting for a reply to a write that never
    /// went out). Flushing the raw writer pre-TLS too is a harmless no-op
    /// (nothing buffered there once `self.writer.flush()` already drained
    /// straight to the socket).
    fn sendRaw(self: *Client, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
        try self.writer.flush();
        try self.stream_writer.interface.flush();
    }

    /// Reads one complete top-level element off `self.reader`, blocking
    /// (via `fillMore`) until enough bytes have arrived — the shared loop
    /// behind every stanza read in this file, and the one
    /// `platform/xmpp.zig`'s `pollFn` calls directly for inbound
    /// message/presence stanzas once the connection is up.
    pub fn readElement(self: *Client, allocator: std.mem.Allocator) !xml.ParsedElement {
        while (true) {
            if (xml.parseElement(allocator, self.reader.buffered())) |parsed| {
                self.reader.toss(parsed.consumed);
                return parsed;
            } else |err| switch (err) {
                error.Incomplete => try self.reader.fillMore(),
                else => |e| return e,
            }
        }
    }

    fn readOpenTag(self: *Client, allocator: std.mem.Allocator) !xml.ParsedOpenTag {
        while (true) {
            if (xml.parseStreamOpenTag(allocator, self.reader.buffered())) |parsed| {
                self.reader.toss(parsed.consumed);
                return parsed;
            } else |err| switch (err) {
                error.Incomplete => try self.reader.fillMore(),
                else => |e| return e,
            }
        }
    }

    /// Sends `<stream:stream to='domain' ...>` and reads back the server's
    /// own stream-open tag plus the `<stream:features>` that follows it in
    /// the same burst (confirmed against Prosody: both arrive in one TCP
    /// read). RFC 6120 requires doing this again after STARTTLS and again
    /// after successful SASL — call it three times total per connection.
    pub fn openStream(self: *Client, allocator: std.mem.Allocator, domain: []const u8) !types.StreamFeatures {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<?xml version='1.0'?><stream:stream to='");
        try xml.writeEscapedAttr(&out.writer, domain);
        try out.writer.writeAll("' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>");
        try self.sendRaw(out.writer.buffered());

        var open = try self.readOpenTag(allocator);
        defer open.deinit();

        var features_el = try self.readElement(allocator);
        defer features_el.deinit();
        return types.StreamFeatures.fromElement(allocator, features_el.element);
    }

    /// Upgrades the connection to TLS following a successful `<starttls/>`
    /// negotiation. `.no_verification` for both host and CA checks —
    /// tonight's self-hosted Prosody uses a self-signed certificate, so
    /// this connector is deliberately only trusted for a self-hosted/
    /// trusted-server deployment, never a public/federated one (see
    /// README's "XMPP" section).
    pub fn startTls(self: *Client) !void {
        try self.sendRaw("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");

        var reply = try self.readElement(self.allocator);
        defer reply.deinit();
        if (!std.mem.eql(u8, reply.element.name, "proceed")) return error.StartTlsRefused;

        var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&random_buffer);

        self.tls_client = try std.crypto.tls.Client.init(&self.stream_reader.interface, &self.stream_writer.interface, .{
            .host = .no_verification,
            .ca = .no_verification,
            .read_buffer = self.tls_read_buf,
            .write_buffer = self.tls_write_buf,
            .entropy = &random_buffer,
            .realtime_now = Io.Clock.real.now(self.io),
        });
        self.reader = &self.tls_client.?.reader;
        self.writer = &self.tls_client.?.writer;
    }

    /// SASL PLAIN (RFC 4616) — call once the post-TLS `<stream:features>`'s
    /// mechanisms include "PLAIN" (`StreamFeatures.hasMechanism`).
    pub fn authPlain(self: *Client, allocator: std.mem.Allocator, user: []const u8, password: []const u8) !void {
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(allocator);
        try raw.append(allocator, 0);
        try raw.appendSlice(allocator, user);
        try raw.append(allocator, 0);
        try raw.appendSlice(allocator, password);

        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(raw.items.len));
        defer allocator.free(encoded);
        _ = encoder.encode(encoded, raw.items);

        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>");
        try out.writer.writeAll(encoded);
        try out.writer.writeAll("</auth>");
        try self.sendRaw(out.writer.buffered());

        var reply = try self.readElement(allocator);
        defer reply.deinit();
        switch (try types.parseSaslOutcome(allocator, reply.element)) {
            .success => {},
            .failure => |reason| {
                defer allocator.free(reason);
                std.log.err("xmpp: SASL PLAIN failed: {s}", .{reason});
                return error.SaslFailed;
            },
        }
    }

    /// Binds `resource` and, if the (post-SASL) features still advertise
    /// `<session/>`, sends the legacy session-establishment IQ too — modern
    /// servers (Prosody included) often no longer require it, so a
    /// non-result reply there doesn't fail the whole connect. Returns the
    /// bound full JID and stores it in `self.bound_jid`.
    pub fn bindResource(self: *Client, allocator: std.mem.Allocator, resource: []const u8, session_required: bool) ![]const u8 {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<iq type='set' id='bind1'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>");
        try xml.writeEscapedText(&out.writer, resource);
        try out.writer.writeAll("</resource></bind></iq>");
        try self.sendRaw(out.writer.buffered());

        var reply = try self.readElement(allocator);
        defer reply.deinit();
        const jid = try types.boundJid(allocator, reply.element) orelse return error.BindFailed;
        errdefer allocator.free(jid);

        if (session_required) {
            try self.sendRaw("<iq type='set' id='sess1'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>");
            var sess_reply = try self.readElement(allocator);
            sess_reply.deinit();
        }

        if (self.bound_jid) |old| self.allocator.free(old);
        self.bound_jid = try self.allocator.dupe(u8, jid);
        return jid;
    }

    /// Sends a `<message>` stanza — `kind` is `"chat"` for 1:1 or
    /// `"groupchat"` for MUC (see `joinMuc`), matching how
    /// `platform/xmpp.zig` tracks which `chat_id`s are joined rooms.
    pub fn sendMessage(self: *Client, allocator: std.mem.Allocator, to: []const u8, kind: []const u8, body: []const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<message to='");
        try xml.writeEscapedAttr(&out.writer, to);
        try out.writer.writeAll("' type='");
        try xml.writeEscapedAttr(&out.writer, kind);
        try out.writer.writeAll("'><body>");
        try xml.writeEscapedText(&out.writer, body);
        try out.writer.writeAll("</body></message>");
        try self.sendRaw(out.writer.buffered());
    }

    /// Joins a MUC room (XEP-0045) under `nick` — the room reflects a burst
    /// of presence/history back; `platform/xmpp.zig` discards it the same
    /// way `matrix.zig`'s `initial_sync_done` discards the first `/sync`'s
    /// backlog, rather than treating replayed history as new messages.
    pub fn joinMuc(self: *Client, allocator: std.mem.Allocator, room_jid: []const u8, nick: []const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<presence to='");
        try xml.writeEscapedAttr(&out.writer, room_jid);
        try out.writer.writeByte('/');
        try xml.writeEscapedAttr(&out.writer, nick);
        try out.writer.writeAll("'><x xmlns='http://jabber.org/protocol/muc'/></presence>");
        try self.sendRaw(out.writer.buffered());
    }

    /// A single whitespace byte — the simplest universally-supported XMPP
    /// keepalive, cheaper than a round-tripping XEP-0199 ping since it
    /// needs no response to parse. Call on an idle timer from
    /// `platform/xmpp.zig`.
    pub fn sendKeepalive(self: *Client) !void {
        try self.sendRaw(" ");
    }

    /// Auto-accepts an incoming presence subscription request (`<presence
    /// type='subscribe'>`) — this connector's whole roster-management story
    /// for tonight's MVP (see README's "XMPP" section): no manual approval,
    /// no roster UI, just always let people add the bot, mirroring how the
    /// Matrix connector auto-joins any room invite.
    pub fn acceptSubscription(self: *Client, allocator: std.mem.Allocator, from_bare_jid: []const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<presence to='");
        try xml.writeEscapedAttr(&out.writer, from_bare_jid);
        try out.writer.writeAll("' type='subscribed'/>");
        try self.sendRaw(out.writer.buffered());
    }
};

const testing = std.testing;

test "authPlain's SASL PLAIN payload is \\0user\\0password, base64-encoded" {
    // authPlain itself needs a live socket, so this locks down the payload
    // construction it depends on in isolation instead.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    try raw.append(testing.allocator, 0);
    try raw.appendSlice(testing.allocator, "test");
    try raw.append(testing.allocator, 0);
    try raw.appendSlice(testing.allocator, "testpass123");

    const encoder = std.base64.standard.Encoder;
    const encoded = try testing.allocator.alloc(u8, encoder.calcSize(raw.items.len));
    defer testing.allocator.free(encoded);
    _ = encoder.encode(encoded, raw.items);

    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const decoded = try testing.allocator.alloc(u8, decoded_len);
    defer testing.allocator.free(decoded);
    try decoder.decode(decoded, encoded);

    try testing.expectEqualSlices(u8, "\x00test\x00testpass123", decoded);
}

// Full connect -> STARTTLS -> SASL PLAIN -> bind round trip against a real
// server — gated on `WARDEN_TEST_XMPP_HOST` (mirrors
// `store/test_support.zig`'s `WARDEN_TEST_POSTGRES_DSN` gate) so this skips
// rather than fails when no XMPP test server is running. Point it at the
// `prosody` compose service (see `compose.yaml`) to verify this file's
// stages 1-4 actually work, not just compile.
test "Client stages 1-4: connect, STARTTLS, SASL PLAIN, and resource binding against a live server" {
    const host_z = std.c.getenv("WARDEN_TEST_XMPP_HOST") orelse return error.SkipZigTest;
    const port: u16 = if (std.c.getenv("WARDEN_TEST_XMPP_PORT")) |p| try std.fmt.parseInt(u16, std.mem.span(p), 10) else 5222;
    const domain = if (std.c.getenv("WARDEN_TEST_XMPP_DOMAIN")) |d| std.mem.span(d) else "localhost";
    const user = if (std.c.getenv("WARDEN_TEST_XMPP_USER")) |u| std.mem.span(u) else "test";
    const password = if (std.c.getenv("WARDEN_TEST_XMPP_PASSWORD")) |p| std.mem.span(p) else "testpass123";

    const client = try Client.connect(testing.allocator, testing.io, std.mem.span(host_z), port);
    defer client.close();

    const features1 = try client.openStream(testing.allocator, domain);
    defer {
        for (features1.mechanisms) |m| testing.allocator.free(m);
        testing.allocator.free(features1.mechanisms);
    }
    try testing.expect(features1.starttls);

    try client.startTls();

    var features2 = try client.openStream(testing.allocator, domain);
    defer {
        for (features2.mechanisms) |m| testing.allocator.free(m);
        testing.allocator.free(features2.mechanisms);
    }
    try testing.expect(features2.hasMechanism("PLAIN"));

    try client.authPlain(testing.allocator, user, password);

    const features3 = try client.openStream(testing.allocator, domain);
    defer {
        for (features3.mechanisms) |m| testing.allocator.free(m);
        testing.allocator.free(features3.mechanisms);
    }
    try testing.expect(features3.bind);

    const jid = try client.bindResource(testing.allocator, "warden-test", features3.session);
    defer testing.allocator.free(jid);
    try testing.expect(std.mem.indexOf(u8, jid, user) != null);
}
