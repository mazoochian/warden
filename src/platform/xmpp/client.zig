const std = @import("std");
const Io = std.Io;

const xml = @import("xml.zig");
const types = @import("types.zig");

/// The raw-socket and TLS-record buffers are all sized to
/// `std.crypto.tls.Client.min_buffer_len`.
const buffer_size = std.crypto.tls.Client.min_buffer_len;

/// The decrypted-plaintext read buffer, which is also the largest stanza
/// `readElement` can assemble.
const max_stanza_size = 256 * 1024;

/// A raw XMPP (RFC 6120) client-to-server connection: TCP + STARTTLS + SASL
/// PLAIN + resource binding, then `<message>`/`<presence>` stanzas.
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
    /// ?.reader` after — every stanza read goes through this.
    reader: *Io.Reader,
    writer: *Io.Writer,
    bound_jid: ?[]const u8 = null,
    /// Source of `id` attributes for `setMucRole`/`setMucAffiliation`/
    /// `replyIqResult`/`replyIqUnsupported` — those are fire-and-forget.
    iq_counter: u32 = 0,

    /// Opens a TCP connection to `host:port` — a plain hostname/IP the socket
    /// actually dials.
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
        const tls_read_buf = try allocator.alloc(u8, max_stanza_size);
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

    /// Best-effort clean shutdown: sends the closing stream tag before tearing
    /// the socket down.
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

    /// `self.writer.flush()` alone is not enough once TLS is active.
    fn sendRaw(self: *Client, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
        try self.writer.flush();
        try self.stream_writer.interface.flush();
    }

    /// Reads one complete top-level element off `self.reader`, blocking (via
    /// `fillMore`) until enough bytes have arrived.
    pub fn readElement(self: *Client, allocator: std.mem.Allocator) !xml.ParsedElement {
        while (true) {
            if (xml.parseElement(allocator, self.reader.buffered())) |parsed| {
                self.reader.toss(parsed.consumed);
                return parsed;
            } else |err| switch (err) {
                error.Incomplete => try self.fillMoreForStanza(),
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
                error.Incomplete => try self.fillMoreForStanza(),
                else => |e| return e,
            }
        }
    }

    /// `self.reader.fillMore()`, but refusing rather than aborting when the
    /// buffer is already full of one unconsumable partial stanza.
    fn fillMoreForStanza(self: *Client) !void {
        if (self.reader.buffered().len >= self.reader.buffer.len) return error.StanzaTooLarge;
        try self.reader.fillMore();
    }

    /// Sends `<stream:stream to='domain' ...>` and reads back the server's own
    /// stream-open tag plus the `<stream:features>` that follows it in the same
    /// burst (confirmed against Prosody: both arrive in one TCP read).
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

    /// How `startTls` verifies the server's certificate — the caller
    /// (`connector.zig`, driven by `WARDEN_XMPP_TLS_MODE`) picks one.
    pub const TlsVerification = union(enum) {
        /// No certificate verification at all — `.no_verification` for both host and
        /// CA.
        insecure,
        /// Certificate must be a well-formed, non-expired self-signed cert whose
        /// identity matches `host` — no CA vouches for it.
        self_signed: struct { host: []const u8 },
        /// Full chain-of-trust verification against `bundle` plus a hostname match
        /// against `host`.
        bundle: struct {
            host: []const u8,
            gpa: std.mem.Allocator,
            io: Io,
            lock: *Io.RwLock,
            bundle: *std.crypto.Certificate.Bundle,
        },
    };

    /// Upgrades the connection to TLS following a successful `<starttls/>`
    /// negotiation.
    pub fn startTls(self: *Client, verification: TlsVerification) !void {
        try self.sendRaw("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>");

        var reply = try self.readElement(self.allocator);
        defer reply.deinit();
        if (!std.mem.eql(u8, reply.element.name, "proceed")) return error.StartTlsRefused;

        var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&random_buffer);

        const options: std.crypto.tls.Client.Options = switch (verification) {
            .insecure => .{
                .host = .no_verification,
                .ca = .no_verification,
                .read_buffer = self.tls_read_buf,
                .write_buffer = self.tls_write_buf,
                .entropy = &random_buffer,
                .realtime_now = Io.Clock.real.now(self.io),
            },
            .self_signed => |v| .{
                .host = .{ .explicit = v.host },
                .ca = .self_signed,
                .read_buffer = self.tls_read_buf,
                .write_buffer = self.tls_write_buf,
                .entropy = &random_buffer,
                .realtime_now = Io.Clock.real.now(self.io),
            },
            .bundle => |v| .{
                .host = .{ .explicit = v.host },
                .ca = .{ .bundle = .{ .gpa = v.gpa, .io = v.io, .lock = v.lock, .bundle = v.bundle } },
                .read_buffer = self.tls_read_buf,
                .write_buffer = self.tls_write_buf,
                .entropy = &random_buffer,
                .realtime_now = Io.Clock.real.now(self.io),
            },
        };

        self.tls_client = try std.crypto.tls.Client.init(&self.stream_reader.interface, &self.stream_writer.interface, options);
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

    fn nextIqId(self: *Client, allocator: std.mem.Allocator) ![]const u8 {
        self.iq_counter += 1;
        return std.fmt.allocPrint(allocator, "wia{d}", .{self.iq_counter});
    }

    fn b64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const encoder = std.base64.standard.Encoder;
        const out = try allocator.alloc(u8, encoder.calcSize(data.len));
        _ = encoder.encode(out, data);
        return out;
    }

    fn b64Decode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        const decoder = std.base64.standard.Decoder;
        const len = try decoder.calcSizeForSlice(data);
        const out = try allocator.alloc(u8, len);
        try decoder.decode(out, data);
        return out;
    }

    /// Escapes `,` and `=` in a SASL "saslname" (RFC 4013/5802 §5.1) — the SCRAM
    /// username field's only escaping requirement.
    fn scramEscapeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (name) |c| switch (c) {
            ',' => try out.appendSlice(allocator, "=2C"),
            '=' => try out.appendSlice(allocator, "=3D"),
            else => try out.append(allocator, c),
        };
        return out.toOwnedSlice(allocator);
    }

    const ScramChallenge = struct {
        nonce: []const u8,
        salt_b64: []const u8,
        iterations: u32,
    };

    /// Parses a decoded SCRAM server-first-message ("r=...,s=...,i=...").
    fn parseScramChallenge(raw: []const u8) !ScramChallenge {
        var nonce: ?[]const u8 = null;
        var salt_b64: ?[]const u8 = null;
        var iterations: ?u32 = null;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |field| {
            if (field.len < 2 or field[1] != '=') continue;
            const value = field[2..];
            switch (field[0]) {
                'r' => nonce = value,
                's' => salt_b64 = value,
                'i' => iterations = std.fmt.parseInt(u32, value, 10) catch return error.ScramMalformedChallenge,
                'm' => return error.ScramUnsupportedExtension,
                else => {},
            }
        }
        return .{
            .nonce = nonce orelse return error.ScramMalformedChallenge,
            .salt_b64 = salt_b64 orelse return error.ScramMalformedChallenge,
            .iterations = iterations orelse return error.ScramMalformedChallenge,
        };
    }

    const ScramProof = struct {
        /// Owns all three fields — free with `deinit`.
        client_final_without_proof: []const u8,
        client_final: []const u8,
        expected_server_signature_b64: []const u8,

        fn deinit(self: ScramProof, allocator: std.mem.Allocator) void {
            allocator.free(self.client_final_without_proof);
            allocator.free(self.client_final);
            allocator.free(self.expected_server_signature_b64);
        }
    };

    /// The pure crypto core of SCRAM (RFC 5802 §3): salted-password -> client
    /// proof + expected server signature.
    fn scramComputeProof(
        allocator: std.mem.Allocator,
        comptime Hmac: type,
        comptime Hash: type,
        password: []const u8,
        salt: []const u8,
        iterations: u32,
        client_first_bare: []const u8,
        server_first_raw: []const u8,
        combined_nonce: []const u8,
    ) !ScramProof {
        const digest_len = Hmac.mac_length;
        comptime std.debug.assert(Hash.digest_length == digest_len);

        var salted_password: [digest_len]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&salted_password, password, salt, iterations, Hmac);

        var client_key: [digest_len]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &salted_password);
        var stored_key: [digest_len]u8 = undefined;
        Hash.hash(&client_key, &stored_key, .{});

        const client_final_without_proof = try std.fmt.allocPrint(allocator, "c=biws,r={s}", .{combined_nonce});
        errdefer allocator.free(client_final_without_proof);

        const auth_message = try std.fmt.allocPrint(allocator, "{s},{s},{s}", .{ client_first_bare, server_first_raw, client_final_without_proof });
        defer allocator.free(auth_message);

        var client_signature: [digest_len]u8 = undefined;
        Hmac.create(&client_signature, auth_message, &stored_key);

        var client_proof: [digest_len]u8 = undefined;
        for (&client_proof, client_key, client_signature) |*p, ck, cs| p.* = ck ^ cs;

        const proof_b64 = try b64Encode(allocator, &client_proof);
        defer allocator.free(proof_b64);

        const client_final = try std.fmt.allocPrint(allocator, "{s},p={s}", .{ client_final_without_proof, proof_b64 });
        errdefer allocator.free(client_final);

        var server_key: [digest_len]u8 = undefined;
        Hmac.create(&server_key, "Server Key", &salted_password);
        var server_signature: [digest_len]u8 = undefined;
        Hmac.create(&server_signature, auth_message, &server_key);
        const server_signature_b64 = try b64Encode(allocator, &server_signature);
        errdefer allocator.free(server_signature_b64);

        return .{
            .client_final_without_proof = client_final_without_proof,
            .client_final = client_final,
            .expected_server_signature_b64 = server_signature_b64,
        };
    }

    /// SCRAM (RFC 5802), parameterized on the hash/HMAC pair.
    fn authScram(self: *Client, allocator: std.mem.Allocator, user: []const u8, password: []const u8, comptime Hmac: type, comptime Hash: type, mechanism: []const u8) !void {
        const escaped_user = try scramEscapeName(allocator, user);
        defer allocator.free(escaped_user);

        var nonce_raw: [24]u8 = undefined;
        self.io.random(&nonce_raw);
        const client_nonce = try b64Encode(allocator, &nonce_raw);
        defer allocator.free(client_nonce);

        const client_first_bare = try std.fmt.allocPrint(allocator, "n={s},r={s}", .{ escaped_user, client_nonce });
        defer allocator.free(client_first_bare);

        {
            const client_first = try std.fmt.allocPrint(allocator, "n,,{s}", .{client_first_bare});
            defer allocator.free(client_first);
            const encoded = try b64Encode(allocator, client_first);
            defer allocator.free(encoded);

            var out: Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            try out.writer.writeAll("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='");
            try out.writer.writeAll(mechanism);
            try out.writer.writeAll("'>");
            try out.writer.writeAll(encoded);
            try out.writer.writeAll("</auth>");
            try self.sendRaw(out.writer.buffered());
        }

        var challenge_reply = try self.readElement(allocator);
        defer challenge_reply.deinit();
        if (std.mem.eql(u8, challenge_reply.element.name, "failure")) {
            switch (try types.parseSaslOutcome(allocator, challenge_reply.element)) {
                .failure => |reason| {
                    defer allocator.free(reason);
                    std.log.err("xmpp: SASL {s} failed: {s}", .{ mechanism, reason });
                    return error.SaslFailed;
                },
                .success => {},
            }
        }
        if (!std.mem.eql(u8, challenge_reply.element.name, "challenge")) return error.UnexpectedSaslReply;

        const server_first_b64 = try challenge_reply.element.text(allocator);
        defer allocator.free(server_first_b64);
        const server_first = try b64Decode(allocator, server_first_b64);
        defer allocator.free(server_first);

        const challenge = try parseScramChallenge(server_first);
        // RFC 5802 §3: the client MUST verify the server's nonce starts with the
        // client's own.
        if (!std.mem.startsWith(u8, challenge.nonce, client_nonce)) return error.ScramNonceMismatch;

        const salt = try b64Decode(allocator, challenge.salt_b64);
        defer allocator.free(salt);

        const proof = try scramComputeProof(allocator, Hmac, Hash, password, salt, challenge.iterations, client_first_bare, server_first, challenge.nonce);
        defer proof.deinit(allocator);

        {
            const encoded = try b64Encode(allocator, proof.client_final);
            defer allocator.free(encoded);

            var out: Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            try out.writer.writeAll("<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>");
            try out.writer.writeAll(encoded);
            try out.writer.writeAll("</response>");
            try self.sendRaw(out.writer.buffered());
        }

        var final_reply = try self.readElement(allocator);
        defer final_reply.deinit();
        if (std.mem.eql(u8, final_reply.element.name, "failure")) {
            switch (try types.parseSaslOutcome(allocator, final_reply.element)) {
                .failure => |reason| {
                    defer allocator.free(reason);
                    std.log.err("xmpp: SASL {s} failed: {s}", .{ mechanism, reason });
                    return error.SaslFailed;
                },
                .success => {},
            }
        }
        if (!std.mem.eql(u8, final_reply.element.name, "success")) return error.UnexpectedSaslReply;

        const success_payload_b64 = try final_reply.element.text(allocator);
        defer allocator.free(success_payload_b64);
        const success_payload = try b64Decode(allocator, success_payload_b64);
        defer allocator.free(success_payload);

        if (!std.mem.startsWith(u8, success_payload, "v=")) return error.ScramServerSignatureMissing;
        if (!std.mem.eql(u8, success_payload[2..], proof.expected_server_signature_b64)) {
            std.log.err("xmpp: SASL {s} succeeded but the server's own signature didn't verify — possible MITM", .{mechanism});
            return error.ScramServerSignatureMismatch;
        }
    }

    /// SASL SCRAM-SHA-256 (RFC 7677) — preferred over SCRAM-SHA-1/PLAIN whenever
    /// a server advertises it (see `connector.zig`'s `ensureConnected`).
    pub fn authScramSha256(self: *Client, allocator: std.mem.Allocator, user: []const u8, password: []const u8) !void {
        return self.authScram(allocator, user, password, std.crypto.auth.hmac.sha2.HmacSha256, std.crypto.hash.sha2.Sha256, "SCRAM-SHA-256");
    }

    /// SASL SCRAM-SHA-1 (RFC 5802) — used when a server advertises SCRAM
    /// but not the SHA-256 variant.
    pub fn authScramSha1(self: *Client, allocator: std.mem.Allocator, user: []const u8, password: []const u8) !void {
        return self.authScram(allocator, user, password, std.crypto.auth.hmac.HmacSha1, std.crypto.hash.Sha1, "SCRAM-SHA-1");
    }

    /// Binds `resource` and, if the (post-SASL) features still advertise
    /// `<session/>`, sends the legacy session-establishment IQ too.
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

    /// Sends a `<message>` stanza — `kind` is `"chat"` for 1:1 or "groupchat" for
    /// MUC (see `joinMuc`).
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

    /// Joins a MUC room (XEP-0045) under `nick`.
    pub fn joinMuc(self: *Client, allocator: std.mem.Allocator, room_jid: []const u8, nick: []const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<presence to='");
        try xml.writeEscapedAttr(&out.writer, room_jid);
        try out.writer.writeByte('/');
        try xml.writeEscapedAttr(&out.writer, nick);
        try out.writer.writeAll("'><x xmlns='http://jabber.org/protocol/muc'><history maxchars='0'/></x></presence>");
        try self.sendRaw(out.writer.buffered());
    }

    /// A single whitespace byte — the simplest universally-supported XMPP
    /// keepalive.
    pub fn sendKeepalive(self: *Client) !void {
        try self.sendRaw(" ");
    }

    /// Changes an occupant's MUC role (XEP-0045 §9.6 kick / §9.8 voice).
    pub fn setMucRole(self: *Client, allocator: std.mem.Allocator, room_jid: []const u8, nick: []const u8, role: []const u8) !void {
        const id = try self.nextIqId(allocator);
        defer allocator.free(id);

        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<iq type='set' to='");
        try xml.writeEscapedAttr(&out.writer, room_jid);
        try out.writer.writeAll("' id='");
        try out.writer.writeAll(id);
        try out.writer.writeAll("'><query xmlns='http://jabber.org/protocol/muc#admin'><item nick='");
        try xml.writeEscapedAttr(&out.writer, nick);
        try out.writer.writeAll("' role='");
        try xml.writeEscapedAttr(&out.writer, role);
        try out.writer.writeAll("'/></query></iq>");
        try self.sendRaw(out.writer.buffered());
    }

    /// Changes an occupant's MUC affiliation (XEP-0045 §9.1 ban / §9.3-9.4 admin-
    /// owner grants).
    pub fn setMucAffiliation(self: *Client, allocator: std.mem.Allocator, room_jid: []const u8, real_jid: []const u8, affiliation: []const u8) !void {
        const id = try self.nextIqId(allocator);
        defer allocator.free(id);

        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<iq type='set' to='");
        try xml.writeEscapedAttr(&out.writer, room_jid);
        try out.writer.writeAll("' id='");
        try out.writer.writeAll(id);
        try out.writer.writeAll("'><query xmlns='http://jabber.org/protocol/muc#admin'><item jid='");
        try xml.writeEscapedAttr(&out.writer, real_jid);
        try out.writer.writeAll("' affiliation='");
        try xml.writeEscapedAttr(&out.writer, affiliation);
        try out.writer.writeAll("'/></query></iq>");
        try self.sendRaw(out.writer.buffered());
    }

    /// Replies to a server-initiated `<iq type='get'>` carrying a
    /// `<ping xmlns='urn:xmpp:ping'/>` (XEP-0199) with an empty result.
    pub fn replyIqPing(self: *Client, allocator: std.mem.Allocator, to: []const u8, id: []const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<iq type='result' to='");
        try xml.writeEscapedAttr(&out.writer, to);
        try out.writer.writeAll("' id='");
        try xml.writeEscapedAttr(&out.writer, id);
        try out.writer.writeAll("'/>");
        try self.sendRaw(out.writer.buffered());
    }

    /// Catch-all reply for any other server-initiated `<iq type='get'/ set'>`
    /// this connector doesn't implement (disco#info/#items, vCard fetches, ...).
    pub fn replyIqUnsupported(self: *Client, allocator: std.mem.Allocator, to: []const u8, id: []const u8) !void {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.writeAll("<iq type='error' to='");
        try xml.writeEscapedAttr(&out.writer, to);
        try out.writer.writeAll("' id='");
        try xml.writeEscapedAttr(&out.writer, id);
        try out.writer.writeAll("'><error type='cancel'><feature-not-implemented xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>");
        try self.sendRaw(out.writer.buffered());
    }

    /// Auto-accepts an incoming presence subscription request (`<presence
    /// type='subscribe'>`).
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
// server.
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

    try client.startTls(.insecure);

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

