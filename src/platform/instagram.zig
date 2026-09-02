//! `platform.Connector` adapter for the Instagram personal-account
//! connector -- wires `instagram/auth.zig` (login/challenge/2FA),
//! `instagram/session.zig` (Postgres-persisted session, so a restart
//! resumes without re-login), `instagram/direct.zig` (DM poll/send), and
//! `instagram/policy.zig` (pacing + pause-on-challenge) into the same
//! shape as `platform/xmpp.zig`/`platform/telegram_user.zig`. No group-admin
//! vtable slots -- Instagram DMs have no equivalent concept.
const std = @import("std");
const Io = std.Io;
const iface = @import("interface.zig");
const Identity = @import("../domain/identity.zig").Identity;
const InstagramProfile = @import("../domain/instagram_profile.zig").InstagramProfile;
const store_pool = @import("../store/pool.zig");
const store = @import("../store/instagram_sessions.zig");
const auth = @import("../instagram/auth.zig");
const session = @import("../instagram/session.zig");
const direct = @import("../instagram/direct.zig");
const media = @import("../instagram/media.zig");
const policy = @import("../instagram/policy.zig");
const transport = @import("../instagram/transport.zig");
const log = @import("../log.zig").scoped("instagram");

pub const InstagramConnector = struct {
    allocator: std.mem.Allocator,
    io: Io,
    pool: *store_pool.PgPool,
    poll_interval_ms: u32,
    auth_client: auth.AuthClient,
    breaker: policy.Breaker,
    /// Guards `auth_client` -- `poll()` runs on its own connector thread
    /// while `/iglogin`'s handler (a `MessageWorkerPool` command-handler
    /// thread) can concurrently call `login`/`submitChallengeCode`/
    /// `submit2faCode`/`logOut`, same two-different-threads shape
    /// `telegram_user.zig`'s `known_chats_mu` documents.
    auth_mu: Io.Mutex = .init,

    /// `pool` must outlive this connector. Loads (or generates, on first
    /// ever run) a `DeviceProfile` and restores a persisted session if one
    /// exists -- see `instagram/session.zig`'s doc comment for why device
    /// identity and session cookies are Postgres-resident rather than a
    /// flat session file.
    pub fn init(allocator: std.mem.Allocator, io: Io, pool: *store_pool.PgPool, poll_interval_ms: u32, rotating: transport.RotatingConstants) !InstagramConnector {
        const profile = (try session.loadDeviceProfile(pool, allocator)) orelse try transport.DeviceProfile.generate(io, allocator);

        var auth_client = auth.AuthClient.init(allocator, io, profile, rotating);
        const restored = session.restore(pool, allocator, &auth_client) catch |err| blk: {
            log.warn("init: failed to restore a persisted session: {t}", .{err});
            break :blk false;
        };
        if (restored) log.info("restored a persisted Instagram session for @{s}", .{auth_client.self_username orelse "?"});

        return .{
            .allocator = allocator,
            .io = io,
            .pool = pool,
            .poll_interval_ms = poll_interval_ms,
            .auth_client = auth_client,
            .breaker = policy.Breaker.init(allocator),
        };
    }

    pub fn deinit(self: *InstagramConnector) void {
        self.auth_client.profile.deinit(self.allocator);
        self.auth_client.deinit();
        self.breaker.deinit();
    }

    pub fn connector(self: *InstagramConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .downloadFile = downloadFileFn,
        .selfId = selfIdFn,
        .selfUsername = selfUsernameFn,
        // No sendPhoto/sendVideo/sendDocument yet (Instagram DM media send
        // needs its own upload flow, not built in this pass -- see the
        // connector plan's sequencing) and no group-admin slots (no
        // equivalent concept on a DM-only platform).
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        _ = ptr;
        return .instagram;
    }

    fn selfIdFn(ptr: *anyopaque) ?[]const u8 {
        const self: *InstagramConnector = @ptrCast(@alignCast(ptr));
        return self.auth_client.self_user_id;
    }

    fn selfUsernameFn(ptr: *anyopaque) ?[]const u8 {
        const self: *InstagramConnector = @ptrCast(@alignCast(ptr));
        return self.auth_client.self_username;
    }

    /// Current login state -- `/iglogin status` reads this.
    pub fn authState(self: *InstagramConnector) auth.AuthState {
        self.auth_mu.lockUncancelable(self.io);
        defer self.auth_mu.unlock(self.io);
        return self.auth_client.state;
    }

    pub fn breakerReason(self: *InstagramConnector) ?[]const u8 {
        return self.breaker.reason;
    }

    pub fn isPaused(self: *InstagramConnector) bool {
        return self.breaker.isPaused();
    }

    pub fn resumePolling(self: *InstagramConnector) void {
        self.breaker.resume_();
    }

    /// `/iglogin start <username> <password>` -- see `auth.AuthClient.login`'s
    /// doc comment on why the raw password never outlives this call.
    pub fn login(self: *InstagramConnector, username: []const u8, password: []const u8) !auth.AuthStepOutcome {
        self.auth_mu.lockUncancelable(self.io);
        defer self.auth_mu.unlock(self.io);
        const outcome = try self.auth_client.login(username, password);
        if (outcome == .ok and self.auth_client.state == .ready) {
            session.save(self.pool, &self.auth_client, self.auth_client.profile) catch |err| {
                log.err("login: succeeded but failed to persist the session: {t}", .{err});
            };
        }
        return outcome;
    }

    pub fn submitChallengeCode(self: *InstagramConnector, code: []const u8) !auth.AuthStepOutcome {
        self.auth_mu.lockUncancelable(self.io);
        defer self.auth_mu.unlock(self.io);
        const outcome = try self.auth_client.submitChallengeCode(code);
        if (outcome == .ok and self.auth_client.state == .ready) {
            session.save(self.pool, &self.auth_client, self.auth_client.profile) catch |err| {
                log.err("submitChallengeCode: succeeded but failed to persist the session: {t}", .{err});
            };
        }
        return outcome;
    }

    pub fn submit2faCode(self: *InstagramConnector, code: []const u8) !auth.AuthStepOutcome {
        self.auth_mu.lockUncancelable(self.io);
        defer self.auth_mu.unlock(self.io);
        const outcome = try self.auth_client.submit2faCode(code);
        if (outcome == .ok and self.auth_client.state == .ready) {
            session.save(self.pool, &self.auth_client, self.auth_client.profile) catch |err| {
                log.err("submit2faCode: succeeded but failed to persist the session: {t}", .{err});
            };
        }
        return outcome;
    }

    pub fn logOut(self: *InstagramConnector) void {
        self.auth_mu.lockUncancelable(self.io);
        defer self.auth_mu.unlock(self.io);
        session.logOut(self.pool, &self.auth_client);
        self.breaker.resume_();
    }

    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        const self: *InstagramConnector = @ptrCast(@alignCast(ptr));

        // Always pace, even when there's nothing to do yet -- avoids a
        // tight busy-loop while not-yet-logged-in or paused, matching every
        // other connector's "poll blocks for roughly one cycle" contract.
        defer Io.sleep(self.io, .fromMilliseconds(policy.nextPollDelayMs(self.io, self.poll_interval_ms)), .awake) catch {};

        if (self.breaker.isPaused()) return &.{};

        self.auth_mu.lockUncancelable(self.io);
        const ready = self.auth_client.state == .ready;
        self.auth_mu.unlock(self.io);
        if (!ready) return &.{};

        const WatermarkCtx = struct {
            var pool_ptr: *store_pool.PgPool = undefined;
        };
        WatermarkCtx.pool_ptr = self.pool;
        const lookup = struct {
            fn get(thread_id: []const u8) i64 {
                return store.getThreadWatermark(WatermarkCtx.pool_ptr, thread_id);
            }
        }.get;

        self.auth_mu.lockUncancelable(self.io);
        const direct_messages = direct.pollInbox(self.io, allocator, &self.auth_client.client, &self.auth_client, &lookup) catch |err| {
            self.auth_mu.unlock(self.io);
            if (err == error.ChallengeOrBlock) {
                self.breaker.trip("Instagram returned a challenge/checkpoint response while polling — paused. Check /iglogin status, and re-authenticate via /iglogin once you've resolved it in the app.");
                log.err("poll: challenge/block detected, pausing until /iglogin resumes it", .{});
            } else {
                log.warn("poll: inbox fetch failed: {t}", .{err});
            }
            return &.{};
        };
        self.auth_mu.unlock(self.io);
        defer allocator.free(direct_messages);

        var out = try std.ArrayList(iface.Message).initCapacity(allocator, direct_messages.len);
        errdefer out.deinit(allocator);

        // Highest timestamp seen per thread this cycle, to advance the
        // watermark once past the point of no return (every message in
        // this batch has already been handed to `main.zig`).
        var max_ts: std.StringHashMapUnmanaged(i64) = .empty;
        defer max_ts.deinit(allocator);

        for (direct_messages) |dm| {
            const entry = try max_ts.getOrPutValue(allocator, dm.thread_id, dm.timestamp_us);
            if (dm.timestamp_us > entry.value_ptr.*) entry.value_ptr.* = dm.timestamp_us;

            out.appendAssumeCapacity(.{
                .chat_id = try allocator.dupe(u8, dm.thread_id),
                .user_id = try allocator.dupe(u8, dm.user_id),
                .text = try allocator.dupe(u8, dm.text),
                .is_group = false,
                .mentions_me = dm.is_self_thread,
                .identity = .{
                    .platform = .instagram,
                    .native_id = try allocator.dupe(u8, dm.user_id),
                    .display_name = try allocator.dupe(u8, dm.user_id),
                    .first_seen = 0,
                    .last_seen = 0,
                },
            });
        }

        var it = max_ts.iterator();
        while (it.next()) |entry| {
            store.setThreadWatermark(self.pool, entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                log.warn("poll: failed to advance watermark for thread {s}: {t}", .{ entry.key_ptr.*, err });
            };
        }

        return out.toOwnedSlice(allocator);
    }

    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = reply_to_message_id; // Instagram DM threading has no reply-to-message concept this API surfaces simply.
        const self: *InstagramConnector = @ptrCast(@alignCast(ptr));

        self.auth_mu.lockUncancelable(self.io);
        defer self.auth_mu.unlock(self.io);
        if (self.auth_client.state != .ready) {
            log.warn("sendMessageFn: not logged in, dropping message to thread {s}", .{chat_id});
            return;
        }
        direct.sendText(self.io, allocator, &self.auth_client.client, &self.auth_client, chat_id, text) catch |err| {
            log.err("sendMessageFn: failed to send to thread {s}: {t}", .{ chat_id, err });
        };
    }

    /// Resolves a `file_id` shaped like a shortcode/media URL (or a bare
    /// numeric `media_pk`) to bytes via the authenticated media-info
    /// resolver. This is the same path `video_download.zig`'s fallback
    /// integration (not built in this pass) will call into for private/
    /// gated content `yt-dlp` alone can't reach.
    fn downloadFileFn(ptr: *anyopaque, allocator: std.mem.Allocator, file_id: []const u8) anyerror![]u8 {
        const self: *InstagramConnector = @ptrCast(@alignCast(ptr));

        const media_pk = media.mediaPkFromUrl(file_id) orelse
            (media.mediaPkFromShortcode(file_id) catch (std.fmt.parseInt(u64, file_id, 10) catch return error.Unsupported));

        self.auth_mu.lockUncancelable(self.io);
        const info_opt = media.fetchMediaInfoAuthenticated(self.io, allocator, &self.auth_client.client, &self.auth_client, media_pk) catch null;
        self.auth_mu.unlock(self.io);
        const info = info_opt orelse return error.Unsupported;
        defer {
            if (info.video_url) |s| allocator.free(s);
            if (info.image_url) |s| allocator.free(s);
        }
        const cdn_url = info.video_url orelse info.image_url orelse return error.Unsupported;

        var client: std.http.Client = .{ .allocator = allocator, .io = self.io };
        defer client.deinit();
        const http_util = @import("../http_util.zig");
        return http_util.get(&client, allocator, cdn_url);
    }
};

