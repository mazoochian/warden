//! Outbound `<message>` serialization and the inbound extensions the
//! connector reads off a parsed `<message>` (ids, replies, corrections,
//! out-of-band URLs, OMEMO payloads).
const std = @import("std");
const xml = @import("xml.zig");

pub const ns_origin_id = "urn:xmpp:sid:0";
pub const ns_correct = "urn:xmpp:message-correct:0";
pub const ns_reply = "urn:xmpp:reply:0";
pub const ns_oob = "jabber:x:oob";
pub const ns_retract = "urn:xmpp:message-retract:1";
pub const ns_retract_legacy = "urn:xmpp:message-retract:0";
pub const ns_fasten = "urn:xmpp:fasten:0";
pub const ns_fallback = "urn:xmpp:fallback:0";
pub const ns_hints = "urn:xmpp:hints";
pub const ns_eme = "urn:xmpp:eme:0";
pub const ns_omemo = "eu.siacs.conversations.axolotl";

pub const retract_fallback_body = "This message was deleted.";
pub const omemo_fallback_body = "I sent you an OMEMO encrypted message but your client doesn't seem to support that.";

pub const OutMessage = struct {
    to: []const u8,
    /// "chat" or "groupchat".
    kind: []const u8,
    id: []const u8,
    body: ?[]const u8 = null,
    /// XEP-0308: id of the original message this one replaces.
    replace_id: ?[]const u8 = null,
    /// XEP-0461 reply target.
    reply_to_id: ?[]const u8 = null,
    reply_to_jid: ?[]const u8 = null,
    /// XEP-0066: the file URL this message shares (body should repeat it).
    oob_url: ?[]const u8 = null,
    /// XEP-0424: id of the message to retract (adds the fallback body).
    retract_id: ?[]const u8 = null,
    /// Pre-serialized `<encrypted>` element; also adds the EME/store hints.
    encrypted_xml: ?[]const u8 = null,
};

pub fn writeMessage(w: *std.Io.Writer, m: OutMessage) !void {
    try w.writeAll("<message to='");
    try xml.writeEscapedAttr(w, m.to);
    try w.writeAll("' type='");
    try xml.writeEscapedAttr(w, m.kind);
    try w.writeAll("' id='");
    try xml.writeEscapedAttr(w, m.id);
    try w.writeAll("'>");

    const body: ?[]const u8 = m.body orelse if (m.retract_id != null) retract_fallback_body else if (m.encrypted_xml != null) omemo_fallback_body else null;
    if (body) |b| {
        try w.writeAll("<body>");
        try xml.writeEscapedText(w, b);
        try w.writeAll("</body>");
    }
    try w.writeAll("<origin-id xmlns='" ++ ns_origin_id ++ "' id='");
    try xml.writeEscapedAttr(w, m.id);
    try w.writeAll("'/>");

    if (m.replace_id) |rid| {
        try w.writeAll("<replace xmlns='" ++ ns_correct ++ "' id='");
        try xml.writeEscapedAttr(w, rid);
        try w.writeAll("'/>");
    }
    if (m.reply_to_id) |rid| {
        try w.writeAll("<reply xmlns='" ++ ns_reply ++ "' id='");
        try xml.writeEscapedAttr(w, rid);
        if (m.reply_to_jid) |to| {
            try w.writeAll("' to='");
            try xml.writeEscapedAttr(w, to);
        }
        try w.writeAll("'/>");
    }
    if (m.oob_url) |url| {
        try w.writeAll("<x xmlns='" ++ ns_oob ++ "'><url>");
        try xml.writeEscapedText(w, url);
        try w.writeAll("</url></x>");
    }
    if (m.retract_id) |rid| {
        // Both the current and the fastening-based legacy form, for older clients.
        try w.writeAll("<retract xmlns='" ++ ns_retract ++ "' id='");
        try xml.writeEscapedAttr(w, rid);
        try w.writeAll("'/><apply-to xmlns='" ++ ns_fasten ++ "' id='");
        try xml.writeEscapedAttr(w, rid);
        try w.writeAll("'><retract xmlns='" ++ ns_retract_legacy ++ "'/></apply-to>");
        try w.writeAll("<fallback xmlns='" ++ ns_fallback ++ "' for='" ++ ns_retract ++ "'/>");
    }
    if (m.encrypted_xml) |enc| {
        try w.writeAll(enc);
        try w.writeAll("<encryption xmlns='" ++ ns_eme ++ "' namespace='" ++ ns_omemo ++ "' name='OMEMO'/>");
    }
    if (m.encrypted_xml != null or m.retract_id != null) {
        try w.writeAll("<store xmlns='" ++ ns_hints ++ "'/>");
    }
    try w.writeAll("</message>");
}

pub fn messageToOwned(allocator: std.mem.Allocator, m: OutMessage) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeMessage(&out.writer, m);
    return out.toOwnedSlice();
}

/// First direct child named `name` whose `xmlns` is `ns`.
pub fn childNs(el: xml.Element, name: []const u8, ns: []const u8) ?xml.Element {
    for (el.children) |node| switch (node) {
        .element => |e| if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.attr("xmlns") orelse "", ns)) return e,
        .text => {},
    };
    return null;
}

