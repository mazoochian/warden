//! Typed extraction helpers layered on top of `xml.zig`'s generic `Element`
//! tree — for the handful of stanza shapes `xmpp/client.zig`'s protocol
//! state machine actually needs to react to (stream features, SASL
//! outcomes, resource binding, chat/groupchat messages). Every function
//! here takes an already-parsed `xml.Element` and dupes what it needs into
//! `allocator`, independent of the `xml.ParsedElement` arena the caller will
//! typically `deinit()` right after — mirrors `matrix/types.zig`'s role as
//! the typed layer above a lower-level parse (JSON there, hand-rolled XML
//! here).

const std = @import("std");
const xml = @import("xml.zig");

/// `<stream:features>` — just the four things the connection state machine
/// (`client.zig`) reacts to across the stream's three (re)negotiations
/// (post-connect, post-STARTTLS, post-SASL).
pub const StreamFeatures = struct {
    starttls: bool,
    mechanisms: []const []const u8,
    bind: bool,
    session: bool,

    pub fn fromElement(allocator: std.mem.Allocator, el: xml.Element) !StreamFeatures {
        var mechanisms: std.ArrayList([]const u8) = .empty;
        if (el.child("mechanisms")) |mechs| {
            for (mechs.children) |node| switch (node) {
                .element => |e| if (std.mem.eql(u8, e.name, "mechanism")) {
                    try mechanisms.append(allocator, try e.text(allocator));
                },
                .text => {},
            };
        }
        return .{
            .starttls = el.child("starttls") != null,
            .mechanisms = try mechanisms.toOwnedSlice(allocator),
            .bind = el.child("bind") != null,
            .session = el.child("session") != null,
        };
    }

    pub fn hasMechanism(self: StreamFeatures, name: []const u8) bool {
        for (self.mechanisms) |m| if (std.mem.eql(u8, m, name)) return true;
        return false;
    }
};

/// A `<success/>` or `<failure>...</failure>` in response to `<auth>` — the
/// failure's reason is the tag name of its single child per RFC 6120 (e.g.
/// `<not-authorized/>`), not text content.
pub const SaslOutcome = union(enum) {
    success,
    failure: []const u8,
};

pub fn parseSaslOutcome(allocator: std.mem.Allocator, el: xml.Element) !SaslOutcome {
    if (std.mem.eql(u8, el.name, "success")) return .success;
    for (el.children) |node| switch (node) {
        .element => |e| return .{ .failure = try allocator.dupe(u8, e.name) },
        .text => {},
    };
    return .{ .failure = try allocator.dupe(u8, "unknown") };
}

/// Extracts the bound full JID from a resource-binding `<iq type='result'>`
/// response (`<iq><bind><jid>...</jid></bind></iq>`). Null if `el` isn't
/// shaped like one (e.g. an error IQ instead).
pub fn boundJid(allocator: std.mem.Allocator, el: xml.Element) !?[]const u8 {
    const bind = el.child("bind") orelse return null;
    const jid_el = bind.child("jid") orelse return null;
    return try jid_el.text(allocator);
}

/// A `<message>` stanza carrying a `<body>` — the shape both 1:1 (`type=
/// "chat"`) and MUC (`type="groupchat"`) messages share; `client.zig` tells
/// them apart via `type`, since MUC's `from` is `room@server/nick` rather
/// than a real user JID (semi-anonymous by default) but the wire shape is
/// otherwise identical.
pub const MessageStanza = struct {
    from: []const u8,
    /// Absent on the wire defaults to "normal" per RFC 6121 — never left
    /// null here so callers don't need to remember that default themselves.
    type: []const u8,
    /// Null when this is some other kind of `<message>` (e.g. a
    /// receipt/chat-state notification with no `<body>`) — not every
    /// message stanza is one a human sent text in.
    body: ?[]const u8,
    id: ?[]const u8,

    pub fn fromElement(allocator: std.mem.Allocator, el: xml.Element) !?MessageStanza {
        const from = el.attr("from") orelse return null;
        return .{
            .from = try allocator.dupe(u8, from),
            .type = try allocator.dupe(u8, el.attr("type") orelse "normal"),
            .body = if (el.child("body")) |b| try b.text(allocator) else null,
            .id = if (el.attr("id")) |i| try allocator.dupe(u8, i) else null,
        };
    }
};

const testing = std.testing;