const testing = std.testing;

test "platformFn reports .instagram" {
    var pool_stub: store_pool.PgPool = undefined;
    _ = &pool_stub;
    // `init` needs a real pool (device-profile/session lookups); this test
    // only exercises the vtable's static platform() mapping, which doesn't
    // touch `self` at all, so a connector built directly (bypassing
    // `init`'s store round trips) is enough.
    var conn = InstagramConnector{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = undefined,
        .poll_interval_ms = 1000,
        .auth_client = auth.AuthClient.init(testing.allocator, testing.io, .{
            .android_device_id = "android-1",
            .phone_id = "p",
            .uuid = "u",
            .advertising_id = "a",
        }, .{}),
        .breaker = policy.Breaker.init(testing.allocator),
    };
    defer {
        conn.auth_client.deinit();
        conn.breaker.deinit();
    }
    const c = conn.connector();
    try testing.expectEqual(iface.Platform.instagram, c.platform());
}

test "selfId/selfUsername are null before any login" {
    var conn = InstagramConnector{
        .allocator = testing.allocator,
        .io = testing.io,
        .pool = undefined,
        .poll_interval_ms = 1000,
        .auth_client = auth.AuthClient.init(testing.allocator, testing.io, .{
            .android_device_id = "android-1",
            .phone_id = "p",
            .uuid = "u",
            .advertising_id = "a",
        }, .{}),
        .breaker = policy.Breaker.init(testing.allocator),
    };
    defer {
        conn.auth_client.deinit();
        conn.breaker.deinit();
    }
    const c = conn.connector();
    try testing.expectEqual(@as(?[]const u8, null), c.selfId());
    try testing.expectEqual(@as(?[]const u8, null), c.selfUsername());
}
