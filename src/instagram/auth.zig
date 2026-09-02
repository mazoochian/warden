//! Login / challenge / 2FA state machine for Instagram's private mobile-app
//! API, structurally mirroring `platform/telegram_user.zig`'s
//! `AuthState`/`AuthStepOutcome`/`submit*` shape (see that file's doc
//! comment) but with Instagram's own states: a plain username+password
//! login can come back `ready` immediately, or demand a challenge code
//! (SMS/email) or a 2FA code, each its own wait-state until the matching
//! `submit*` call resolves it.
//!
//! The exact endpoint paths and response field names below are this
//! implementation's best-effort current knowledge of Instagram's private
//! API (same class of reverse-engineered detail as
//! `transport.RotatingConstants`), NOT independently verified against live
//! Instagram servers or a freshly-cloned reference library -- this
//! development environment has no network access to do that. If a real
//! `/iglogin start` attempt fails with an unexpected response shape, that's
//! the first place to look, cross-checked against a current maintained
//! library's source (e.g. instagrapi's `mixins/auth.py`/`mixins/challenge.py`)
//! rather than assumed to be a bug in the surrounding state machine.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;
const crypto = @import("crypto.zig");
const transport = @import("transport.zig");
const log = @import("../log.zig").scoped("instagram");

pub const AuthState = enum {
    logged_out,
    wait_challenge_choice,
    wait_challenge_code,
    wait_2fa_code,
    ready,
};

/// Mirrors `telegram_user.zig`'s `AuthStepOutcome` exactly -- see that
/// type's doc comment for why a wrong code/password needs to report back
/// distinctly from a timeout instead of just silently not advancing.
pub const AuthStepOutcome = union(enum) {
    ok,
    rejected: []const u8,
    timed_out,
};

