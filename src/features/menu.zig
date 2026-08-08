const std = @import("std");
const Io = std.Io;
const iface = @import("../platform/interface.zig");
const store_pool = @import("../store/pool.zig");
const config_mod = @import("../config.zig");
const scheduler = @import("scheduler.zig");
const convert_flow = @import("convert_flow.zig");
const audit_notify = @import("audit_notify.zig");
const tree = @import("menu_tree.zig");
const civil_time = @import("../text/civil_time.zig");
const reminder_format = @import("reminder_format.zig");
const log = @import("../log.zig").scoped("menu");

pub const NodeId = tree.NodeId;

/// `.help` mode renders the exact same tree read-only (picking anything
/// just shows its description, never performs an action or prompts for
/// input) — see `menu_tree.zig`'s doc comment for why this is one tree,
/// not two. Reverts to `.normal` the moment navigation returns to `.root`
/// (there's no meaningful "help view of the root menu" distinct from the
/// real one).
pub const Mode = enum { normal, help };

const Stage = union(enum) {
    browsing,
    /// The live message is showing `NodeId`'s `.prompt` text, waiting for
    /// the next plain-text/reply message from this same (chat, user).
    awaiting_input: NodeId,
    /// Mid-`.wizard`-kind-node flow — see `ReminderDraft`'s doc comment.
    wizard: ReminderDraft,
};

/// One step in the reminder-creation wizard (the only `.wizard`-kind node
/// today — see `menu_tree.zig`'s `.reminders_new`). Built specifically for
/// this flow rather than a generalized "any wizard" framework: YAGNI until
/// a second wizard actually needs one.
pub const WizardStep = enum { date, hour, minute, second, message, confirm };

/// `year`/`month`/`day`/`hour`/`minute`/`second` are the in-progress local
/// civil time being assembled (see `civil_time.Civil`); `message` is only
/// set once `step` reaches `.message`. Owned by `Sessions.allocator` (not
/// the caller's per-message arena) since it outlives any single message —
/// see `Sessions.freeStage`.
pub const ReminderDraft = struct {
    step: WizardStep = .date,
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8 = 0,
    message: []const u8 = "",
};

const Session = struct {
    node: NodeId,
    mode: Mode,
    /// Breadcrumb trail for "Back" — does not include `node` itself.
    stack: std.ArrayList(NodeId),
    /// The one living message this session edits in place on platforms
    /// that support it (Telegram); a fresh message each navigation step
    /// otherwise (Matrix) — see `showNode`.
    prompt_message_id: []const u8,
    stage: Stage,
    expires_at: i64,
    /// Which connector opened this session — set once at creation from
    /// the `connector` `open` was called with. `sweepExpired` uses this to
    /// find the right connector (out of possibly several, one per
    /// platform) to edit the stale message on before evicting.
    platform: iface.Platform,
};

/// What a runner call tells the engine to do next.
pub const Outcome = union(enum) {
    /// Navigate to (and render) this node — typically the acting node's
    /// parent, so a moderator can chain several actions from one open menu.
    show: NodeId,
    /// The flow is done (e.g. `/convert` handed off to its own separate UI);
    /// dismiss the menu.
    close,
    /// Stay on the current `awaiting_input` node — the runner has already
    /// sent whatever feedback was needed (e.g. a usage error), and the user
    /// can just try again.
    retry,
};

/// Everything a runner call needs beyond its own `NodeId` — deliberately a
/// plain passthrough bundle (`menu.zig` never reaches into `pool`/`config`
/// itself, just carries them from the caller in `main.zig` to the runner
/// functions also defined in `main.zig`).
pub const ActionContext = struct {
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    config: *const config_mod.Config,
    chat_id: i64,
    identity_id: i64,
    now: i64,
    /// The message that triggered this call — a button press's synthetic
    /// wrapper message for `.perform`/`.performDynamicPick`, or the actual
    /// follow-up message for `.resumeAwaitingInput`.
    msg: iface.Message,
    /// The rest of this bundle is only needed by a handful of specific
    /// actions (word cloud/pie chart rendering, the digest on/off toggle,
    /// launching `/convert`'s own flow) — carried through unconditionally
    /// anyway, same passthrough reasoning as `pool`/`config` above.
    io: Io,
    digest_scheduler: *scheduler.DigestScheduler,
    pending_conversions: *convert_flow.PendingConversions,
    pending_undos: *audit_notify.PendingUndos,
};

/// Every implementation lives in `main.zig` (the only place with every
/// handler function/store module already in scope) as plain functions, not
/// a ptr+vtable pair like `iface.Connector` — there's exactly one
/// implementation, so the extra indirection buys nothing.
pub const ActionRunner = struct {
    /// Runs a `.action` node's effect.
    perform: *const fn (id: NodeId, ctx: ActionContext) Outcome,
    /// Produces a `.dynamic_list` node's live choices (e.g. this chat's
    /// actual pending alerts). Owned by `ctx.a` (an arena in practice).
    dynamicChoices: *const fn (id: NodeId, ctx: ActionContext) []const iface.Choice,
    /// One of a `.dynamic_list`'s live choices was picked; `value` is
    /// whichever `iface.Choice.value` `dynamicChoices` produced for it.
    performDynamicPick: *const fn (id: NodeId, value: []const u8, ctx: ActionContext) Outcome,
    /// An `.awaiting_input` node's follow-up message arrived.
    resumeAwaitingInput: *const fn (id: NodeId, ctx: ActionContext) Outcome,
    /// A `.wizard` node was entered — produces its initial draft (today,
    /// a sensible default time).
    beginWizard: *const fn (id: NodeId, ctx: ActionContext) ReminderDraft,
    /// The wizard's confirm screen was accepted — creates the real
    /// reminder from the assembled draft.
    finishWizard: *const fn (draft: ReminderDraft, ctx: ActionContext) Outcome,
};

const back_value = "\x00back";
const back_emoji = "⬅️";
const close_value = "\x00close";
const close_emoji = "✖️";

// Wizard-only synthetic choice values -- never a `NodeId` tag name, so
// these can't collide with `resolvePick`'s tree-node matches.
const wiz_dec_value = "\x00wiz_dec";
const wiz_inc_value = "\x00wiz_inc";
const wiz_noop_value = "\x00wiz_noop";
const wiz_prev_value = "\x00wiz_prev";
const wiz_next_value = "\x00wiz_next";
const wiz_confirm_value = "\x00wiz_confirm";
const wiz_discard_value = "\x00wiz_discard";

/// One rendered screen: message text plus the buttons/reactions to show
/// under it (already including Back/Close).
const Rendered = struct {
    text: []const u8,
    choices: []const iface.Choice,
};

/// Builds the choice list for `id` under `mode`/`stack_len` — real content
/// from `menu_tree`'s static `children` (or, in `.normal` mode only, a
/// `.dynamic_list` node's live `runner.dynamicChoices`), plus a trailing
/// Back (only when there's somewhere to go back to) and Close. This same
/// list is rebuilt both to render a screen and to resolve a Matrix pick
/// (matched by emoji) — see `resolvePick`.
fn choicesFor(n: *const tree.MenuNode, mode: Mode, runner: ActionRunner, ctx: ActionContext, stack_len: usize) []const iface.Choice {
    var out: std.ArrayList(iface.Choice) = .empty;
    if (mode == .normal and n.kind == .dynamic_list) {
        for (runner.dynamicChoices(n.id, ctx)) |c| out.append(ctx.a, c) catch {};
    } else {
        for (n.children) |c| out.append(ctx.a, .{ .emoji = c.emoji, .label = c.label, .value = @tagName(c.id) }) catch {};
    }
    if (stack_len > 0) out.append(ctx.a, .{ .emoji = back_emoji, .label = "Back", .value = back_value }) catch {};
    out.append(ctx.a, .{ .emoji = close_emoji, .label = "Close", .value = close_value }) catch {};
    return out.items;
}

