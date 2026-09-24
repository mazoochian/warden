//! Matrix interactive (SAS/emoji) device verification, `m.key.verification.*`
//! — the protocol logic layered on top of `olm.zig`'s `Sas` binding.

const std = @import("std");
const olm = @import("olm.zig");

/// One in-flight verification ceremony, keyed by `transaction_id` on
/// `crypto.zig`'s `State.verifications` map.
pub const VerificationSession = struct {
    their_user_id: []const u8,
    their_device_id: []const u8,
    /// Pinned once, at `.request` time, from a fresh `/keys/query` — never re-
    /// resolved mid-ceremony.
    their_ed25519: []const u8,
    /// Literal bytes of the `m.key.verification.start` content this device sent —
    /// needed verbatim (not re-serialized) for the later commitment check.
    sent_start_json: []const u8,
    our_pubkey: []const u8,
    sas: olm.Sas,
    created_at_unix: i64,
    state: enum { ready_sent, accept_received, key_sent, mac_sent },
    /// Set once `m.key.verification.accept` arrives — `null` until then.
    their_commitment: ?[]const u8 = null,
    /// Whether `accept` negotiated emoji display (vs. falling back to
    /// decimal-only, if the other side didn't offer emoji).
    use_emoji: bool = true,

    pub fn deinit(self: *VerificationSession, allocator: std.mem.Allocator) void {
        allocator.free(self.their_user_id);
        allocator.free(self.their_device_id);
        allocator.free(self.their_ed25519);
        allocator.free(self.sent_start_json);
        allocator.free(self.our_pubkey);
        if (self.their_commitment) |c| allocator.free(c);
        self.sas.deinit(allocator);
        self.* = undefined;
    }
};

/// A verification ceremony older than this is abandoned — swept lazily by
/// `crypto.zig`'s handlers on each new verification event.
pub const session_max_age_s: i64 = 10 * std.time.s_per_min;

/// `base64_unpadded(SHA256(their_ephemeral_key_b64 || start_content_json))` —
/// the `m.key.verification.accept` `commitment` field.
pub fn commitment(allocator: std.mem.Allocator, their_key_b64: []const u8, start_json: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(their_key_b64);
    hasher.update(start_json);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    const encoder = std.base64.standard_no_pad.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(digest.len));
    return @constCast(encoder.encode(out, &digest));
}

/// The exact `MATRIX_KEY_VERIFICATION_SAS|...` HKDF info string the spec
/// defines, pipe-delimited.
pub fn sasInfo(
    allocator: std.mem.Allocator,
    starter_user: []const u8,
    starter_device: []const u8,
    starter_key_b64: []const u8,
    accepter_user: []const u8,
    accepter_device: []const u8,
    accepter_key_b64: []const u8,
    transaction_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "MATRIX_KEY_VERIFICATION_SAS|{s}|{s}|{s}|{s}|{s}|{s}|{s}",
        .{ starter_user, starter_device, starter_key_b64, accepter_user, accepter_device, accepter_key_b64, transaction_id },
    );
}

/// The exact `MATRIX_KEY_VERIFICATION_MAC...` HKDF info string.
pub fn macInfo(
    allocator: std.mem.Allocator,
    mac_sender_user: []const u8,
    mac_sender_device: []const u8,
    mac_recipient_user: []const u8,
    mac_recipient_device: []const u8,
    transaction_id: []const u8,
    key_id_or_key_ids: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "MATRIX_KEY_VERIFICATION_MAC{s}{s}{s}{s}{s}{s}",
        .{ mac_sender_user, mac_sender_device, mac_recipient_user, mac_recipient_device, transaction_id, key_id_or_key_ids },
    );
}

pub const EmojiEntry = struct { emoji: []const u8, description: []const u8 };