/// Instagram's `accounts/login/` response, most fields optional since which
/// ones are present depends entirely on which of "logged in outright",
/// "challenge required", or "2FA required" happened.
const LoginResponseShape = struct {
    logged_in: bool = false,
    user_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    challenge_api_path: ?[]const u8 = null,
    two_factor_identifier: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const AuthClient = struct {
    allocator: std.mem.Allocator,
    io: Io,
    client: http.Client,
    profile: transport.DeviceProfile,
    constants: transport.RotatingConstants,
    jar: transport.CookieJar,
    state: AuthState = .logged_out,
    self_user_id: ?[]const u8 = null,
    self_username: ?[]const u8 = null,
    /// Raw `challenge_api_path` Instagram's login response carried, needed
    /// to resubmit a challenge code against the right endpoint. Owned,
    /// duped onto `allocator`.
    challenge_api_path: ?[]const u8 = null,
    /// `two_factor_identifier` from a 2FA-required login response, needed
    /// to submit the follow-up 2FA code. Owned, duped onto `allocator`.
    two_factor_identifier: ?[]const u8 = null,
    /// The password submitted this login attempt -- held only in memory,
    /// only for the duration of a pending challenge/2FA step (Instagram's
    /// challenge-resolution and 2FA endpoints don't need it again, but some
    /// challenge sub-flows do ask for a fresh password confirmation).
    /// Zeroed and cleared the moment login resolves either way (`ready` or
    /// abandoned) -- never persisted, never logged.
    pending_password: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: Io, profile: transport.DeviceProfile, constants: transport.RotatingConstants) AuthClient {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .profile = profile,
            .constants = constants,
            .jar = transport.CookieJar.init(allocator),
        };
    }

    pub fn deinit(self: *AuthClient) void {
        self.client.deinit();
        self.jar.deinit();
        if (self.self_user_id) |s| self.allocator.free(s);
        if (self.self_username) |s| self.allocator.free(s);
        if (self.challenge_api_path) |s| self.allocator.free(s);
        if (self.two_factor_identifier) |s| self.allocator.free(s);
        self.clearPendingPassword();
    }

    fn clearPendingPassword(self: *AuthClient) void {
        if (self.pending_password) |p| {
            @memset(p, 0);
            self.allocator.free(p);
            self.pending_password = null;
        }
    }

    /// Restores a previously-persisted session (see `session.zig`) without
    /// any network round trip -- the connector calls this at startup, then
    /// treats a subsequent request's auth failure as "session actually
    /// invalid, needs a real re-login" rather than assuming it up front.
    pub fn restoreSession(self: *AuthClient, ig_user_id: []const u8, ig_username: []const u8, sessionid: []const u8, csrftoken: []const u8, mid: []const u8) !void {
        self.self_user_id = try self.allocator.dupe(u8, ig_user_id);
        self.self_username = try self.allocator.dupe(u8, ig_username);
        try self.jar.putOwned("sessionid", try self.allocator.dupe(u8, sessionid));
        try self.jar.putOwned("csrftoken", try self.allocator.dupe(u8, csrftoken));
        try self.jar.putOwned("mid", try self.allocator.dupe(u8, mid));
        self.state = .ready;
    }

    /// Bootstraps cookies (`mid`/`csrftoken`) via an ordinary unauthenticated
    /// request, same first step every login flow in this API family starts
    /// with, then returns the password-encryption key id/public key from
    /// config (`RotatingConstants.password_encryption_key_id`/
    /// `_pubkey_der_b64`) -- see that field's doc comment for why this isn't
    /// sourced from the bootstrap response itself in this environment.
    fn fetchPasswordPublicKey(self: *AuthClient) !struct { key_id: []const u8, public_key_der_b64: []const u8 } {
        const url = transport.base_url ++ "/si/fetch_headers/?challenge_type=signup&guid=00000000-0000-4000-8000-000000000000";
        const resp = try transport.request(self.io, self.allocator, &self.client, .GET, url, self.profile, self.constants, &self.jar, null);
        self.allocator.free(resp.body);

        if (self.constants.password_encryption_key_id.len == 0 or self.constants.password_encryption_pubkey_der_b64.len == 0) {
            return error.PasswordEncryptionKeyNotConfigured;
        }
        return .{ .key_id = self.constants.password_encryption_key_id, .public_key_der_b64 = self.constants.password_encryption_pubkey_der_b64 };
    }

    /// `#PWD_INSTAGRAM:4:<unix_ts>:<base64 envelope>` per the connector
    /// plan's crypto design -- AES-256-GCM-encrypts `password` (AAD = the
    /// timestamp string), RSA-PKCS1v1.5-encrypts the AES key, packs
    /// `0x01 | key_id_byte | u16-LE rsa_len | rsa_ciphertext | gcm_tag | iv |
    /// aes_ciphertext`, base64-encodes the whole envelope.
    fn buildEncPassword(self: *AuthClient, password: []const u8, key_id: []const u8, public_key_der_b64: []const u8) ![]const u8 {
        const a = self.allocator;
        const ts = Io.Timestamp.now(self.io, .real).toSeconds();
        var ts_buf: [24]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});

        var aes_key: [32]u8 = undefined;
        self.io.random(&aes_key);
        var iv: [12]u8 = undefined;
        self.io.random(&iv);

        const gcm = try crypto.gcmEncrypt(a, aes_key, iv, ts_str, password);
        defer a.free(gcm.ciphertext);

        const modulus = try a.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(public_key_der_b64) catch return error.InvalidPublicKey);
        defer a.free(modulus);
        std.base64.standard.Decoder.decode(modulus, public_key_der_b64) catch return error.InvalidPublicKey;

        const rsa_ciphertext = try crypto.rsaPkcs1v15Encrypt(self.io, a, modulus, 65537, &aes_key);
        defer a.free(rsa_ciphertext);

        const key_id_num = std.fmt.parseInt(u8, key_id, 10) catch 0;

        var envelope: std.Io.Writer.Allocating = .init(a);
        defer envelope.deinit();
        try envelope.writer.writeByte(0x01);
        try envelope.writer.writeByte(key_id_num);
        try envelope.writer.writeInt(u16, @intCast(rsa_ciphertext.len), .little);
        try envelope.writer.writeAll(rsa_ciphertext);
        try envelope.writer.writeAll(&gcm.tag);
        try envelope.writer.writeAll(&iv);
        try envelope.writer.writeAll(gcm.ciphertext);

        const envelope_bytes = envelope.writer.buffered();
        const b64_buf = try a.alloc(u8, std.base64.standard.Encoder.calcSize(envelope_bytes.len));
        defer a.free(b64_buf);
        const b64 = std.base64.standard.Encoder.encode(b64_buf, envelope_bytes);

        return std.fmt.allocPrint(a, "#PWD_INSTAGRAM:4:{d}:{s}", .{ ts, b64 });
    }

    /// Parses `accounts/login/`'s (or a challenge/2FA follow-up's) response
    /// body into `LoginResponseShape`, tolerant of whichever subset of
    /// fields is actually present.
    fn parseLoginResponse(allocator: std.mem.Allocator, body: []const u8) !LoginResponseShape {
        var parsed = json.parseFromSlice(json.Value, allocator, body, .{ .ignore_unknown_fields = true }) catch return .{};
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .{},
        };

        var out = LoginResponseShape{};
        if (obj.get("logged_in_user")) |lu| if (lu == .object) {
            out.logged_in = true;
            if (lu.object.get("pk")) |pk| out.user_id = try jsonToOwnedString(allocator, pk);
            if (lu.object.get("username")) |un| if (un == .string) {
                out.username = try allocator.dupe(u8, un.string);
            };
        };
        if (obj.get("challenge")) |ch| if (ch == .object) {
            if (ch.object.get("api_path")) |p| if (p == .string) {
                out.challenge_api_path = try allocator.dupe(u8, p.string);
            };
        };
        if (obj.get("two_factor_info")) |tf| if (tf == .object) {
            if (tf.object.get("two_factor_identifier")) |id| if (id == .string) {
                out.two_factor_identifier = try allocator.dupe(u8, id.string);
            };
        };
        if (obj.get("message")) |m| if (m == .string) {
            out.error_message = try allocator.dupe(u8, m.string);
        };
        return out;
    }

    fn jsonToOwnedString(allocator: std.mem.Allocator, v: json.Value) !?[]const u8 {
        return switch (v) {
            .string => |s| try allocator.dupe(u8, s),
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            else => null,
        };
    }

    /// Starts (or restarts, after a `rejected` outcome) a login attempt.
    /// `password` is used only to build `enc_password` for this one request
    /// and is never retained beyond a pending challenge/2FA step (see
    /// `pending_password`'s doc comment) -- the caller (the `/iglogin`
    /// command handler) must not log it either.
    pub fn login(self: *AuthClient, username: []const u8, password: []const u8) !AuthStepOutcome {
        const a = self.allocator;
        const pubkey = self.fetchPasswordPublicKey() catch |err| {
            if (err == error.PasswordEncryptionKeyNotConfigured) {
                return .{ .rejected = try a.dupe(u8, "the deployment's WARDEN_INSTAGRAM_PASSWORD_KEY_ID/_PASSWORD_PUBKEY_DER_B64 aren't set — Instagram's login endpoint requires a current password-encryption public key that this build can't fetch automatically yet, see instagram/transport.zig's RotatingConstants doc comment") };
            }
            return .timed_out;
        };
        const enc_password = self.buildEncPassword(password, pubkey.key_id, pubkey.public_key_der_b64) catch {
            return .{ .rejected = try a.dupe(u8, "couldn't prepare an encrypted login request (see logs)") };
        };
        defer a.free(enc_password);

        var payload: std.Io.Writer.Allocating = .init(a);
        defer payload.deinit();
        json.Stringify.value(.{
            .username = username,
            .enc_password = enc_password,
            .device_id = self.profile.android_device_id,
            .phone_id = self.profile.phone_id,
            .guid = self.profile.uuid,
            .login_attempt_count = 0,
        }, .{}, &payload.writer) catch return .{ .rejected = try a.dupe(u8, "couldn't build the login request") };

        const resp = transport.signedPost(self.io, a, &self.client, transport.base_url ++ "/accounts/login/", self.profile, self.constants, &self.jar, payload.writer.buffered()) catch |err| {
            log.warn("login: request failed: {t}", .{err});
            return .timed_out;
        };
        defer a.free(resp.body);

        const parsed = parseLoginResponse(a, resp.body) catch return .{ .rejected = try a.dupe(u8, "couldn't parse Instagram's response") };

        if (parsed.logged_in) {
            self.self_user_id = parsed.user_id;
            self.self_username = parsed.username orelse try a.dupe(u8, username);
            self.state = .ready;
            self.clearPendingPassword();
            return .ok;
        }
        if (parsed.two_factor_identifier) |id| {
            self.two_factor_identifier = id;
            self.pending_password = try a.dupe(u8, password);
            self.state = .wait_2fa_code;
            return .ok;
        }
        if (parsed.challenge_api_path) |path| {
            self.challenge_api_path = path;
            self.pending_password = try a.dupe(u8, password);
            self.state = .wait_challenge_code;
            return .ok;
        }
        return .{ .rejected = parsed.error_message orelse try a.dupe(u8, "login rejected for an unspecified reason") };
    }

    /// Submits a challenge code (SMS/email) Instagram sent during `login`.
    pub fn submitChallengeCode(self: *AuthClient, code: []const u8) !AuthStepOutcome {
        const a = self.allocator;
        if (self.state != .wait_challenge_code) return .{ .rejected = try a.dupe(u8, "not currently waiting on a challenge code") };
        const path = self.challenge_api_path orelse return .{ .rejected = try a.dupe(u8, "no pending challenge to answer") };

        var payload: std.Io.Writer.Allocating = .init(a);
        defer payload.deinit();
        json.Stringify.value(.{
            .security_code = code,
        }, .{}, &payload.writer) catch return .{ .rejected = try a.dupe(u8, "couldn't build the challenge request") };

        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ transport.base_url, path });
        defer a.free(url);
        const resp = transport.signedPost(self.io, a, &self.client, url, self.profile, self.constants, &self.jar, payload.writer.buffered()) catch |err| {
            log.warn("submitChallengeCode: request failed: {t}", .{err});
            return .timed_out;
        };
        defer a.free(resp.body);

        const parsed = parseLoginResponse(a, resp.body) catch return .{ .rejected = try a.dupe(u8, "couldn't parse Instagram's response") };
        if (parsed.logged_in or resp.status.class() == .success) {
            self.self_user_id = parsed.user_id;
            self.self_username = parsed.username;
            self.state = .ready;
            self.clearPendingPassword();
            if (self.challenge_api_path) |old| {
                a.free(old);
                self.challenge_api_path = null;
            }
            return .ok;
        }
        return .{ .rejected = parsed.error_message orelse try a.dupe(u8, "challenge code rejected") };
    }

    /// Submits a 2FA (TOTP/SMS) code from `login`'s `two_factor_identifier`.
    pub fn submit2faCode(self: *AuthClient, code: []const u8) !AuthStepOutcome {
        const a = self.allocator;
        if (self.state != .wait_2fa_code) return .{ .rejected = try a.dupe(u8, "not currently waiting on a 2FA code") };
        const identifier = self.two_factor_identifier orelse return .{ .rejected = try a.dupe(u8, "no pending 2FA challenge to answer") };
        const username = self.self_username orelse "";

        var payload: std.Io.Writer.Allocating = .init(a);
        defer payload.deinit();
        json.Stringify.value(.{
            .username = username,
            .verification_code = code,
            .two_factor_identifier = identifier,
            .device_id = self.profile.android_device_id,
        }, .{}, &payload.writer) catch return .{ .rejected = try a.dupe(u8, "couldn't build the 2FA request") };

        const resp = transport.signedPost(self.io, a, &self.client, transport.base_url ++ "/accounts/two_factor_login/", self.profile, self.constants, &self.jar, payload.writer.buffered()) catch |err| {
            log.warn("submit2faCode: request failed: {t}", .{err});
            return .timed_out;
        };
        defer a.free(resp.body);

        const parsed = parseLoginResponse(a, resp.body) catch return .{ .rejected = try a.dupe(u8, "couldn't parse Instagram's response") };
        if (parsed.logged_in) {
            self.self_user_id = parsed.user_id;
            self.self_username = parsed.username;
            self.state = .ready;
            self.clearPendingPassword();
            if (self.two_factor_identifier) |old| {
                a.free(old);
                self.two_factor_identifier = null;
            }
            return .ok;
        }
        return .{ .rejected = parsed.error_message orelse try a.dupe(u8, "2FA code rejected") };
    }

    /// Resets local state -- the caller (`session.zig`) is responsible for
    /// also clearing the persisted store row (`store/instagram_sessions.zig`'s
    /// `clearSession`) so a restart doesn't resurrect the logged-out session.
    pub fn logOut(self: *AuthClient) void {
        self.jar.deinit();
        self.jar = transport.CookieJar.init(self.allocator);
        if (self.self_user_id) |s| {
            self.allocator.free(s);
            self.self_user_id = null;
        }
        if (self.self_username) |s| {
            self.allocator.free(s);
            self.self_username = null;
        }
        self.clearPendingPassword();
        self.state = .logged_out;
    }
};