test "Client.scramEscapeName escapes ',' and '=' per RFC 5802 5.1" {
    const escaped = try Client.scramEscapeName(testing.allocator, "a=b,c");
    defer testing.allocator.free(escaped);
    try testing.expectEqualStrings("a=3Db=2Cc", escaped);
}

test "Client.parseScramChallenge extracts nonce/salt/iterations, rejects an 'm=' extension" {
    const c = try Client.parseScramChallenge("r=abc123,s=c2FsdA==,i=4096");
    try testing.expectEqualStrings("abc123", c.nonce);
    try testing.expectEqualStrings("c2FsdA==", c.salt_b64);
    try testing.expectEqual(@as(u32, 4096), c.iterations);

    try testing.expectError(error.ScramUnsupportedExtension, Client.parseScramChallenge("r=abc,s=c2FsdA==,i=4096,m=unknown"));
    try testing.expectError(error.ScramMalformedChallenge, Client.parseScramChallenge("r=abc,s=c2FsdA=="));
}

// RFC 5802 §5's worked example — the canonical SCRAM-SHA-1 known-answer test,
// run against `scramComputeProof` directly.
test "Client.scramComputeProof matches RFC 5802's SCRAM-SHA-1 worked example" {
    const salt = try Client.b64Decode(testing.allocator, "QSXCR+Q6sek8bf92");
    defer testing.allocator.free(salt);

    const proof = try Client.scramComputeProof(
        testing.allocator,
        std.crypto.auth.hmac.HmacSha1,
        std.crypto.hash.Sha1,
        "pencil",
        salt,
        4096,
        "n=user,r=fyko+d2lbbFgONRv9qkxdawL",
        "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096",
        "fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j",
    );
    defer proof.deinit(testing.allocator);

    try testing.expectEqualStrings("c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=", proof.client_final);
    try testing.expectEqualStrings("rmF9pqV8S7suAoZWja4dJRkFsKQ=", proof.expected_server_signature_b64);
}

// AUDIT-2026-09-03 CONN-1: this used to be `panic: reached unreachable code`
// inside `Io.Reader.defaultRebase`.
test "readElement refuses a stanza too large for its buffer instead of aborting" {
    var address = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(testing.io, .{ .reuse_address = true });
    defer listener.deinit(testing.io);
    const port = listener.socket.address.getPort();

    // Sends the opening of a stanza it never closes, a little past the read
    // buffer, then closes.
    const feeder = struct {
        fn run(l: *Io.net.Server, io: Io) void {
            const stream = l.accept(io) catch return;
            defer stream.close(io);
            var buf: [4096]u8 = undefined;
            var w = stream.writer(io, &buf);
            w.interface.writeAll("<message to='warden@localhost'><body>") catch return;
            var written: usize = 0;
            while (written < buffer_size + 4096) : (written += 1024) {
                w.interface.writeAll("x" ** 1024) catch return;
            }
            w.interface.flush() catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, feeder.run, .{ &listener, testing.io });
    defer thread.join();

    const client = try Client.connect(testing.allocator, testing.io, "127.0.0.1", port);
    defer client.deinit();
    try testing.expectError(error.StanzaTooLarge, client.readElement(testing.allocator));
}
