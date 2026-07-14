const Identity = @import("identity.zig").Identity;

/// Matrix-specific extension of `Identity`. Stubbed ahead of an actual Matrix
/// connector (see `src/platform/matrix.zig`) — no code populates this yet.
pub const MatrixProfile = struct {
    identity: Identity,
    homeserver: []const u8 = "",
    avatar_url: ?[]const u8 = null,
};