fn renderNode(id: NodeId, mode: Mode, runner: ActionRunner, ctx: ActionContext, stack_len: usize) Rendered {
    const n = tree.node(id);
    const text = switch (mode) {
        .normal => switch (n.kind) {
            .awaiting_input => std.fmt.allocPrint(ctx.a, "{s}\n\n{s}", .{ n.title, n.prompt }) catch n.title,
            else => if (n.body.len > 0) std.fmt.allocPrint(ctx.a, "{s}\n\n{s}", .{ n.title, n.body }) catch n.title else n.title,
        },
        .help => blk: {
            var buf: std.Io.Writer.Allocating = .init(ctx.a);
            buf.writer.print("{s}", .{n.title}) catch {};
            if (n.help_body.len > 0) buf.writer.print("\n\n{s}", .{n.help_body}) catch {};
            if (n.help_example.len > 0) buf.writer.print("\n\nExample: {s}", .{n.help_example}) catch {};
            break :blk buf.writer.buffered();
        },
    };
    return .{ .text = text, .choices = choicesFor(n, mode, runner, ctx, stack_len) };
}

/// Resolves `picked_value` against `choices` the same way
/// `convert_flow.resolveTargetFormat` does: Telegram's value already IS the
/// canonical `Choice.value`; Matrix's is the raw reaction emoji, resolved
/// by scanning for a matching `.emoji`. Returns the canonical `.value`
/// either way (a `NodeId` tag name, a dynamic-list id/url, or a
/// back/close sentinel).
fn resolvePick(platform: iface.Platform, choices: []const iface.Choice, picked_value: []const u8) ?[]const u8 {
    return switch (platform) {
        .telegram => blk: {
            for (choices) |c| if (std.mem.eql(u8, c.value, picked_value)) break :blk c.value;
            break :blk null;
        },
        .matrix => blk: {
            for (choices) |c| if (std.mem.eql(u8, c.emoji, picked_value)) break :blk c.value;
            break :blk null;
        },
        else => null,
    };
}

fn nextStep(step: WizardStep) WizardStep {
    return switch (step) {
        .date => .hour,
        .hour => .minute,
        .minute => .second,
        .second => .message,
        .message => .confirm,
        .confirm => .confirm,
    };
}

fn prevStep(step: WizardStep) WizardStep {
    return switch (step) {
        .date => .date,
        .hour => .date,
        .minute => .hour,
        .second => .minute,
        .message => .second,
        .confirm => .confirm,
    };
}

/// How much a single ±press moves `draft`'s current-step field — 1 day, 1
/// hour, 5 minutes, 1 second, matching the spec's stepper granularity.
fn adjustDraft(draft: *ReminderDraft, sign: i32) void {
    switch (draft.step) {
        .date => {
            const c: civil_time.Civil = .{ .year = draft.year, .month = draft.month, .day = draft.day, .hour = draft.hour, .minute = draft.minute, .second = draft.second };
            const shifted = civil_time.addDays(c, sign);
            draft.year = shifted.year;
            draft.month = shifted.month;
            draft.day = shifted.day;
        },
        .hour => draft.hour = @intCast(@mod(@as(i32, draft.hour) + sign, 24)),
        .minute => draft.minute = @intCast(@mod(@as(i32, draft.minute) + sign * 5, 60)),
        .second => draft.second = @intCast(@mod(@as(i32, draft.second) + sign, 60)),
        .message, .confirm => {},
    }
}

/// The current step's value rendered as the stepper's middle button label.
fn stepValueLabel(a: std.mem.Allocator, draft: ReminderDraft) []const u8 {
    return switch (draft.step) {
        .date => std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2}", .{ draft.year, draft.month, draft.day }) catch "?",
        .hour => std.fmt.allocPrint(a, "{d:0>2}h", .{draft.hour}) catch "?",
        .minute => std.fmt.allocPrint(a, "{d:0>2}m", .{draft.minute}) catch "?",
        .second => std.fmt.allocPrint(a, "{d:0>2}s", .{draft.second}) catch "?",
        .message, .confirm => "",
    };
}

/// Renders one wizard screen — bypasses `renderNode`/`choicesFor` entirely
/// (those build a node's *static* children or a `.dynamic_list`'s live
/// items; a wizard's buttons are its own stepper/nav, not tree content).
/// No generic Back among these: the wizard's own Previous/Next covers
/// linear step navigation, and Back's stack-pop semantics don't fit a
/// linear flow — Discard (from `.confirm`) is the one way out early.
fn renderWizardStep(draft: ReminderDraft, ctx: ActionContext) Rendered {
    var choices: std.ArrayList(iface.Choice) = .empty;
    var text: []const u8 = "";

    switch (draft.step) {
        .date, .hour, .minute, .second => {
            const label = stepValueLabel(ctx.a, draft);
            const step_num: u8 = switch (draft.step) {
                .date => 1,
                .hour => 2,
                .minute => 3,
                .second => 4,
                else => 0,
            };
            const step_name: []const u8 = switch (draft.step) {
                .date => "Date",
                .hour => "Hour",
                .minute => "Minute",
                .second => "Second",
                else => "",
            };
            text = std.fmt.allocPrint(ctx.a, "⏰ New reminder — step {d}/6: {s}\n\n{s}\n\nOr just reply with a time (13:37) or date (5/22/26) to jump straight there.", .{ step_num, step_name, label }) catch label;
            choices.append(ctx.a, .{ .emoji = "◀️", .label = "-", .value = wiz_dec_value }) catch {};
            choices.append(ctx.a, .{ .emoji = "🔘", .label = label, .value = wiz_noop_value }) catch {};
            choices.append(ctx.a, .{ .emoji = "▶️", .label = "+", .value = wiz_inc_value }) catch {};
            if (draft.step != .date) choices.append(ctx.a, .{ .emoji = "⬅️", .label = "Previous", .value = wiz_prev_value }) catch {};
            choices.append(ctx.a, .{ .emoji = "➡️", .label = "Next", .value = wiz_next_value }) catch {};
        },
        .message => {
            text = "⏰ New reminder — step 5/6: Message\n\nSend the reminder message.";
            choices.append(ctx.a, .{ .emoji = "⬅️", .label = "Previous", .value = wiz_prev_value }) catch {};
        },
        .confirm => {
            const c: civil_time.Civil = .{ .year = draft.year, .month = draft.month, .day = draft.day, .hour = draft.hour, .minute = draft.minute, .second = draft.second };
            const date_str = civil_time.formatDate(ctx.a, c, .ymd);
            const time_str = civil_time.formatTime(ctx.a, c, .h24);
            text = std.fmt.allocPrint(ctx.a, "⏰ New reminder — step 6/6: Confirm\n\n{s} {s}\n{s}", .{ date_str, time_str, draft.message }) catch draft.message;
            choices.append(ctx.a, .{ .emoji = "✅", .label = "Create", .value = wiz_confirm_value }) catch {};
            choices.append(ctx.a, .{ .emoji = "✖️", .label = "Discard", .value = wiz_discard_value }) catch {};
        },
    }
    choices.append(ctx.a, .{ .emoji = close_emoji, .label = "Close", .value = close_value }) catch {};
    return .{ .text = text, .choices = choices.items };
}