const testing = std.testing;

test "AuthClient starts logged_out with no identity" {
    var client = AuthClient.init(testing.allocator, testing.io, .{
        .android_device_id = "android-1",
        .phone_id = "p",
        .uuid = "u",
        .advertising_id = "a",
    }, .{});
    defer client.deinit();

    try testing.expectEqual(AuthState.logged_out, client.state);
    try testing.expectEqual(@as(?[]const u8, null), client.self_user_id);
}

test "restoreSession populates identity and cookies without a network call" {
    var client = AuthClient.init(testing.allocator, testing.io, .{
        .android_device_id = "android-1",
        .phone_id = "p",
        .uuid = "u",
        .advertising_id = "a",
    }, .{});
    defer client.deinit();

    try client.restoreSession("999", "example_user", "sess123", "csrf123", "mid123");

    try testing.expectEqual(AuthState.ready, client.state);
    try testing.expectEqualStrings("999", client.self_user_id.?);
    try testing.expectEqualStrings("example_user", client.self_username.?);
    try testing.expectEqualStrings("sess123", client.jar.get("sessionid").?);
}

test "submitChallengeCode rejects when no challenge is pending" {
    var client = AuthClient.init(testing.allocator, testing.io, .{
        .android_device_id = "android-1",
        .phone_id = "p",
        .uuid = "u",
        .advertising_id = "a",
    }, .{});
    defer client.deinit();

    const outcome = try client.submitChallengeCode("123456");
    switch (outcome) {
        .rejected => |why| {
            defer testing.allocator.free(why);
            try testing.expect(why.len > 0);
        },
        else => return error.TestExpectedRejection,
    }
}