/// The official 64-entry SAS emoji table, in index order (0-63) — `data-
/// definitions/sas-emoji.json` at spec.matrix.org.
pub const emoji_table = [64]EmojiEntry{
    .{ .emoji = "🐶", .description = "Dog" },
    .{ .emoji = "🐱", .description = "Cat" },
    .{ .emoji = "🦁", .description = "Lion" },
    .{ .emoji = "🐎", .description = "Horse" },
    .{ .emoji = "🦄", .description = "Unicorn" },
    .{ .emoji = "🐷", .description = "Pig" },
    .{ .emoji = "🐘", .description = "Elephant" },
    .{ .emoji = "🐰", .description = "Rabbit" },
    .{ .emoji = "🐼", .description = "Panda" },
    .{ .emoji = "🐓", .description = "Rooster" },
    .{ .emoji = "🐧", .description = "Penguin" },
    .{ .emoji = "🐢", .description = "Turtle" },
    .{ .emoji = "🐟", .description = "Fish" },
    .{ .emoji = "🐙", .description = "Octopus" },
    .{ .emoji = "🦋", .description = "Butterfly" },
    .{ .emoji = "🌷", .description = "Flower" },
    .{ .emoji = "🌳", .description = "Tree" },
    .{ .emoji = "🌵", .description = "Cactus" },
    .{ .emoji = "🍄", .description = "Mushroom" },
    .{ .emoji = "🌏", .description = "Globe" },
    .{ .emoji = "🌙", .description = "Moon" },
    .{ .emoji = "☁️", .description = "Cloud" },
    .{ .emoji = "🔥", .description = "Fire" },
    .{ .emoji = "🍌", .description = "Banana" },
    .{ .emoji = "🍎", .description = "Apple" },
    .{ .emoji = "🍓", .description = "Strawberry" },
    .{ .emoji = "🌽", .description = "Corn" },
    .{ .emoji = "🍕", .description = "Pizza" },
    .{ .emoji = "🎂", .description = "Cake" },
    .{ .emoji = "❤️", .description = "Heart" },
    .{ .emoji = "😀", .description = "Smiley" },
    .{ .emoji = "🤖", .description = "Robot" },
    .{ .emoji = "🎩", .description = "Hat" },
    .{ .emoji = "👓", .description = "Glasses" },
    .{ .emoji = "🔧", .description = "Spanner" },
    .{ .emoji = "🎅", .description = "Santa" },
    .{ .emoji = "👍", .description = "Thumbs Up" },
    .{ .emoji = "☂️", .description = "Umbrella" },
    .{ .emoji = "⌛", .description = "Hourglass" },
    .{ .emoji = "⏰", .description = "Clock" },
    .{ .emoji = "🎁", .description = "Gift" },
    .{ .emoji = "💡", .description = "Light Bulb" },
    .{ .emoji = "📕", .description = "Book" },
    .{ .emoji = "✏️", .description = "Pencil" },
    .{ .emoji = "📎", .description = "Paperclip" },
    .{ .emoji = "✂️", .description = "Scissors" },
    .{ .emoji = "🔒", .description = "Lock" },
    .{ .emoji = "🔑", .description = "Key" },
    .{ .emoji = "🔨", .description = "Hammer" },
    .{ .emoji = "☎️", .description = "Telephone" },
    .{ .emoji = "🏁", .description = "Flag" },
    .{ .emoji = "🚂", .description = "Train" },
    .{ .emoji = "🚲", .description = "Bicycle" },
    .{ .emoji = "✈️", .description = "Aeroplane" },
    .{ .emoji = "🚀", .description = "Rocket" },
    .{ .emoji = "🏆", .description = "Trophy" },
    .{ .emoji = "⚽", .description = "Ball" },
    .{ .emoji = "🎸", .description = "Guitar" },
    .{ .emoji = "🎺", .description = "Trumpet" },
    .{ .emoji = "🔔", .description = "Bell" },
    .{ .emoji = "⚓", .description = "Anchor" },
    .{ .emoji = "🎧", .description = "Headphones" },
    .{ .emoji = "📁", .description = "Folder" },
    .{ .emoji = "📌", .description = "Pin" },
};