/// Tries the date shape first (both orderings, since the shortcut has no
/// per-user format preference to consult — the stepper buttons remain the
/// always-correct path; this is convenience-only), then a bare clock time.
fn parseShortcutDate(text: []const u8) ?reminder_format.DateParts {
    if (reminder_format.parseDatePart(text, .mdy)) |d| return d;
    return reminder_format.parseDatePart(text, .dmy);
}

/// Finds the connector whose platform matches `platform` — duplicated from
/// `main.zig`'s own `findConnector` rather than exported, same reasoning
/// as `features/alerts.zig`'s copy of the same helper: keeps this feature
/// file's only dependency on `main.zig` at zero.
fn findConnectorByPlatform(connectors: []const iface.Connector, platform: iface.Platform) ?iface.Connector {
    for (connectors) |c| {
        if (c.platform() == platform) return c;
    }
    return null;
}

pub const Sessions = struct {
    allocator: std.mem.Allocator,
    io: Io,
    map: std.StringHashMap(Session),
    mutex: Io.Mutex = .init,
    timeout_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: Io, timeout_seconds: i64) Sessions {
        return .{
            .allocator = allocator,
            .io = io,
            .map = std.StringHashMap(Session).init(allocator),
            .timeout_seconds = timeout_seconds,
        };
    }

    pub fn deinit(self: *Sessions) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.freeEntry(entry.key_ptr.*, entry.value_ptr.*);
        self.map.deinit();
    }

    fn compositeKey(allocator: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ chat_id, user_id });
    }

    /// Splits a stored key back into its `chat_id` half — used only by
    /// `handleChoicePicked`'s "does this prompt belong to someone else in
    /// this same chat" scan.
    fn chatIdOfKey(key: []const u8) []const u8 {
        const at = std.mem.indexOfScalar(u8, key, 0) orelse return key;
        return key[0..at];
    }

    fn freeEntry(self: *Sessions, key: []const u8, entry: Session) void {
        self.allocator.free(key);
        self.freeStage(entry.stage);
        var stack = entry.stack;
        stack.deinit(self.allocator);
        self.allocator.free(entry.prompt_message_id);
    }

    /// A `.wizard` stage owns its `draft.message` (once set) on
    /// `self.allocator` — every place that overwrites or drops a session's
    /// `stage` must free the outgoing value first, or a wizard's message
    /// leaks once per finished/discarded/abandoned flow.
    fn freeStage(self: *Sessions, stage: Stage) void {
        switch (stage) {
            .wizard => |d| if (d.message.len > 0) self.allocator.free(d.message),
            .browsing, .awaiting_input => {},
        }
    }

    fn putSession(self: *Sessions, now: i64, chat_id: []const u8, user_id: []const u8, prompt_message_id: []const u8, node_id: NodeId, mode: Mode, platform: iface.Platform) !void {
        const owned_prompt_id = try self.allocator.dupe(u8, prompt_message_id);
        errdefer self.allocator.free(owned_prompt_id);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const key = try compositeKey(self.allocator, chat_id, user_id);
        errdefer self.allocator.free(key);
        if (self.map.fetchRemove(key)) |old| self.freeEntry(old.key, old.value);
        try self.map.put(key, .{
            .node = node_id,
            .mode = mode,
            .stack = .empty,
            .prompt_message_id = owned_prompt_id,
            .stage = .browsing,
            .expires_at = now + self.timeout_seconds,
            .platform = platform,
        });
    }

    /// Opens a brand new `/menu` (always at `.root`, `.normal` mode) —
    /// replaces any session already open for this (chat, user), same as
    /// `convert_flow.beginAwaitingFile` replacing a stale entry.
    /// `a` is a throwaway allocator for this one call's rendering/sending
    /// (an arena in production, freed with the rest of the per-message
    /// task) — distinct from `self.allocator`, the session store's own
    /// long-lived allocator used only for what `putSession` actually keeps.
    pub fn open(self: *Sessions, connector: iface.Connector, a: std.mem.Allocator, runner: ActionRunner, now: i64, msg: iface.Message) void {
        const ctx = ActionContext{ .connector = connector, .a = a, .pool = undefined, .config = undefined, .chat_id = 0, .identity_id = 0, .now = now, .msg = msg, .io = self.io, .digest_scheduler = undefined, .pending_conversions = undefined, .pending_undos = undefined };
        const rendered = renderNode(.root, .normal, runner, ctx, 0);
        const prompt_id = (connector.sendChoicePrompt(a, msg.chat_id, rendered.text, rendered.choices, msg.message_id) catch |err| {
            log.err("failed to open menu for chat {s}: {t}", .{ msg.chat_id, err });
            connector.sendMessage(a, msg.chat_id, "Couldn't open the menu, try again.", msg.message_id);
            return;
        }) orelse return; // no button support -- the wrapper already sent a plain-text fallback listing every module.

        self.putSession(now, msg.chat_id, msg.user_id, prompt_id, .root, .normal, connector.platform()) catch |err| {
            log.err("failed to store menu session for chat {s}: {t}", .{ msg.chat_id, err });
        };
    }

    /// Edits the session's living message to show `id` (Telegram), or —
    /// when the connector has no `editChoicePrompt` — sends a fresh message
    /// and updates `prompt_message_id` to it (Matrix, this pass; see
    /// `menu`'s module doc comment on why real in-place editing there is
    /// deferred).
    fn showNode(self: *Sessions, connector: iface.Connector, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, id: NodeId, mode: Mode, stack_len: usize) void {
        self.showRendered(connector, ctx, chat_id, user_id, renderNode(id, mode, runner, ctx, stack_len));
    }

    /// Renders one wizard screen for the session's living message — the
    /// `.wizard`-stage sibling of `showNode` (which renders a tree `NodeId`
    /// instead of a `ReminderDraft`).
    fn showWizardStep(self: *Sessions, connector: iface.Connector, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, draft: ReminderDraft) void {
        self.showRendered(connector, ctx, chat_id, user_id, renderWizardStep(draft, ctx));
    }

    fn showRendered(self: *Sessions, connector: iface.Connector, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, rendered: Rendered) void {
        var current_prompt_id: ?[]const u8 = null;
        self.mutex.lockUncancelable(self.io);
        if (self.lockedGet(chat_id, user_id)) |s| current_prompt_id = s.prompt_message_id;
        self.mutex.unlock(self.io);
        const prompt_id = current_prompt_id orelse return;

        connector.editChoicePrompt(ctx.a, chat_id, prompt_id, rendered.text, rendered.choices) catch |err| {
            if (err != error.Unsupported) {
                log.warn("failed to edit menu message for chat {s}: {t}", .{ chat_id, err });
                return;
            }
            const new_id = (connector.sendChoicePrompt(ctx.a, chat_id, rendered.text, rendered.choices, null) catch |send_err| {
                log.warn("failed to re-send menu message for chat {s}: {t}", .{ chat_id, send_err });
                return;
            }) orelse return;
            const key = compositeKey(self.allocator, chat_id, user_id) catch return;
            defer self.allocator.free(key);
            self.mutex.lockUncancelable(self.io);
            if (self.map.getPtr(key)) |s| {
                self.allocator.free(s.prompt_message_id);
                s.prompt_message_id = self.allocator.dupe(u8, new_id) catch new_id;
            }
            self.mutex.unlock(self.io);
            return;
        };
    }

    /// Caller must hold `self.mutex`. Read-only lookup with the lazy-expiry
    /// check every other read path here does.
    fn lockedGet(self: *Sessions, chat_id: []const u8, user_id: []const u8) ?Session {
        const key = compositeKey(self.allocator, chat_id, user_id) catch return null;
        defer self.allocator.free(key);
        const s = self.map.get(key) orelse return null;
        return s;
    }

    /// A `choice_picked` event arrived. `connector`'s allocator use is the
    /// caller's per-message arena (`ctx.a`); the session store's own
    /// allocator is separate and long-lived.
    pub fn handleChoicePicked(self: *Sessions, runner: ActionRunner, now: i64, ctx: ActionContext, picked: iface.ChoicePicked) void {
        const chat_id = ctx.msg.chat_id;
        const user_id = ctx.msg.user_id;

        self.mutex.lockUncancelable(self.io);
        const key = compositeKey(self.allocator, chat_id, user_id) catch {
            self.mutex.unlock(self.io);
            return;
        };
        defer self.allocator.free(key);
        const session = self.map.get(key);
        self.mutex.unlock(self.io);

        if (session == null or now > session.?.expires_at or !std.mem.eql(u8, session.?.prompt_message_id, picked.prompt_message_id)) {
            // Not (or no longer) this presser's own open menu. If the
            // prompt actually belongs to *someone else's* still-live menu
            // in this chat, say so on Telegram (Matrix has no per-press
            // alert channel, so it just stays silent) -- otherwise this is
            // simply not a menu pick at all (e.g. it's `convert_flow`'s),
            // and must be left alone.
            if (ctx.connector.platform() == .telegram and self.anyOtherSessionOwnsPrompt(chat_id, picked.prompt_message_id)) {
                ctx.connector.sendMessage(ctx.a, chat_id, "This menu isn't yours — run /menu yourself.", null);
            }
            return;
        }
        const s = session.?;

        switch (s.stage) {
            .wizard => |draft| {
                self.handleWizardPick(runner, ctx, chat_id, user_id, draft, picked);
                return;
            },
            .browsing, .awaiting_input => {},
        }

        const stack_len = s.stack.items.len;
        const n = tree.node(s.node);
        const choices = choicesFor(n, s.mode, runner, ctx, stack_len);
        const resolved = resolvePick(ctx.connector.platform(), choices, picked.value) orelse return;

        if (std.mem.eql(u8, resolved, close_value)) {
            self.closeSession(ctx.connector, ctx.a, chat_id, user_id, s.prompt_message_id);
            return;
        }
        if (std.mem.eql(u8, resolved, back_value)) {
            self.navigateBack(ctx.connector, runner, ctx, chat_id, user_id);
            return;
        }

        if (s.mode == .help) {
            // Read-only browsing: any pick just descends into it and shows
            // its description, regardless of `kind`.
            const picked_id = std.meta.stringToEnum(NodeId, resolved) orelse return;
            self.navigateInto(ctx.connector, runner, ctx, chat_id, user_id, picked_id, .help);
            return;
        }

        switch (n.kind) {
            .branch => {
                const picked_id = std.meta.stringToEnum(NodeId, resolved) orelse return;
                const picked_node = tree.node(picked_id);
                switch (picked_node.kind) {
                    // Entering `.help` specifically is what switches the
                    // session into help mode -- every other branch/
                    // dynamic_list child is navigated in `.normal`.
                    .branch, .dynamic_list => self.navigateInto(ctx.connector, runner, ctx, chat_id, user_id, picked_id, if (picked_id == .help) .help else .normal),
                    .action => self.runAndApply(ctx.connector, runner, ctx, chat_id, user_id, runner.perform(picked_id, ctx)),
                    .awaiting_input => self.beginAwaitingInput(ctx.connector, runner, ctx, chat_id, user_id, picked_id),
                    .wizard => self.beginWizard(ctx.connector, runner, ctx, chat_id, user_id, picked_id),
                }
            },
            .dynamic_list => self.runAndApply(ctx.connector, runner, ctx, chat_id, user_id, runner.performDynamicPick(s.node, resolved, ctx)),
            .action, .awaiting_input, .wizard => {}, // never "current" outside a transient instant -- nothing to pick here.
        }
    }

    /// True if some *other* session in `chat_id` currently has
    /// `prompt_message_id` as its live message — used only to decide
    /// whether a stray pick deserves the "not yours" notice.
    fn anyOtherSessionOwnsPrompt(self: *Sessions, chat_id: []const u8, prompt_message_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, chatIdOfKey(entry.key_ptr.*), chat_id)) continue;
            if (std.mem.eql(u8, entry.value_ptr.prompt_message_id, prompt_message_id)) return true;
        }
        return false;
    }

    fn navigateInto(self: *Sessions, connector: iface.Connector, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, id: NodeId, mode: Mode) void {
        const key = compositeKey(self.allocator, chat_id, user_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        var stack_len: usize = 0;
        if (self.map.getPtr(key)) |s| {
            s.stack.append(self.allocator, s.node) catch {};
            s.node = id;
            s.mode = mode;
            self.freeStage(s.stage);
            s.stage = .browsing;
            s.expires_at = ctx.now + self.timeout_seconds;
            stack_len = s.stack.items.len;
        }
        self.mutex.unlock(self.io);
        self.showNode(connector, runner, ctx, chat_id, user_id, id, mode, stack_len);
    }

    fn navigateBack(self: *Sessions, connector: iface.Connector, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8) void {
        const key = compositeKey(self.allocator, chat_id, user_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        var target: ?NodeId = null;
        var mode: Mode = .normal;
        var stack_len: usize = 0;
        if (self.map.getPtr(key)) |s| {
            target = s.stack.pop() orelse .root;
            if (target.? == .root) s.mode = .normal;
            s.node = target.?;
            self.freeStage(s.stage);
            s.stage = .browsing;
            s.expires_at = ctx.now + self.timeout_seconds;
            mode = s.mode;
            stack_len = s.stack.items.len;
        }
        self.mutex.unlock(self.io);
        const id = target orelse return;
        self.showNode(connector, runner, ctx, chat_id, user_id, id, mode, stack_len);
    }

    fn beginAwaitingInput(self: *Sessions, connector: iface.Connector, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, id: NodeId) void {
        const key = compositeKey(self.allocator, chat_id, user_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        var stack_len: usize = 0;
        if (self.map.getPtr(key)) |s| {
            s.stack.append(self.allocator, s.node) catch {};
            s.node = id;
            self.freeStage(s.stage);
            s.stage = .{ .awaiting_input = id };
            s.expires_at = ctx.now + self.timeout_seconds;
            stack_len = s.stack.items.len;
        }
        self.mutex.unlock(self.io);
        self.showNode(connector, runner, ctx, chat_id, user_id, id, .normal, stack_len);
    }

    /// Enters the reminder-creation wizard for `.wizard`-kind node `id` —
    /// the `.wizard` sibling of `beginAwaitingInput`.
    fn beginWizard(self: *Sessions, connector: iface.Connector, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, id: NodeId) void {
        const draft = runner.beginWizard(id, ctx);
        const key = compositeKey(self.allocator, chat_id, user_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        if (self.map.getPtr(key)) |s| {
            s.stack.append(self.allocator, s.node) catch {};
            s.node = id;
            self.freeStage(s.stage);
            s.stage = .{ .wizard = draft };
            s.expires_at = ctx.now + self.timeout_seconds;
        }
        self.mutex.unlock(self.io);
        self.showWizardStep(connector, ctx, chat_id, user_id, draft);
    }

    /// Overwrites the session's stored wizard draft in place (used after
    /// every stepper press/text-shortcut) — takes over `draft.message`'s
    /// ownership from the caller (the old draft's message, if any, must
    /// already have been freed by the caller before calling this).
    fn updateWizardDraft(self: *Sessions, chat_id: []const u8, user_id: []const u8, draft: ReminderDraft) void {
        const key = compositeKey(self.allocator, chat_id, user_id) catch return;
        defer self.allocator.free(key);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.getPtr(key)) |s| s.stage = .{ .wizard = draft };
    }

    /// A `choice_picked` event arrived while (chat_id, user_id) is mid-
    /// wizard — resolved against that step's own synthetic choices (built
    /// fresh from `draft`, not from `choicesFor`/the tree, since a wizard's
    /// buttons are never tree content).
    fn handleWizardPick(self: *Sessions, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, draft_in: ReminderDraft, picked: iface.ChoicePicked) void {
        const rendered = renderWizardStep(draft_in, ctx);
        const resolved = resolvePick(ctx.connector.platform(), rendered.choices, picked.value) orelse return;

        if (std.mem.eql(u8, resolved, close_value)) {
            self.closeCurrent(ctx.connector, ctx.a, chat_id, user_id);
            return;
        }
        if (std.mem.eql(u8, resolved, wiz_noop_value)) return;
        if (std.mem.eql(u8, resolved, wiz_confirm_value)) {
            self.runAndApply(ctx.connector, runner, ctx, chat_id, user_id, runner.finishWizard(draft_in, ctx));
            return;
        }
        if (std.mem.eql(u8, resolved, wiz_discard_value)) {
            self.navigateBack(ctx.connector, runner, ctx, chat_id, user_id);
            return;
        }

        var draft = draft_in;
        if (std.mem.eql(u8, resolved, wiz_dec_value)) {
            adjustDraft(&draft, -1);
        } else if (std.mem.eql(u8, resolved, wiz_inc_value)) {
            adjustDraft(&draft, 1);
        } else if (std.mem.eql(u8, resolved, wiz_prev_value)) {
            draft.step = prevStep(draft.step);
        } else if (std.mem.eql(u8, resolved, wiz_next_value)) {
            draft.step = nextStep(draft.step);
        } else {
            return;
        }
        self.updateWizardDraft(chat_id, user_id, draft);
        self.showWizardStep(ctx.connector, ctx, chat_id, user_id, draft);
    }

    /// A plain message arrived while (chat_id, user_id) is mid-wizard.
    /// `.message` step: captures it as the reminder text. Any stepper step:
    /// the "reply with a time/date to jump straight there" shortcut — a
    /// parseable date sets year/month/day and advances to the hour step; a
    /// parseable clock time sets hour/minute and jumps straight to the
    /// message step. Anything else is left alone (`false`) so normal
    /// command/LLM dispatch proceeds untouched, same convention as
    /// `handleAwaitingInputMessage`.
    fn handleWizardMessage(self: *Sessions, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, draft_in: ReminderDraft) bool {
        const text = std.mem.trim(u8, ctx.msg.text orelse "", " \t\r\n");
        if (text.len == 0) return false;
        var draft = draft_in;

        switch (draft.step) {
            .message => {
                draft.message = self.allocator.dupe(u8, text) catch return false;
                draft.step = .confirm;
            },
            .date, .hour, .minute, .second => {
                if (parseShortcutDate(text)) |d| {
                    draft.year = d.year orelse draft.year;
                    draft.month = d.month;
                    draft.day = d.day;
                    draft.step = .hour;
                } else if (reminder_format.parseClockTime(text)) |t| {
                    draft.hour = t.hour;
                    draft.minute = t.minute;
                    draft.step = .message;
                } else {
                    return false;
                }
            },
            .confirm => return false,
        }
        self.updateWizardDraft(chat_id, user_id, draft);
        self.showWizardStep(ctx.connector, ctx, chat_id, user_id, draft);
        return true;
    }

    /// Shared by `handleWizardPick`'s Close and `runAndApply`'s `.close`
    /// outcome — looks up the session's own living message id (the caller
    /// doesn't necessarily have it to hand) and tears the session down.
    fn closeCurrent(self: *Sessions, connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, user_id: []const u8) void {
        const prompt_id = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const s = self.lockedGet(chat_id, user_id) orelse break :blk null;
            break :blk self.allocator.dupe(u8, s.prompt_message_id) catch null;
        };
        defer if (prompt_id) |p| self.allocator.free(p);
        if (prompt_id) |p| self.closeSession(connector, a, chat_id, user_id, p);
    }

    fn closeSession(self: *Sessions, connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, prompt_message_id: []const u8) void {
        connector.deleteMessage(a, chat_id, prompt_message_id) catch |err| {
            log.warn("failed to delete menu message for chat {s}: {t}", .{ chat_id, err });
        };
        const key = compositeKey(self.allocator, chat_id, user_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        if (self.map.fetchRemove(key)) |old| self.freeEntry(old.key, old.value);
        self.mutex.unlock(self.io);
    }

    fn runAndApply(self: *Sessions, connector: iface.Connector, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, outcome: Outcome) void {
        switch (outcome) {
            .show => |id| self.navigateIntoReplacingTop(connector, runner, ctx, chat_id, user_id, id),
            .close => self.closeCurrent(connector, ctx.a, chat_id, user_id),
            .retry => {},
        }
    }

    /// Like `navigateInto`, but replaces the current node in place rather
    /// than pushing it onto the stack — used after an `.action`/
    /// `.awaiting_input` completes, since e.g. Kick's own node was never
    /// really "a screen" to preserve a Back-breadcrumb to.
    fn navigateIntoReplacingTop(self: *Sessions, connector: iface.Connector, runner: ActionRunner, ctx: ActionContext, chat_id: []const u8, user_id: []const u8, id: NodeId) void {
        const key = compositeKey(self.allocator, chat_id, user_id) catch return;
        defer self.allocator.free(key);

        self.mutex.lockUncancelable(self.io);
        var stack_len: usize = 0;
        var mode: Mode = .normal;
        if (self.map.getPtr(key)) |s| {
            s.node = id;
            self.freeStage(s.stage);
            s.stage = .browsing;
            s.expires_at = ctx.now + self.timeout_seconds;
            stack_len = s.stack.items.len;
            mode = s.mode;
        }
        self.mutex.unlock(self.io);
        self.showNode(connector, runner, ctx, chat_id, user_id, id, mode, stack_len);
    }

    /// A plain message (or reply) arrived from `ctx.msg`'s sender. If they
    /// have an open `awaiting_input` session, hands it to the runner; if
    /// they're mid-wizard, hands it to `handleWizardMessage` (the message
    /// capture step, or the stepper-step text shortcut). Returns `true` if
    /// consumed, `false` so normal command/LLM dispatch proceeds untouched.
    pub fn handleAwaitingInputMessage(self: *Sessions, runner: ActionRunner, ctx: ActionContext) bool {
        const chat_id = ctx.msg.chat_id;
        const user_id = ctx.msg.user_id;

        self.mutex.lockUncancelable(self.io);
        const session = self.lockedGet(chat_id, user_id);
        self.mutex.unlock(self.io);

        const s = session orelse return false;
        if (ctx.now > s.expires_at) return false;

        switch (s.stage) {
            .browsing => return false,
            .awaiting_input => |id| {
                self.runAndApply(ctx.connector, runner, ctx, chat_id, user_id, runner.resumeAwaitingInput(id, ctx));
                return true;
            },
            .wizard => |draft| return self.handleWizardMessage(ctx, chat_id, user_id, draft),
        }
    }

    /// Clears whatever's open for (chat_id, user_id) — used by `/cancel`.
    /// Returns whether anything was actually open. Doesn't touch the
    /// message itself (the caller sends its own "Cancelled." reply, same
    /// convention as `group_admin.cancel`).
    pub fn cancel(self: *Sessions, chat_id: []const u8, user_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const key = compositeKey(self.allocator, chat_id, user_id) catch return false;
        defer self.allocator.free(key);
        const removed = self.map.fetchRemove(key) orelse return false;
        self.freeEntry(removed.key, removed.value);
        return true;
    }

    /// True if (chat_id, user_id) currently has an open, unexpired session
    /// in `awaiting_input` stage — lets `/cancel`'s existing "try each
    /// pending-state owner in turn" chain check this one without consuming
    /// it, matching `PendingConversions.isAwaitingFile`'s shape.
    pub fn isAwaitingInput(self: *Sessions, now: i64, chat_id: []const u8, user_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const s = self.lockedGet(chat_id, user_id) orelse return false;
        if (now > s.expires_at) return false;
        return switch (s.stage) {
            .awaiting_input, .wizard => true,
            .browsing => false,
        };
    }

    /// Evicts every expired session — called once per main-loop tick
    /// alongside `PendingConversions.sweepExpired`. Before evicting each
    /// one, best-effort edits its living message to "Menu timeout" with no
    /// buttons (rather than leaving dead buttons sitting there forever) —
    /// `connectors` is searched for the one matching the session's stored
    /// `platform` (see `Session.platform`'s doc comment); a lookup/edit
    /// failure (message already deleted, connector gone) is logged and
    /// doesn't block the eviction itself, same "best-effort, never let a
    /// connector call block cleanup" convention `closeSession` follows.
    pub fn sweepExpired(self: *Sessions, connectors: []const iface.Connector, now: i64) void {
        // Two-phase, same reasoning as `closeSession`: the connector call
        // below can block on a real network round trip, so it must never
        // run while `self.mutex` is held (every other menu operation --
        // navigate/open/etc -- takes the same lock and would stall behind
        // it). Phase 1 removes every expired entry from the map under the
        // lock but doesn't free it yet; phase 2 (unlocked) does the
        // best-effort edit using the not-yet-freed `prompt_message_id`/key,
        // then frees.
        const Removed = struct { key: []const u8, value: Session };
        var removed_list: std.ArrayList(Removed) = .empty;
        defer removed_list.deinit(self.allocator);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            var expired_keys: std.ArrayList([]const u8) = .empty;
            defer expired_keys.deinit(self.allocator);
            var it = self.map.iterator();
            while (it.next()) |entry| {
                if (now > entry.value_ptr.expires_at) expired_keys.append(self.allocator, entry.key_ptr.*) catch continue;
            }
            for (expired_keys.items) |k| {
                const old = self.map.fetchRemove(k) orelse continue;
                removed_list.append(self.allocator, .{ .key = old.key, .value = old.value }) catch self.freeEntry(old.key, old.value);
            }
        }

        for (removed_list.items) |r| {
            if (findConnectorByPlatform(connectors, r.value.platform)) |connector| {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                connector.editChoicePrompt(arena.allocator(), chatIdOfKey(r.key), r.value.prompt_message_id, "Menu timeout", &.{}) catch |err| {
                    log.warn("failed to edit timed-out menu message for chat {s}: {t}", .{ chatIdOfKey(r.key), err });
                };
            }
            self.freeEntry(r.key, r.value);
        }
    }
};

const testing = std.testing;

fn testRunner() ActionRunner {
    const impl = struct {
        fn perform(id: NodeId, ctx: ActionContext) Outcome {
            _ = ctx;
            return .{ .show = tree.node(id).parent orelse .root };
        }
        fn dynamicChoices(id: NodeId, ctx: ActionContext) []const iface.Choice {
            _ = id;
            const out = ctx.a.alloc(iface.Choice, 1) catch return &.{};
            out[0] = .{ .emoji = "1️⃣", .label = "item-1", .value = "item-1" };
            return out;
        }
        fn performDynamicPick(id: NodeId, value: []const u8, ctx: ActionContext) Outcome {
            _ = value;
            _ = ctx;
            return .{ .show = tree.node(id).parent orelse .root };
        }
        fn resumeAwaitingInput(id: NodeId, ctx: ActionContext) Outcome {
            if (std.mem.eql(u8, ctx.msg.text orelse "", "bad")) return .retry;
            return .{ .show = tree.node(id).parent orelse .root };
        }
        fn beginWizard(id: NodeId, ctx: ActionContext) ReminderDraft {
            _ = id;
            _ = ctx;
            return .{ .year = 2026, .month = 5, .day = 22, .hour = 9, .minute = 0, .second = 0 };
        }
        fn finishWizard(draft: ReminderDraft, ctx: ActionContext) Outcome {
            _ = draft;
            _ = ctx;
            return .{ .show = .reminders };
        }
    };
    return .{
        .perform = impl.perform,
        .dynamicChoices = impl.dynamicChoices,
        .performDynamicPick = impl.performDynamicPick,
        .resumeAwaitingInput = impl.resumeAwaitingInput,
        .beginWizard = impl.beginWizard,
        .finishWizard = impl.finishWizard,
    };
}

const StubConnector = struct {
    platform_kind: iface.Platform = .telegram,
    next_message_id: usize = 1000,
    sent_messages: std.ArrayList([]const u8) = .empty,
    deleted_ids: std.ArrayList([]const u8) = .empty,
    edited: std.ArrayList([]const u8) = .empty,
    support_edit: bool = true,

    fn connector(self: *StubConnector) iface.Connector {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: iface.Connector.VTable = .{
        .platform = platformFn,
        .poll = pollFn,
        .sendMessage = sendMessageFn,
        .sendChoicePrompt = sendChoicePromptFn,
        .editChoicePrompt = editChoicePromptFn,
        .deleteMessage = deleteMessageFn,
    };

    fn platformFn(ptr: *anyopaque) iface.Platform {
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        return self.platform_kind;
    }
    fn pollFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]iface.Message {
        _ = ptr;
        _ = allocator;
        return &.{};
    }
    fn sendMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to_message_id: ?[]const u8) void {
        _ = chat_id;
        _ = reply_to_message_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(allocator, text) catch {};
    }
    /// Real Telegram/Matrix buttons carry the choice labels, not the
    /// message text — so a test asserting on "what the user would see"
    /// (e.g. a `.dynamic_list` node's live items) needs those labels
    /// recorded somewhere too. Folds them into the stored string instead of
    /// tracking a second parallel list.
    fn renderWithChoices(allocator: std.mem.Allocator, text: []const u8, choices: []const iface.Choice) []const u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        buf.writer.print("{s}", .{text}) catch return text;
        for (choices) |c| buf.writer.print("\n[{s}]", .{c.label}) catch {};
        return buf.writer.buffered();
    }
    fn sendChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, text: []const u8, choices: []const iface.Choice, reply_to_message_id: ?[]const u8) anyerror!?[]const u8 {
        _ = chat_id;
        _ = reply_to_message_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        self.sent_messages.append(allocator, renderWithChoices(allocator, text, choices)) catch {};
        self.next_message_id += 1;
        const id: ?[]const u8 = try std.fmt.allocPrint(allocator, "{d}", .{self.next_message_id});
        return id;
    }
    fn editChoicePromptFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8, text: []const u8, choices: []const iface.Choice) anyerror!void {
        _ = chat_id;
        _ = message_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        if (!self.support_edit) return error.Unsupported;
        self.edited.append(allocator, renderWithChoices(allocator, text, choices)) catch {};
    }
    fn deleteMessageFn(ptr: *anyopaque, allocator: std.mem.Allocator, chat_id: []const u8, message_id: []const u8) anyerror!void {
        _ = chat_id;
        const self: *StubConnector = @ptrCast(@alignCast(ptr));
        self.deleted_ids.append(allocator, message_id) catch {};
    }
};

