//! Thin glue between `auth.zig`'s in-memory `AuthClient` and
//! `store/instagram_sessions.zig`'s Postgres-persisted session row --
//! load-on-startup and save-after-login, so a process restart resumes
//! without re-authenticating (see the connector plan's ban-avoidance
//! rationale for why that matters here more than for any other connector).
const std = @import("std");
const PgPool = @import("../store/pool.zig").PgPool;
const store = @import("../store/instagram_sessions.zig");
const auth = @import("auth.zig");
const transport = @import("transport.zig");

/// Restores `client` from the persisted session row, if one exists.
/// Returns `true` if a session was restored (caller should NOT then also
/// call `login` -- treat `.ready` as already-authenticated), `false` if
/// there's nothing to restore (first-ever run, or after a logout).
pub fn restore(pool: *PgPool, allocator: std.mem.Allocator, client: *auth.AuthClient) !bool {
    const loaded = store.loadSession(pool, allocator) orelse return false;
    defer {
        allocator.free(loaded.ig_username);
        allocator.free(loaded.ig_user_id);
        allocator.free(loaded.android_device_id);
        allocator.free(loaded.phone_id);
        allocator.free(loaded.device_uuid);
        allocator.free(loaded.advertising_id);
        allocator.free(loaded.session_id_cookie);
        allocator.free(loaded.csrf_token);
        allocator.free(loaded.mid_cookie);
    }
    try client.restoreSession(loaded.ig_user_id, loaded.ig_username, loaded.session_id_cookie, loaded.csrf_token, loaded.mid_cookie);
    return true;
}

/// Loads just the device profile half of a persisted session (if any) --
/// used at connector startup to decide whether to generate a fresh
/// `DeviceProfile` (first-ever run) or reuse the one already on file
/// (every subsequent run), since a real Android app never changes its
/// device fingerprint between sessions.
pub fn loadDeviceProfile(pool: *PgPool, allocator: std.mem.Allocator) !?transport.DeviceProfile {
    const loaded = store.loadSession(pool, allocator) orelse return null;
    allocator.free(loaded.ig_username);
    allocator.free(loaded.ig_user_id);
    allocator.free(loaded.session_id_cookie);
    allocator.free(loaded.csrf_token);
    allocator.free(loaded.mid_cookie);
    return .{
        .android_device_id = loaded.android_device_id,
        .phone_id = loaded.phone_id,
        .uuid = loaded.device_uuid,
        .advertising_id = loaded.advertising_id,
    };
}

/// Persists `client`'s current session state -- called right after a
/// successful `login`/`submitChallengeCode`/`submit2faCode` reaches `.ready`.
/// No-op (returns an error the caller should just log) if `client` isn't
/// actually `.ready` -- there's nothing meaningful to save otherwise.
pub fn save(pool: *PgPool, client: *const auth.AuthClient, profile: transport.DeviceProfile) !void {
    if (client.state != .ready) return error.NotLoggedIn;
    const user_id = client.self_user_id orelse return error.NotLoggedIn;
    const username = client.self_username orelse return error.NotLoggedIn;

    try store.saveSession(pool, .{
        .ig_username = username,
        .ig_user_id = user_id,
        .android_device_id = profile.android_device_id,
        .phone_id = profile.phone_id,
        .device_uuid = profile.uuid,
        .advertising_id = profile.advertising_id,
        .session_id_cookie = client.jar.get("sessionid") orelse "",
        .csrf_token = client.jar.get("csrftoken") orelse "",
        .mid_cookie = client.jar.get("mid") orelse "",
    });
}

/// `/iglogin logout` -- logs `client` out locally and clears the persisted
/// row so a restart doesn't resurrect it.
pub fn logOut(pool: *PgPool, client: *auth.AuthClient) void {
    client.logOut();
    store.clearSession(pool) catch {};
}