/// Splits 6 bytes (48 bits) into 7 six-bit indices.
pub fn formatSas(allocator: std.mem.Allocator, bytes: [6]u8) ![]u8 {
    const indices = [7]u8{
        bytes[0] >> 2,
        ((bytes[0] & 0x3) << 4) | (bytes[1] >> 4),
        ((bytes[1] & 0xF) << 2) | (bytes[2] >> 6),
        bytes[2] & 0x3F,
        bytes[3] >> 2,
        ((bytes[3] & 0x3) << 4) | (bytes[4] >> 4),
        ((bytes[4] & 0xF) << 2) | (bytes[5] >> 6),
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (indices, 0..) |idx, i| {
        if (i != 0) try out.writer.writeAll(", ");
        const entry = emoji_table[idx];
        try out.writer.print("{s} {s}", .{ entry.emoji, entry.description });
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "commitment matches an independently computed SHA256+base64 value" {
    // Independently verified via `python3 -c "import hashlib, base64; print(base64.b64encode(hashlib.sha256(b'bob-pubkey-b64' + b'{\"foo\":\"bar\"}').digest()).decode().rstrip('='))"`.
    const c = try commitment(testing.allocator, "bob-pubkey-b64", "{\"foo\":\"bar\"}");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("8BISV0OByxewGDBQ6Yn5Y3b0lmFBdo0o42PKqHTlnpI", c);
}

test "sasInfo builds the exact pipe-delimited MATRIX_KEY_VERIFICATION_SAS string" {
    const info = try sasInfo(testing.allocator, "@bot:server", "BOTDEVICE", "botkey", "@alice:server", "ALICEDEVICE", "alicekey", "txn123");
    defer testing.allocator.free(info);
    try testing.expectEqualStrings("MATRIX_KEY_VERIFICATION_SAS|@bot:server|BOTDEVICE|botkey|@alice:server|ALICEDEVICE|alicekey|txn123", info);
}

test "macInfo concatenates with no delimiters" {
    const info = try macInfo(testing.allocator, "@bot:server", "BOTDEVICE", "@alice:server", "ALICEDEVICE", "txn123", "KEY_IDS");
    defer testing.allocator.free(info);
    try testing.expectEqualStrings("MATRIX_KEY_VERIFICATION_MAC@bot:serverBOTDEVICE@alice:serverALICEDEVICEtxn123KEY_IDS", info);

    const info2 = try macInfo(testing.allocator, "@bot:server", "BOTDEVICE", "@alice:server", "ALICEDEVICE", "txn123", "ed25519:BOTDEVICE");
    defer testing.allocator.free(info2);
    try testing.expectEqualStrings("MATRIX_KEY_VERIFICATION_MAC@bot:serverBOTDEVICE@alice:serverALICEDEVICEtxn123ed25519:BOTDEVICE", info2);
}

test "formatSas produces 7 emoji from 6 bytes, using the top 42 bits" {
    // All-zero bytes -> index 0 seven times -> "Dog" repeated.
    const zeros = try formatSas(testing.allocator, .{ 0, 0, 0, 0, 0, 0 });
    defer testing.allocator.free(zeros);
    try testing.expectEqualStrings("🐶 Dog, 🐶 Dog, 🐶 Dog, 🐶 Dog, 🐶 Dog, 🐶 Dog, 🐶 Dog", zeros);

    // 0xFF repeated -> every 6-bit group is 0b111111 = 63 -> index 63 (last entry) seven times.
    const ones = try formatSas(testing.allocator, .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    defer testing.allocator.free(ones);
    const expected_last = emoji_table[63];
    var expected_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_buf.deinit();
    for (0..7) |i| {
        if (i != 0) try expected_buf.writer.writeAll(", ");
        try expected_buf.writer.print("{s} {s}", .{ expected_last.emoji, expected_last.description });
    }
    try testing.expectEqualStrings(expected_buf.writer.buffered(), ones);
}