fn baseCtx(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, user_id: []const u8, now: i64) ActionContext {
    return .{
        .connector = connector,
        .a = a,
        .pool = undefined,
        .config = undefined,
        .chat_id = 0,
        .identity_id = 0,
        .now = now,
        .msg = .{ .chat_id = chat_id, .user_id = user_id },
        .io = testing.io,
        .digest_scheduler = undefined,
        .pending_conversions = undefined,
    };
}

test "open sends the root menu and stores a session" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    try testing.expectEqual(@as(usize, 1), stub.sent_messages.items.len);
    try testing.expect(std.mem.indexOf(u8, stub.sent_messages.items[0], "Warden") != null);
}

test "handleChoicePicked navigates into a branch and edits the message in place" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    const prompt_id = stub.next_message_id; // the id `sendChoicePrompt` handed back

    var ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1001);
    var buf: [16]u8 = undefined;
    ctx.msg.message_id = "2";
    sessions.handleChoicePicked(testRunner(), 1001, ctx, .{
        .prompt_message_id = std.fmt.bufPrint(&buf, "{d}", .{prompt_id}) catch unreachable,
        .value = "alerts",
    });

    try testing.expectEqual(@as(usize, 1), stub.edited.items.len);
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[0], "Alerts") != null);
}

test "a different user pressing the same message gets rejected on Telegram" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    const prompt_id = stub.next_message_id;

    const ctx = baseCtx(stub.connector(), a, "chat1", "mallory", 1001);
    var buf: [16]u8 = undefined;
    sessions.handleChoicePicked(testRunner(), 1001, ctx, .{
        .prompt_message_id = std.fmt.bufPrint(&buf, "{d}", .{prompt_id}) catch unreachable,
        .value = "alerts",
    });

    try testing.expectEqual(@as(usize, 0), stub.edited.items.len);
    try testing.expect(stub.sent_messages.items.len >= 2); // the original open + the rejection notice
    try testing.expect(std.mem.indexOf(u8, stub.sent_messages.items[stub.sent_messages.items.len - 1], "isn't yours") != null);
}

