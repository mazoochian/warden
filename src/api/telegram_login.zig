//! Telegram Login Widget verification — see
//! /home/armin/claude/warden-ui/ARCHITECTURE.md §3.1 for why this is its
//! own hand-rolled algorithm (Telegram's own documented scheme) rather
//! than OAuth2/OIDC: the widget posts back a signed payload directly,
//! verified here via HMAC-SHA256 keyed by `SHA256(bot_token)` over the
//! sorted `key=value` fields, per Telegram's own docs
//! (https://core.telegram.org/widgets/login#checking-authorization).
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Payload = struct {
    id: i64,
    first_name: []const u8,
    last_name: ?[]const u8 = null,
    username: ?[]const u8 = null,
    photo_url: ?[]const u8 = null,
    auth_date: i64,
    hash: []const u8,
};

/// `false` if `payload.hash` doesn't match the fields, or `payload.auth_date`
/// is in the future or older than `max_age_seconds` — the widget re-issues
/// `auth_date` on every load, so a stale one usually means a captured/
/// replayed payload rather than a legitimately slow page load.
pub fn verify(allocator: std.mem.Allocator, payload: Payload, bot_token: []const u8, now: i64, max_age_seconds: i64) !bool {
    if (payload.auth_date > now) return false;
    if (now - payload.auth_date > max_age_seconds) return false;

    const data_check_string = try buildDataCheckString(allocator, payload);
    defer allocator.free(data_check_string);

    var secret_key: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bot_token, &secret_key, .{});

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, data_check_string, &secret_key);
    const mac_hex = std.fmt.bytesToHex(mac, .lower);

    if (payload.hash.len != mac_hex.len) return false;
    var given_buf: [mac_hex.len]u8 = undefined;
    @memcpy(&given_buf, payload.hash);
    return std.crypto.timing_safe.eql([mac_hex.len]u8, mac_hex, given_buf);
}

/// Telegram's documented data-check-string: every received field except
/// `hash`, formatted as `key=value`, sorted alphabetically by key, joined
/// with `\n`. Fields not present in the payload are omitted entirely, not
/// sent as empty strings — the alphabetical field order here (auth_date,
/// first_name, id, last_name, photo_url, username) must match construction
/// order exactly.
fn buildDataCheckString(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    var pieces: std.ArrayList([]const u8) = .empty;
    defer {
        for (pieces.items) |p| allocator.free(p);
        pieces.deinit(allocator);
    }

    try pieces.append(allocator, try std.fmt.allocPrint(allocator, "auth_date={d}", .{payload.auth_date}));
    try pieces.append(allocator, try std.fmt.allocPrint(allocator, "first_name={s}", .{payload.first_name}));
    try pieces.append(allocator, try std.fmt.allocPrint(allocator, "id={d}", .{payload.id}));
    if (payload.last_name) |v| try pieces.append(allocator, try std.fmt.allocPrint(allocator, "last_name={s}", .{v}));
    if (payload.photo_url) |v| try pieces.append(allocator, try std.fmt.allocPrint(allocator, "photo_url={s}", .{v}));
    if (payload.username) |v| try pieces.append(allocator, try std.fmt.allocPrint(allocator, "username={s}", .{v}));

    return std.mem.join(allocator, "\n", pieces.items);
}

const testing = std.testing;

fn testSign(allocator: std.mem.Allocator, data_check_string: []const u8, bot_token: []const u8) ![]u8 {
    var secret_key: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bot_token, &secret_key, .{});
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, data_check_string, &secret_key);
    const hex = std.fmt.bytesToHex(mac, .lower);
    return allocator.dupe(u8, &hex);
}

test "verify accepts a correctly signed payload with every optional field present" {
    const a = testing.allocator;
    const bot_token = "123456:ABC-DEF";
    const data_check_string = "auth_date=1000\nfirst_name=Alice\nid=42\nlast_name=Smith\nphoto_url=https://t.me/a.jpg\nusername=alice";
    const hash = try testSign(a, data_check_string, bot_token);
    defer a.free(hash);

    const payload = Payload{
        .id = 42,
        .first_name = "Alice",
        .last_name = "Smith",
        .username = "alice",
        .photo_url = "https://t.me/a.jpg",
        .auth_date = 1000,
        .hash = hash,
    };

    try testing.expect(try verify(a, payload, bot_token, 1000, 86400));
}

test "verify accepts a correctly signed payload with optional fields omitted" {
    const a = testing.allocator;
    const bot_token = "123456:ABC-DEF";
    const data_check_string = "auth_date=1000\nfirst_name=Bob\nid=7";
    const hash = try testSign(a, data_check_string, bot_token);
    defer a.free(hash);

    const payload = Payload{
        .id = 7,
        .first_name = "Bob",
        .auth_date = 1000,
        .hash = hash,
    };

    try testing.expect(try verify(a, payload, bot_token, 1000, 86400));
}

test "verify rejects a tampered field (hash no longer matches)" {
    const a = testing.allocator;
    const bot_token = "123456:ABC-DEF";
    const data_check_string = "auth_date=1000\nfirst_name=Alice\nid=42";
    const hash = try testSign(a, data_check_string, bot_token);
    defer a.free(hash);

    // first_name changed after signing -- hash was computed for "Alice".
    const payload = Payload{
        .id = 42,
        .first_name = "Mallory",
        .auth_date = 1000,
        .hash = hash,
    };

    try testing.expect(!try verify(a, payload, bot_token, 1000, 86400));
}

test "verify rejects a signature produced with the wrong bot token" {
    const a = testing.allocator;
    const data_check_string = "auth_date=1000\nfirst_name=Alice\nid=42";
    const hash = try testSign(a, data_check_string, "wrong-token");
    defer a.free(hash);

    const payload = Payload{
        .id = 42,
        .first_name = "Alice",
        .auth_date = 1000,
        .hash = hash,
    };

    try testing.expect(!try verify(a, payload, "123456:ABC-DEF", 1000, 86400));
}

test "verify rejects a stale auth_date" {
    const a = testing.allocator;
    const bot_token = "123456:ABC-DEF";
    const data_check_string = "auth_date=1000\nfirst_name=Alice\nid=42";
    const hash = try testSign(a, data_check_string, bot_token);
    defer a.free(hash);

    const payload = Payload{
        .id = 42,
        .first_name = "Alice",
        .auth_date = 1000,
        .hash = hash,
    };

    // now = auth_date + max_age + 1 -- just past the allowed window.
    try testing.expect(!try verify(a, payload, bot_token, 1000 + 86400 + 1, 86400));
}

test "verify rejects an auth_date in the future" {
    const a = testing.allocator;
    const bot_token = "123456:ABC-DEF";
    const data_check_string = "auth_date=2000\nfirst_name=Alice\nid=42";
    const hash = try testSign(a, data_check_string, bot_token);
    defer a.free(hash);

    const payload = Payload{
        .id = 42,
        .first_name = "Alice",
        .auth_date = 2000,
        .hash = hash,
    };

    try testing.expect(!try verify(a, payload, bot_token, 1000, 86400));
}

test "verify rejects a hash of the wrong length" {
    const a = testing.allocator;
    const payload = Payload{
        .id = 42,
        .first_name = "Alice",
        .auth_date = 1000,
        .hash = "too-short",
    };
    try testing.expect(!try verify(a, payload, "123456:ABC-DEF", 1000, 86400));
}
