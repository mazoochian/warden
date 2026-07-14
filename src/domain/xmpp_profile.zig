const Identity = @import("identity.zig").Identity;

/// XMPP-specific extension of `Identity`. Stubbed ahead of an actual XMPP
/// connector (see `src/platform/xmpp.zig`) — no code populates this yet.
pub const XmppProfile = struct {
    identity: Identity,
    jid_resource: ?[]const u8 = null,
};