test "Matrix falls back to a fresh message when editChoicePrompt is unsupported" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{ .platform_kind = .matrix, .support_edit = false };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    const prompt_id = stub.next_message_id;
    const sent_before = stub.sent_messages.items.len;

    const ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1001);
    var buf: [16]u8 = undefined;
    sessions.handleChoicePicked(testRunner(), 1001, ctx, .{
        .prompt_message_id = std.fmt.bufPrint(&buf, "{d}", .{prompt_id}) catch unreachable,
        .value = "🔔", // Matrix's ChoicePicked.value is the raw reaction emoji, not the tag name
    });

    try testing.expectEqual(@as(usize, 0), stub.edited.items.len);
    try testing.expect(stub.sent_messages.items.len > sent_before); // a fresh message was sent instead
}

test "awaiting_input round trip: a bad follow-up retries, a good one advances and re-renders" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    const prompt_id = stub.next_message_id;
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{prompt_id}) catch unreachable;

    const ctx1 = baseCtx(stub.connector(), a, "chat1", "alice", 1001);
    sessions.handleChoicePicked(runner, 1001, ctx1, .{ .prompt_message_id = pid, .value = "group_admin" });
    const ctx2 = baseCtx(stub.connector(), a, "chat1", "alice", 1002);
    sessions.handleChoicePicked(runner, 1002, ctx2, .{ .prompt_message_id = pid, .value = "group_admin_kick" });
    try testing.expect(sessions.isAwaitingInput(1002, "chat1", "alice"));

    var bad_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    bad_ctx.msg.text = "bad";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, bad_ctx));
    try testing.expect(sessions.isAwaitingInput(1003, "chat1", "alice")); // still open -- retry

    var good_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1004);
    good_ctx.msg.text = "@someone";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, good_ctx));
    try testing.expect(!sessions.isAwaitingInput(1004, "chat1", "alice")); // resolved back to browsing
}