test "submit2faCode rejects when no 2FA challenge is pending" {
    var client = AuthClient.init(testing.allocator, testing.io, .{
        .android_device_id = "android-1",
        .phone_id = "p",
        .uuid = "u",
        .advertising_id = "a",
    }, .{});
    defer client.deinit();

    const outcome = try client.submit2faCode("123456");
    switch (outcome) {
        .rejected => |why| {
            defer testing.allocator.free(why);
            try testing.expect(why.len > 0);
        },
        else => return error.TestExpectedRejection,
    }
}

test "logOut resets state back to logged_out and clears identity" {
    var client = AuthClient.init(testing.allocator, testing.io, .{
        .android_device_id = "android-1",
        .phone_id = "p",
        .uuid = "u",
        .advertising_id = "a",
    }, .{});
    defer client.deinit();

    try client.restoreSession("999", "example_user", "sess123", "csrf123", "mid123");
    try testing.expectEqual(AuthState.ready, client.state);

    client.logOut();
    try testing.expectEqual(AuthState.logged_out, client.state);
    try testing.expectEqual(@as(?[]const u8, null), client.self_user_id);
    try testing.expectEqual(@as(?[]const u8, null), client.jar.get("sessionid"));
}

test "parseLoginResponse extracts logged_in_user pk/username" {
    const body =
        \\{"logged_in_user": {"pk": 12345, "username": "alice"}, "status": "ok"}
    ;
    const parsed = try AuthClient.parseLoginResponse(testing.allocator, body);
    defer {
        if (parsed.user_id) |s| testing.allocator.free(s);
        if (parsed.username) |s| testing.allocator.free(s);
    }
    try testing.expect(parsed.logged_in);
    try testing.expectEqualStrings("12345", parsed.user_id.?);
    try testing.expectEqualStrings("alice", parsed.username.?);
}

test "parseLoginResponse extracts a challenge_required response's api_path" {
    const body =
        \\{"challenge": {"api_path": "/challenge/123/abc/"}, "message": "challenge_required"}
    ;
    const parsed = try AuthClient.parseLoginResponse(testing.allocator, body);
    defer {
        if (parsed.challenge_api_path) |s| testing.allocator.free(s);
        if (parsed.error_message) |s| testing.allocator.free(s);
    }
    try testing.expect(!parsed.logged_in);
    try testing.expectEqualStrings("/challenge/123/abc/", parsed.challenge_api_path.?);
}

test "parseLoginResponse extracts a two_factor_required response's identifier" {
    const body =
        \\{"two_factor_info": {"two_factor_identifier": "abc123"}, "message": "two_factor_required"}
    ;
    const parsed = try AuthClient.parseLoginResponse(testing.allocator, body);
    defer {
        if (parsed.two_factor_identifier) |s| testing.allocator.free(s);
        if (parsed.error_message) |s| testing.allocator.free(s);
    }
    try testing.expect(!parsed.logged_in);
    try testing.expectEqualStrings("abc123", parsed.two_factor_identifier.?);
}