/// The XMPP extensions of one inbound `<message>` the connector acts on.
/// Every slice borrows from the parsed element.
pub const Inbound = struct {
    id: ?[]const u8 = null,
    origin_id: ?[]const u8 = null,
    /// XEP-0359 id assigned by `stanza_id_by` (a MUC room, or our own account).
    stanza_id: ?[]const u8 = null,
    stanza_id_by: ?[]const u8 = null,
    replace_id: ?[]const u8 = null,
    reply_to_id: ?[]const u8 = null,
    reply_to_jid: ?[]const u8 = null,
    oob_url: ?[]const u8 = null,
    encrypted: ?xml.Element = null,
    has_delay: bool = false,
    is_error: bool = false,

    pub fn read(el: xml.Element) Inbound {
        var in: Inbound = .{
            .id = el.attr("id"),
            .is_error = std.mem.eql(u8, el.attr("type") orelse "", "error"),
        };
        for (el.children) |node| switch (node) {
            .element => |e| {
                const ns = e.attr("xmlns") orelse "";
                if (std.mem.eql(u8, e.name, "origin-id") and std.mem.eql(u8, ns, ns_origin_id)) {
                    in.origin_id = e.attr("id");
                } else if (std.mem.eql(u8, e.name, "stanza-id") and std.mem.eql(u8, ns, ns_origin_id)) {
                    in.stanza_id = e.attr("id");
                    in.stanza_id_by = e.attr("by");
                } else if (std.mem.eql(u8, e.name, "replace") and std.mem.eql(u8, ns, ns_correct)) {
                    in.replace_id = e.attr("id");
                } else if (std.mem.eql(u8, e.name, "reply") and std.mem.eql(u8, ns, ns_reply)) {
                    in.reply_to_id = e.attr("id");
                    in.reply_to_jid = e.attr("to");
                } else if (std.mem.eql(u8, e.name, "x") and std.mem.eql(u8, ns, ns_oob)) {
                    if (e.child("url")) |u| in.oob_url = firstText(u);
                } else if (std.mem.eql(u8, e.name, "encrypted") and std.mem.eql(u8, ns, ns_omemo)) {
                    in.encrypted = e;
                } else if (std.mem.eql(u8, e.name, "delay")) {
                    in.has_delay = true;
                }
            },
            .text => {},
        };
        return in;
    }

    /// The id other clients use to refer to this message: origin-id first,
    /// then the stanza `id` attribute.
    pub fn referenceId(self: Inbound) ?[]const u8 {
        return self.origin_id orelse self.id;
    }
};

/// The element's single text node, borrowed (no entity re-decoding needed:
/// the parser already decoded it).
pub fn firstText(el: xml.Element) ?[]const u8 {
    for (el.children) |node| switch (node) {
        .text => |t| return std.mem.trim(u8, t, " \t\r\n"),
        .element => {},
    };
    return null;
}

const testing = std.testing;

fn render(m: OutMessage) ![]u8 {
    return messageToOwned(testing.allocator, m);
}

test "writeMessage emits body and origin-id, escaping both" {
    const s = try render(.{ .to = "a@b.c", .kind = "chat", .id = "x1", .body = "1 < 2 & 'q'" });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(
        "<message to='a@b.c' type='chat' id='x1'><body>1 &lt; 2 &amp; 'q'</body><origin-id xmlns='urn:xmpp:sid:0' id='x1'/></message>",
        s,
    );
}

test "writeMessage adds a correction and reply reference" {
    const s = try render(.{ .to = "r@muc", .kind = "groupchat", .id = "x2", .body = "fixed", .replace_id = "x1", .reply_to_id = "m9", .reply_to_jid = "r@muc/alice" });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "<replace xmlns='urn:xmpp:message-correct:0' id='x1'/>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<reply xmlns='urn:xmpp:reply:0' id='m9' to='r@muc/alice'/>") != null);
}

test "writeMessage retraction carries both forms, a fallback body and a store hint" {
    const s = try render(.{ .to = "a@b.c", .kind = "chat", .id = "x3", .retract_id = "x1" });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "<body>This message was deleted.</body>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<retract xmlns='urn:xmpp:message-retract:1' id='x1'/>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<apply-to xmlns='urn:xmpp:fasten:0' id='x1'><retract xmlns='urn:xmpp:message-retract:0'/></apply-to>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<store xmlns='urn:xmpp:hints'/>") != null);
}

test "writeMessage oob shares a URL" {
    const s = try render(.{ .to = "a@b.c", .kind = "chat", .id = "x4", .body = "https://u/f.png", .oob_url = "https://u/f.png" });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "<x xmlns='jabber:x:oob'><url>https://u/f.png</url></x>") != null);
}

test "Inbound.read picks up ids, reply, correction, oob and delay" {
    var parsed = try xml.parseElement(testing.allocator,
        \\<message from='r@muc/bob' type='groupchat' id='a1'>
        \\<body>hi</body>
        \\<origin-id xmlns='urn:xmpp:sid:0' id='o1'/>
        \\<stanza-id xmlns='urn:xmpp:sid:0' id='s1' by='r@muc'/>
        \\<replace xmlns='urn:xmpp:message-correct:0' id='old'/>
        \\<reply xmlns='urn:xmpp:reply:0' id='m7' to='r@muc/warden'/>
        \\<x xmlns='jabber:x:oob'><url> https://up/x.m4a </url></x>
        \\<delay xmlns='urn:xmpp:delay' stamp='2026-01-01T00:00:00Z'/>
        \\</message>
    );
    defer parsed.deinit();
    const in = Inbound.read(parsed.element);
    try testing.expectEqualStrings("a1", in.id.?);
    try testing.expectEqualStrings("o1", in.referenceId().?);
    try testing.expectEqualStrings("s1", in.stanza_id.?);
    try testing.expectEqualStrings("r@muc", in.stanza_id_by.?);
    try testing.expectEqualStrings("old", in.replace_id.?);
    try testing.expectEqualStrings("m7", in.reply_to_id.?);
    try testing.expectEqualStrings("r@muc/warden", in.reply_to_jid.?);
    try testing.expectEqualStrings("https://up/x.m4a", in.oob_url.?);
    try testing.expect(in.has_delay);
    try testing.expect(!in.is_error);
}