test "cancel clears an open session and reports whether anything was open" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(!sessions.cancel("chat1", "alice"));
    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    try testing.expect(sessions.cancel("chat1", "alice"));
    try testing.expect(!sessions.isAwaitingInput(1000, "chat1", "alice"));
}

test "sweepExpired evicts only sessions past their deadline" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    sessions.sweepExpired(&.{stub.connector()}, 1000 + 59);
    try testing.expect(sessions.map.count() == 1);
    sessions.sweepExpired(&.{stub.connector()}, 1000 + 61);
    try testing.expect(sessions.map.count() == 0);
}

test "sweepExpired edits the timed-out menu message to \"Menu timeout\" with no buttons before evicting" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    sessions.sweepExpired(&.{stub.connector()}, 1000 + 61);

    try testing.expectEqual(@as(usize, 1), stub.edited.items.len);
    try testing.expectEqualStrings("Menu timeout", stub.edited.items[0]);
}

test "sweepExpired doesn't crash when no connector matches the session's platform" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    sessions.sweepExpired(&.{}, 1000 + 61);
    try testing.expect(sessions.map.count() == 0);
}

test "close deletes the message and drops the session" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    sessions.open(stub.connector(), a, testRunner(), 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    const prompt_id = stub.next_message_id;
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{prompt_id}) catch unreachable;

    const ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1001);
    sessions.handleChoicePicked(testRunner(), 1001, ctx, .{ .prompt_message_id = pid, .value = close_value });

    try testing.expectEqual(@as(usize, 1), stub.deleted_ids.items.len);
    try testing.expect(!sessions.isAwaitingInput(1001, "chat1", "alice"));
}