test "StreamFeatures.fromElement reads starttls, mechanisms, bind, and session" {
    var parsed = try xml.parseElement(testing.allocator,
        \\<stream:features>
        \\  <starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>
        \\  <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>
        \\    <mechanism>SCRAM-SHA-1</mechanism>
        \\    <mechanism>PLAIN</mechanism>
        \\  </mechanisms>
        \\</stream:features>
    );
    defer parsed.deinit();

    const features = try StreamFeatures.fromElement(testing.allocator, parsed.element);
    defer {
        for (features.mechanisms) |m| testing.allocator.free(m);
        testing.allocator.free(features.mechanisms);
    }
    try testing.expect(features.starttls);
    try testing.expect(!features.bind);
    try testing.expect(!features.session);
    try testing.expect(features.hasMechanism("PLAIN"));
    try testing.expect(features.hasMechanism("SCRAM-SHA-1"));
    try testing.expect(!features.hasMechanism("ANONYMOUS"));
}

test "StreamFeatures.fromElement reads bind+session with no mechanisms" {
    var parsed = try xml.parseElement(testing.allocator,
        "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></stream:features>",
    );
    defer parsed.deinit();

    const features = try StreamFeatures.fromElement(testing.allocator, parsed.element);
    defer testing.allocator.free(features.mechanisms);
    try testing.expect(features.bind);
    try testing.expect(features.session);
    try testing.expect(!features.starttls);
    try testing.expectEqual(@as(usize, 0), features.mechanisms.len);
}

test "parseSaslOutcome recognizes success and extracts the failure reason tag" {
    var success_parsed = try xml.parseElement(testing.allocator, "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>");
    defer success_parsed.deinit();
    switch (try parseSaslOutcome(testing.allocator, success_parsed.element)) {
        .success => {},
        .failure => try testing.expect(false),
    }

    var failure_parsed = try xml.parseElement(testing.allocator,
        "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>",
    );
    defer failure_parsed.deinit();
    switch (try parseSaslOutcome(testing.allocator, failure_parsed.element)) {
        .success => try testing.expect(false),
        .failure => |reason| {
            defer testing.allocator.free(reason);
            try testing.expectEqualStrings("not-authorized", reason);
        },
    }
}

test "boundJid extracts the bound JID from a bind result IQ" {
    var parsed = try xml.parseElement(testing.allocator,
        "<iq type='result' id='bind1'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>test@localhost/warden</jid></bind></iq>",
    );
    defer parsed.deinit();

    const jid = (try boundJid(testing.allocator, parsed.element)).?;
    defer testing.allocator.free(jid);
    try testing.expectEqualStrings("test@localhost/warden", jid);
}

test "boundJid returns null for an IQ with no bind child" {
    var parsed = try xml.parseElement(testing.allocator, "<iq type='error' id='bind1'/>");
    defer parsed.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try boundJid(testing.allocator, parsed.element));
}

test "MessageStanza.fromElement extracts a chat message's body" {
    var parsed = try xml.parseElement(testing.allocator,
        "<message from='alice@localhost/phone' to='warden@localhost' type='chat' id='m1'><body>hi there</body></message>",
    );
    defer parsed.deinit();

    const stanza = (try MessageStanza.fromElement(testing.allocator, parsed.element)).?;
    defer {
        testing.allocator.free(stanza.from);
        testing.allocator.free(stanza.type);
        testing.allocator.free(stanza.body.?);
        testing.allocator.free(stanza.id.?);
    }
    try testing.expectEqualStrings("alice@localhost/phone", stanza.from);
    try testing.expectEqualStrings("chat", stanza.type);
    try testing.expectEqualStrings("hi there", stanza.body.?);
}

test "MessageStanza.fromElement defaults type to normal and body to null when absent" {
    var parsed = try xml.parseElement(testing.allocator, "<message from='a@b'/>");
    defer parsed.deinit();

    const stanza = (try MessageStanza.fromElement(testing.allocator, parsed.element)).?;
    defer {
        testing.allocator.free(stanza.from);
        testing.allocator.free(stanza.type);
    }
    try testing.expectEqualStrings("normal", stanza.type);
    try testing.expectEqual(@as(?[]const u8, null), stanza.body);
}

test "MessageStanza.fromElement returns null without a from attribute" {
    var parsed = try xml.parseElement(testing.allocator, "<message type='chat'/>");
    defer parsed.deinit();
    try testing.expectEqual(@as(?MessageStanza, null), try MessageStanza.fromElement(testing.allocator, parsed.element));
}