test "a dynamic_list node shows the runner's live choices, and picking one calls performDynamicPick" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;

    const ctx1 = baseCtx(stub.connector(), a, "chat1", "alice", 1001);
    sessions.handleChoicePicked(runner, 1001, ctx1, .{ .prompt_message_id = pid, .value = "alerts" });
    const ctx2 = baseCtx(stub.connector(), a, "chat1", "alice", 1002);
    sessions.handleChoicePicked(runner, 1002, ctx2, .{ .prompt_message_id = pid, .value = "alerts_view" });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "item-1") != null);

    const ctx3 = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    sessions.handleChoicePicked(runner, 1003, ctx3, .{ .prompt_message_id = pid, .value = "item-1" });
    // testRunner's performDynamicPick sends the node back to its parent (.alerts).
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "Alerts") != null);
}

test "help mode browses read-only: picking a module shows its help text, never runs its action" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;

    const ctx1 = baseCtx(stub.connector(), a, "chat1", "alice", 1001);
    sessions.handleChoicePicked(runner, 1001, ctx1, .{ .prompt_message_id = pid, .value = "help" });
    const ctx2 = baseCtx(stub.connector(), a, "chat1", "alice", 1002);
    sessions.handleChoicePicked(runner, 1002, ctx2, .{ .prompt_message_id = pid, .value = "alerts" });

    // Shows alerts' help_body, not its normal browsing body -- and never
    // called `perform`/pushed into `awaiting_input` the way normal mode
    // would for a non-branch child.
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "standing watch") != null);
    try testing.expect(!sessions.isAwaitingInput(1002, "chat1", "alice"));
}

/// Navigates a fresh session all the way to `reminders_new` (root ->
/// Reminders -> New reminder) — every wizard test below starts from here.
/// `now`s used for the two picks are fixed (1001/1002); callers continue
/// from 1003.
fn enterReminderWizard(sessions: *Sessions, stub: *StubConnector, a: std.mem.Allocator, runner: ActionRunner, pid: []const u8) void {
    const ctx1 = baseCtx(stub.connector(), a, "chat1", "alice", 1001);
    sessions.handleChoicePicked(runner, 1001, ctx1, .{ .prompt_message_id = pid, .value = "reminders" });
    const ctx2 = baseCtx(stub.connector(), a, "chat1", "alice", 1002);
    sessions.handleChoicePicked(runner, 1002, ctx2, .{ .prompt_message_id = pid, .value = "reminders_new" });
}

test "wizard: entering a .wizard child shows the date stepper with the runner's initial draft" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    const last = stub.edited.items[stub.edited.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, last, "step 1/6: Date") != null);
    try testing.expect(std.mem.indexOf(u8, last, "2026-05-22") != null);
}

test "wizard: +/- steps the current field, Next/Previous move linearly through date/hour/minute/second" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    // Date step: +1 day (2026-05-22 -> 2026-05-23), then Next -> Hour.
    const ctx_inc_date = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    sessions.handleChoicePicked(runner, 1003, ctx_inc_date, .{ .prompt_message_id = pid, .value = wiz_inc_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "2026-05-23") != null);
    const ctx_next1 = baseCtx(stub.connector(), a, "chat1", "alice", 1004);
    sessions.handleChoicePicked(runner, 1004, ctx_next1, .{ .prompt_message_id = pid, .value = wiz_next_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "step 2/6: Hour") != null);

    // Hour step: +1h (09h -> 10h), then Next -> Minute.
    const ctx_inc_hour = baseCtx(stub.connector(), a, "chat1", "alice", 1005);
    sessions.handleChoicePicked(runner, 1005, ctx_inc_hour, .{ .prompt_message_id = pid, .value = wiz_inc_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "10h") != null);
    const ctx_next2 = baseCtx(stub.connector(), a, "chat1", "alice", 1006);
    sessions.handleChoicePicked(runner, 1006, ctx_next2, .{ .prompt_message_id = pid, .value = wiz_next_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "step 3/6: Minute") != null);

    // Minute step: +5m (00m -> 05m), then Next -> Second.
    const ctx_inc_min = baseCtx(stub.connector(), a, "chat1", "alice", 1007);
    sessions.handleChoicePicked(runner, 1007, ctx_inc_min, .{ .prompt_message_id = pid, .value = wiz_inc_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "05m") != null);
    const ctx_next3 = baseCtx(stub.connector(), a, "chat1", "alice", 1008);
    sessions.handleChoicePicked(runner, 1008, ctx_next3, .{ .prompt_message_id = pid, .value = wiz_next_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "step 4/6: Second") != null);

    // Previous from Second goes back to Minute, and Next returns to Second.
    const ctx_prev = baseCtx(stub.connector(), a, "chat1", "alice", 1009);
    sessions.handleChoicePicked(runner, 1009, ctx_prev, .{ .prompt_message_id = pid, .value = wiz_prev_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "step 3/6: Minute") != null);
    const ctx_next4 = baseCtx(stub.connector(), a, "chat1", "alice", 1010);
    sessions.handleChoicePicked(runner, 1010, ctx_next4, .{ .prompt_message_id = pid, .value = wiz_next_value });

    // Second step: +1s (00s -> 01s), then Next -> the message step (no stepper).
    const ctx_inc_sec = baseCtx(stub.connector(), a, "chat1", "alice", 1011);
    sessions.handleChoicePicked(runner, 1011, ctx_inc_sec, .{ .prompt_message_id = pid, .value = wiz_inc_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "01s") != null);
    const ctx_next5 = baseCtx(stub.connector(), a, "chat1", "alice", 1012);
    sessions.handleChoicePicked(runner, 1012, ctx_next5, .{ .prompt_message_id = pid, .value = wiz_next_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "Send the reminder message") != null);
}

test "wizard: the message step captures a follow-up message and shows the confirm summary" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    // Shortcut straight past the steppers: a bare time on the date step
    // jumps directly to the message step (skipping date/hour/minute/second).
    var time_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    time_ctx.msg.text = "13:37";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, time_ctx));
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "Send the reminder message") != null);

    var msg_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1004);
    msg_ctx.msg.text = "water the plants";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, msg_ctx));
    const confirm_text = stub.edited.items[stub.edited.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, confirm_text, "step 6/6: Confirm") != null);
    try testing.expect(std.mem.indexOf(u8, confirm_text, "water the plants") != null);
    try testing.expect(std.mem.indexOf(u8, confirm_text, "13:37") != null);
}

test "wizard: a date reply on a stepper step jumps straight there and advances to the hour step" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    var date_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    date_ctx.msg.text = "12/31/2026";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, date_ctx));
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "step 2/6: Hour") != null);
}

test "wizard: unparseable text on a stepper step is left alone for normal dispatch" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    var bad_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    bad_ctx.msg.text = "hello there";
    try testing.expect(!sessions.handleAwaitingInputMessage(runner, bad_ctx));
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "step 1/6: Date") != null); // unchanged
}

test "wizard: Discard from the confirm screen exits back to Reminders without leaking the draft message" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    var time_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    time_ctx.msg.text = "13:37";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, time_ctx));
    var msg_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1004);
    msg_ctx.msg.text = "water the plants";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, msg_ctx));

    const ctx_discard = baseCtx(stub.connector(), a, "chat1", "alice", 1005);
    sessions.handleChoicePicked(runner, 1005, ctx_discard, .{ .prompt_message_id = pid, .value = wiz_discard_value });
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "Reminders") != null);
    try testing.expect(!sessions.isAwaitingInput(1005, "chat1", "alice"));
}

test "wizard: Create on the confirm screen calls finishWizard and shows its outcome" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    var time_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    time_ctx.msg.text = "13:37";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, time_ctx));
    var msg_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1004);
    msg_ctx.msg.text = "water the plants";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, msg_ctx));

    const ctx_confirm = baseCtx(stub.connector(), a, "chat1", "alice", 1005);
    sessions.handleChoicePicked(runner, 1005, ctx_confirm, .{ .prompt_message_id = pid, .value = wiz_confirm_value });
    // testRunner's finishWizard navigates to .reminders on success.
    try testing.expect(std.mem.indexOf(u8, stub.edited.items[stub.edited.items.len - 1], "Reminders") != null);
    try testing.expect(!sessions.isAwaitingInput(1005, "chat1", "alice"));
}

test "wizard: Close mid-wizard tears the session down cleanly (no leaked draft message)" {
    var sessions = Sessions.init(testing.allocator, testing.io, 60);
    defer sessions.deinit();
    var stub = StubConnector{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runner = testRunner();

    sessions.open(stub.connector(), a, runner, 1000, .{ .chat_id = "chat1", .user_id = "alice", .message_id = "1" });
    var buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{stub.next_message_id}) catch unreachable;
    enterReminderWizard(&sessions, &stub, a, runner, pid);

    var time_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1003);
    time_ctx.msg.text = "13:37";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, time_ctx));
    var msg_ctx = baseCtx(stub.connector(), a, "chat1", "alice", 1004);
    msg_ctx.msg.text = "water the plants";
    try testing.expect(sessions.handleAwaitingInputMessage(runner, msg_ctx));

    const ctx_close = baseCtx(stub.connector(), a, "chat1", "alice", 1005);
    sessions.handleChoicePicked(runner, 1005, ctx_close, .{ .prompt_message_id = pid, .value = close_value });
    try testing.expectEqual(@as(usize, 1), stub.deleted_ids.items.len);
    // The leak checker on `sessions.deinit()`/the arena above is the real
    // assertion here: a bug in `freeStage` would surface as a testing
    // allocator failure, not a normal `expect`.
}
