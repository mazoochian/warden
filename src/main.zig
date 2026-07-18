const std = @import("std");
const Io = std.Io;

const config_mod = @import("config.zig");
const auth = @import("auth.zig");
const iface = @import("platform/interface.zig");
const telegram_platform = @import("platform/telegram.zig");
const matrix_platform = @import("platform/matrix.zig");
const store_pool = @import("store/pool.zig");
const migrate = @import("store/migrate.zig");
const chats = @import("store/chats.zig");
const identities = @import("store/identities.zig");
const chat_members = @import("store/chat_members.zig");
const chat_settings = @import("store/chat_settings.zig");
const bot_config = @import("store/bot_config.zig");
const messages = @import("store/messages.zig");
const stats = @import("store/stats.zig");
const reminders = @import("store/reminders.zig");
const reminder_format = @import("features/reminder_format.zig");
const llm = @import("llm/provider.zig");
const AnthropicProvider = @import("llm/anthropic.zig").AnthropicProvider;
const OpenAiCompatProvider = @import("llm/openai_compat.zig").OpenAiCompatProvider;
const qa = @import("features/qa.zig");
const toolcall = @import("llm/toolcall.zig");
const tool_registry = @import("tools/registry.zig");
const group_admin = @import("features/group_admin.zig");
const wordcloud = @import("features/wordcloud.zig");
const digest = @import("features/digest.zig");
const scheduler = @import("features/scheduler.zig");
const convert_file = @import("tools/convert_file.zig");

const base_tools = [_]tool_registry.ToolDef{
    @import("tools/calculator.zig").tool,
    @import("tools/weather.zig").tool,
    @import("tools/air_quality.zig").tool,
    @import("tools/currency.zig").tool,
    @import("tools/crypto_price.zig").tool,
    @import("tools/fetch_url.zig").tool,
    @import("tools/scrape_site.zig").tool,
    @import("tools/draw_diagram.zig").tool,
    @import("tools/qr_code.zig").tool,
    @import("tools/word_cloud.zig").tool,
    @import("tools/dictionary.zig").tool,
    @import("tools/urban_dictionary.zig").tool,
    @import("tools/hackernews.zig").tool,
    @import("tools/remind.zig").tool,
    convert_file.tool,
};
const web_search_tool = @import("tools/web_search.zig").tool;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const config = config_mod.Config.load(init.environ_map, init.arena.allocator(), io) catch |err| {
        std.log.err("config error: {t} (did you set WARDEN_TELEGRAM_BOT_TOKEN and WARDEN_POSTGRES_DSN?)", .{err});
        return err;
    };

    // web_search only joins the tool list when an instance is configured,
    // so the model never sees a tool that's guaranteed to fail.
    var tools_buf: [base_tools.len + 1]tool_registry.ToolDef = undefined;
    @memcpy(tools_buf[0..base_tools.len], &base_tools);
    var tools_len: usize = base_tools.len;
    if (config.searxng_url != null) {
        tools_buf[tools_len] = web_search_tool;
        tools_len += 1;
    } else {
        std.log.info("web search disabled (set WARDEN_SEARXNG_URL to enable)", .{});
    }
    const active_tools = tools_buf[0..tools_len];

    var telegram_adapter = telegram_platform.TelegramConnector.init(gpa, io, config.telegram_bot_token);
    defer telegram_adapter.deinit();

    // Matrix only joins the active connector list when configured (see
    // `config.zig`'s `matrix` field) — `matrix_adapter` lives in `main`'s own
    // stack frame for the whole run, so `&matrix_adapter.?` below stays valid
    // for as long as its `Connector` does.
    var matrix_adapter: ?matrix_platform.MatrixConnector = if (config.matrix) |mc|
        matrix_platform.MatrixConnector.init(gpa, io, mc.homeserver_url, mc.access_token)
    else
        null;
    defer if (matrix_adapter) |*m| m.deinit();

    var connectors_buf: [2]iface.Connector = undefined;
    var connectors_len: usize = 0;
    connectors_buf[connectors_len] = telegram_adapter.connector();
    connectors_len += 1;
    if (matrix_adapter) |*m| {
        connectors_buf[connectors_len] = m.connector();
        connectors_len += 1;
    }
    const connectors: []const iface.Connector = connectors_buf[0..connectors_len];
    const max_message_len = effectiveMaxMessageLength(connectors);

    var pool = try store_pool.PgPool.init(gpa, io, config.postgres_dsn, config.postgres_pool_size);
    defer pool.deinit();
    {
        const db = try pool.acquire();
        defer pool.release(db);
        try migrate.migrate(db, gpa);
    }

    var pending_confirmations = group_admin.PendingConfirmations.init(gpa, io, config.confirm_timeout_seconds);
    defer pending_confirmations.deinit();

    var digest_scheduler = scheduler.DigestScheduler.init(gpa, io, config.digest_interval_seconds);
    defer digest_scheduler.deinit();
    loadDigestScheduleFromDisk(gpa, &pool, &digest_scheduler);

    // Heap-allocated: whichever variant isn't selected never gets
    // constructed, and the process-lifetime singleton is fine to leave for
    // the OS to reclaim on exit rather than threading a deinit through
    // both branches here.
    const llm_provider: llm.Provider = switch (config.llm) {
        .anthropic => |a| blk: {
            const p = try gpa.create(AnthropicProvider);
            p.* = AnthropicProvider.init(gpa, io, a.api_key, a.model);
            break :blk p.provider();
        },
        .openai_compat => |o| blk: {
            const p = try gpa.create(OpenAiCompatProvider);
            p.* = OpenAiCompatProvider.init(gpa, io, o.base_url, o.api_key, o.model, config.llm_show_thinking);
            break :blk p.provider();
        },
    };

    std.log.info("warden started, {d} connector(s), {d} owner(s) configured", .{ connectors.len, config.owners.len });

    // Long-lived: every message spawns a task into this group (never
    // awaited/canceled during normal operation — see `Group`'s doc comment
    // on why that's fine for a repeatedly-added-to, long-lived group). This
    // is what keeps one slow chat (a stuck LLM call, a slow tool) from
    // blocking polling or any other chat: the loop below only ever does the
    // fast, sequential parts (poll, group by nothing — spawn per message,
    // check digests) and never blocks on `handleMessage` itself.
    var worker_group: Io.Group = .init;

    while (true) {
        for (connectors) |connector| {
            var poll_arena = std.heap.ArenaAllocator.init(gpa);
            defer poll_arena.deinit();
            const poll_a = poll_arena.allocator();

            const polled_messages = connector.poll(poll_a) catch |err| {
                switch (err) {
                    // A long poll whose connection died or never came up is
                    // operationally an empty poll: updates queue server-side
                    // until the next successful getUpdates, so nothing is
                    // lost. Flaky networks kill idle connections at the ~30s
                    // long-poll mark and drop TLS handshakes during rough
                    // patches routinely — warn, don't alarm.
                    error.HttpConnectionClosing,
                    error.TlsInitializationFailed,
                    => std.log.warn("poll connection dropped (will re-poll): {t}", .{err}),
                    else => std.log.err("poll failed: {t}", .{err}),
                }
                // A failed poll returns immediately instead of blocking for
                // the ~30s long-poll window, so during an outage this loop
                // would otherwise spin against a dead network. Cool off
                // before the next attempt.
                Io.sleep(io, .fromSeconds(5), .awake) catch {};
                continue;
            };

            for (polled_messages) |msg| {
                const ts = Io.Timestamp.now(io, .real).toSeconds();

                // Each task owns an arena for its whole lifetime, created
                // here (not shared with `poll_arena`, which this cycle
                // frees as soon as every message in it has been spawned
                // off) and freed by the task itself when it's done. `msg`
                // is duped into it right away, before `poll_arena` can be
                // freed out from under a task that hasn't started yet.
                const task_arena = gpa.create(std.heap.ArenaAllocator) catch |err| {
                    std.log.err("failed to allocate task arena: {t}", .{err});
                    continue;
                };
                task_arena.* = std.heap.ArenaAllocator.init(gpa);
                const duped_msg = msg.dupe(task_arena.allocator()) catch |err| {
                    std.log.err("failed to dupe message for chat {s}: {t}", .{ msg.chat_id, err });
                    task_arena.deinit();
                    gpa.destroy(task_arena);
                    continue;
                };

                worker_group.async(io, processMessageTask, .{
                    connector,
                    &config,
                    &pool,
                    llm_provider,
                    active_tools,
                    &pending_confirmations,
                    &digest_scheduler,
                    io,
                    gpa,
                    ts,
                    max_message_len,
                    task_arena,
                    duped_msg,
                });
            }
        }

        // Piggybacks on the poll loop's natural ~30s cadence (Telegram's
        // long-poll timeout) rather than a separate timer/thread — fine
        // granularity for a daily-ish interval. Runs once per lap over every
        // connector (not once per connector) since a due digest/reminder
        // needs to be matched to whichever connector actually owns its
        // chat's platform, not delivered through whichever connector
        // happened to be polling most recently.
        const now = Io.Timestamp.now(io, .real).toSeconds();
        checkAndSendDueDigests(connectors, gpa, io, &config, &pool, &digest_scheduler, llm_provider, max_message_len, now);
        checkAndSendDueReminders(connectors, gpa, &pool, now);
    }
}

/// Finds the connector whose platform matches `platform` among `connectors`
/// — the lookup `checkAndSendDueDigests`/`checkAndSendDueReminders` need to
/// deliver a due item through the right connector once more than one is
/// active (see `chats.ChatRef`'s doc comment).
fn findConnector(connectors: []const iface.Connector, platform: iface.Platform) ?iface.Connector {
    for (connectors) |c| {
        if (c.platform() == platform) return c;
    }
    return null;
}

/// Fallback used when no connector declares a `maxMessageLength` (shouldn't
/// happen today — Telegram always does) — Telegram's own limit, the
/// tightest of any platform actually implemented so far (see
/// `iface.Connector.VTable.maxMessageLength`'s doc comment).
const default_max_message_length: usize = 4096;

/// The tightest `maxMessageLength` across every active connector. A single
/// deployment could eventually run more than one platform connector at
/// once, each with its own limit (see `iface.Platform`); capping generated
/// text to the smallest of them keeps it valid everywhere without the
/// answer/digest generation paths needing to know which platforms are
/// actually active.
fn effectiveMaxMessageLength(connectors: []const iface.Connector) usize {
    var min_len: usize = default_max_message_length;
    for (connectors) |c| {
        if (c.maxMessageLength()) |len| min_len = @min(min_len, len);
    }
    return min_len;
}

/// Sends `text` normally if it fits within `max_len`, otherwise attaches it
/// as a `.txt` file instead — the fallback for text too long for the
/// active platform(s)' limit (LLM answers, digests). `filename` names the
/// attachment when the fallback fires.
fn sendTextOrFile(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, text: []const u8, reply_to: ?[]const u8, max_len: usize, filename: []const u8) void {
    if (text.len <= max_len) {
        connector.sendMessage(a, chat_id, text, reply_to);
        return;
    }
    connector.sendDocument(a, chat_id, text, filename, "That was too long for a single message — attached as a file.");
}

/// Body of one spawned per-message task (see `worker_group` above). Owns
/// `task_arena` end-to-end: created by the caller right before spawning
/// (so `duped_msg` has somewhere stable to live), destroyed here once this
/// message is fully handled.
fn processMessageTask(
    connector: iface.Connector,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    llm_provider: llm.Provider,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    io: Io,
    gpa: std.mem.Allocator,
    ts: i64,
    max_message_len: usize,
    task_arena: *std.heap.ArenaAllocator,
    msg: iface.Message,
) void {
    defer {
        task_arena.deinit();
        gpa.destroy(task_arena);
    }
    const a = task_arena.allocator();

    const chat_id = chats.upsertChat(pool, connector.platform(), msg.chat_id, msg.chat_type, msg.chat_title) catch |err| {
        std.log.err("failed to upsert chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };

    // Every group member's message counts toward this chat's local record
    // (stats/content recall), regardless of who sent it — only
    // replies/actions are owner-gated below.
    const identity_id = resolveSenderIdentity(pool, connector, msg, ts) catch |err| {
        std.log.err("failed to resolve identity for user {s}: {t}", .{ msg.user_id, err });
        return;
    };
    recordMessage(pool, chat_id, identity_id, msg.message_id, msg.text, ts, config.retention_messages);

    // Downloaded eagerly (not lazily on first tool use) since it's cheap
    // relative to the LLM round trip this task is about to make anyway, and
    // keeps `convert_file`'s execute() simple (just read ctx.attachment_path,
    // never fetch bytes itself). Deleted once this task is done regardless
    // of whether any tool actually touched it — `task_arena`'s deinit only
    // frees memory, not files on disk.
    var attachment_cleanup_path: ?[]const u8 = null;
    defer if (attachment_cleanup_path) |p| Io.Dir.cwd().deleteFile(io, p) catch {};
    const attachment_path = if (msg.attachment) |att| blk: {
        const path = downloadAttachment(connector, io, a, config.tmp_dir, att);
        attachment_cleanup_path = path;
        break :blk path;
    } else null;

    var reminder_adapter: ReminderToolAdapter = .{
        .pool = pool,
        .chat_id = chat_id,
        .identity_id = identity_id,
        .is_owner = auth.isOwner(config, connector.platform(), msg.user_id),
        .now = ts,
    };
    const tool_ctx = tool_registry.ToolContext{
        .allocator = a,
        .io = io,
        .connector = connector,
        .chat_id = msg.chat_id,
        .tmp_dir = config.tmp_dir,
        .searxng_url = config.searxng_url,
        .scraper = bot_config.loadScraperConfig(pool, a),
        .now = ts,
        .reminders = reminder_adapter.sink(),
        .attachment_path = attachment_path,
        .attachment_file_name = if (msg.attachment) |att| att.file_name else null,
        .attachment_mime = if (msg.attachment) |att| att.mime_type else null,
    };
    handleMessage(connector, a, config, pool, chat_id, identity_id, llm_provider, tool_ctx, tools, pending, digest_scheduler, io, ts, max_message_len, msg);
}

/// Downloads `att`'s bytes into `tmp_dir` and returns the local file path
/// (allocated in `allocator`), or null on any failure (connector doesn't
/// support downloads, network error, disk write error) — all logged, none
/// propagated, since a failed download shouldn't stop the rest of message
/// handling (LLM Q&A, other tools) from running; `convert_file` just
/// reports "no file attached" when `ctx.attachment_path` ends up null.
/// Written straight to disk rather than kept in memory and handed back,
/// since document/video attachments can run tens of MB.
fn downloadAttachment(connector: iface.Connector, io: Io, allocator: std.mem.Allocator, tmp_dir: []const u8, att: iface.Attachment) ?[]const u8 {
    const bytes = connector.downloadFile(allocator, att.file_id) catch |err| {
        std.log.warn("attachment: download failed for file_id {s}: {t}", .{ att.file_id, err });
        return null;
    };
    defer allocator.free(bytes);

    Io.Dir.cwd().createDirPath(io, tmp_dir) catch |err| {
        std.log.warn("attachment: failed to create tmp dir {s}: {t}", .{ tmp_dir, err });
        return null;
    };

    const ts = Io.Timestamp.now(io, .real).toNanoseconds();
    const path = std.fmt.allocPrint(allocator, "{s}/attach_{d}{s}", .{ tmp_dir, ts, extensionFor(att) }) catch return null;

    var file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        std.log.warn("attachment: failed to create {s}: {t}", .{ path, err });
        return null;
    };
    defer file.close(io);
    var file_writer = file.writer(io, &.{});
    file_writer.interface.writeAll(bytes) catch |err| {
        std.log.warn("attachment: failed to write {s}: {t}", .{ path, err });
        return null;
    };
    file_writer.interface.flush() catch |err| {
        std.log.warn("attachment: failed to flush {s}: {t}", .{ path, err });
        return null;
    };

    return path;
}

/// Best-effort extension (leading dot included) for a downloaded
/// attachment's local file name — prefers the original filename's own
/// extension when Telegram sent one, falling back to a kind-appropriate
/// default so `convert_file` still has something plausible to dispatch on.
fn extensionFor(att: iface.Attachment) []const u8 {
    if (att.file_name) |name| {
        if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i..];
    }
    return switch (att.kind) {
        .photo => ".jpg",
        .document => "",
        .voice => ".ogg",
        .audio => ".mp3",
        .video => ".mp4",
    };
}

/// Stand-in `qa.answer` question for a captionless attachment, so the
/// model's `user_content` still names what just arrived instead of reading
/// "Question: " with nothing after it.
fn attachmentPlaceholder(allocator: std.mem.Allocator, att: iface.Attachment) ![]const u8 {
    const kind_desc = switch (att.kind) {
        .photo => "a photo",
        .document => "a document",
        .voice => "a voice message",
        .audio => "an audio file",
        .video => "a video",
    };
    if (att.file_name) |name| {
        return std.fmt.allocPrint(allocator, "[The user sent {s} named \"{s}\", with no caption.]", .{ kind_desc, name });
    }
    return std.fmt.allocPrint(allocator, "[The user sent {s}, with no caption.]", .{kind_desc});
}

/// Resolves (upserting as needed) the internal `identities.id` for a
/// message's sender. Prefers the full `Identity`/`TelegramProfile` the
/// connector already built from the platform's wire format; falls back to a
/// minimal placeholder (e.g. `msg.identity` unset because `msg.from` was
/// absent) so a message never fails to log just because identity data was
/// thin.
fn resolveSenderIdentity(pool: *store_pool.PgPool, connector: iface.Connector, msg: iface.Message, ts: i64) !i64 {
    if (msg.identity) |identity| {
        const identity_id = try identities.upsertIdentity(pool, identity);
        if (msg.telegram_profile) |profile| {
            identities.upsertTelegramProfile(pool, identity_id, profile) catch |err| {
                std.log.err("failed to upsert telegram profile for identity {d}: {t}", .{ identity_id, err });
            };
        }
        return identity_id;
    }
    return identities.getOrCreateMinimal(pool, connector.platform(), msg.user_id, msg.username orelse msg.user_id, false, ts);
}

/// Logs one message and bumps the sender's chat-membership record, then
/// prunes to the retention window — replaces the old `ChatStore.record`.
/// Errors are logged, not propagated: a storage hiccup shouldn't take down
/// the poll loop.
fn recordMessage(pool: *store_pool.PgPool, chat_id: i64, identity_id: i64, message_id: ?[]const u8, text: ?[]const u8, ts: i64, retention: i64) void {
    messages.insert(pool, chat_id, identity_id, message_id, text, ts) catch |err| {
        std.log.err("failed to insert message for chat {d}: {t}", .{ chat_id, err });
        return;
    };
    chat_members.touch(pool, chat_id, identity_id, ts) catch |err| {
        std.log.err("failed to touch chat_members for chat {d}: {t}", .{ chat_id, err });
    };
    messages.pruneKeepLast(pool, chat_id, retention) catch |err| {
        std.log.err("prune failed for chat {d}: {t}", .{ chat_id, err });
    };
}

/// Rebuilds the in-memory enabled-chat set from every known chat's
/// persisted `chat_settings.digest_enabled` — so digests opted into before
/// a restart keep firing rather than silently going quiet.
fn loadDigestScheduleFromDisk(gpa: std.mem.Allocator, pool: *store_pool.PgPool, digest_scheduler: *scheduler.DigestScheduler) void {
    const refs = chats.listAll(pool, gpa) catch |err| {
        std.log.err("digest: failed to scan existing chats: {t}", .{err});
        return;
    };
    defer {
        for (refs) |r| gpa.free(r.native_chat_id);
        gpa.free(refs);
    }

    for (refs) |ref| {
        if (chat_settings.getDigestEnabled(pool, ref.id)) {
            digest_scheduler.enable(ref.platform, ref.native_chat_id) catch |err| {
                std.log.err("digest: failed to restore schedule for chat {s}: {t}", .{ ref.native_chat_id, err });
            };
        }
    }
}

/// Delivers through whichever of `connectors` actually owns each due chat's
/// platform (see `findConnector`) — a chat whose platform has no active
/// connector (shouldn't normally happen; guards against a stale/removed
/// platform's leftover `chat_settings` row) is skipped with a log line
/// rather than silently misdelivered through an unrelated connector.
fn checkAndSendDueDigests(
    connectors: []const iface.Connector,
    gpa: std.mem.Allocator,
    io: Io,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    digest_scheduler: *scheduler.DigestScheduler,
    llm_provider: llm.Provider,
    max_message_len: usize,
    now: i64,
) void {
    const enabled_chats = digest_scheduler.snapshotEnabledChatIds(gpa) catch |err| {
        std.log.err("digest: failed to snapshot enabled chats: {t}", .{err});
        return;
    };
    defer {
        for (enabled_chats) |k| gpa.free(k.native_chat_id);
        gpa.free(enabled_chats);
    }

    for (enabled_chats) |key| {
        const native_chat_id = key.native_chat_id;
        const connector = findConnector(connectors, key.platform) orelse {
            std.log.warn("digest: no active connector for platform {s}, skipping chat {s}", .{ @tagName(key.platform), native_chat_id });
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // `chat_type`/`title` null: this isn't a fresh inbound message, just
        // a scheduled check, and `upsertChat` preserves whatever's already
        // stored for those columns when passed null (see its doc comment).
        const chat_id = chats.upsertChat(pool, connector.platform(), native_chat_id, null, null) catch |err| {
            std.log.err("digest: failed to resolve chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };

        const last_sent = chat_settings.getLastDigestTs(pool, chat_id);
        if (now - last_sent < config.digest_interval_seconds) continue;

        const tool_ctx = tool_registry.ToolContext{
            .allocator = a,
            .io = io,
            .connector = connector,
            .chat_id = native_chat_id,
            .tmp_dir = config.tmp_dir,
            .searxng_url = config.searxng_url,
            .scraper = bot_config.loadScraperConfig(pool, a),
        };
        const digest_text = digest.generate(llm_provider, a, tool_ctx, pool, chat_id) catch |err| {
            std.log.err("digest: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            continue;
        };
        sendTextOrFile(connector, a, native_chat_id, digest_text, null, max_message_len, "digest.txt");
        chat_settings.setLastDigestTs(pool, chat_id, now) catch |err| {
            std.log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ native_chat_id, err });
        };
    }
}

fn handleMessage(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    pending: *group_admin.PendingConfirmations,
    digest_scheduler: *scheduler.DigestScheduler,
    io: Io,
    now: i64,
    max_message_len: usize,
    msg: iface.Message,
) void {
    // A photo/document/voice/audio/video with no caption has no `text` at
    // all (Telegram never sets it for those), but it still deserves a
    // reply when addressed to the bot — the attachment alone is enough for
    // e.g. convert_file to have something to work with. Only bail when
    // there's neither text nor an attachment to react to.
    const text = msg.text orelse "";
    if (text.len == 0 and msg.attachment == null) return;

    if (std.mem.eql(u8, text, "/ping")) {
        connector.sendMessage(a, msg.chat_id, "pong", msg.message_id);
    } else if (std.mem.eql(u8, text, "/stats")) {
        replyWithStats(connector, a, pool, chat_id, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/wordcloud")) {
        replyWithWordcloud(connector, a, pool, chat_id, config.tmp_dir, io, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/digest") or std.mem.startsWith(u8, text, "/digest ")) {
        handleDigestCommand(connector, a, pool, chat_id, digest_scheduler, llm_provider, tool_ctx, now, max_message_len, msg.chat_id, msg.message_id, text);
    } else if (std.mem.eql(u8, text, "/mute")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.mute(connector, a, msg, now);
    } else if (std.mem.eql(u8, text, "/unmute")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.unmute(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/pin")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.pin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/unpin")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.unpin(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/delete")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.deleteMessage(connector, a, msg);
    } else if (std.mem.eql(u8, text, "/kick")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.requestConfirmation(connector, a, pool, chat_id, now, msg, .kick);
    } else if (std.mem.eql(u8, text, "/ban")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.requestConfirmation(connector, a, pool, chat_id, now, msg, .ban);
    } else if (std.mem.eql(u8, text, "/confirm")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.confirm(connector, a, pending, now, msg);
    } else if (std.mem.eql(u8, text, "/cancel")) {
        if (!isAuthorizedForGroupAdmin(connector, a, config, msg)) return;
        group_admin.cancel(connector, a, pending, msg);
    } else if (std.mem.startsWith(u8, text, "/token")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return;
        handleToken(connector, a, pool, chat_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/magicword") or std.mem.startsWith(u8, text, "/magicword ")) {
        handleMagicWord(connector, a, config, pool, chat_id, msg, text);
    } else if (std.mem.eql(u8, text, "/scraper") or std.mem.startsWith(u8, text, "/scraper ")) {
        if (!auth.isOwner(config, connector.platform(), msg.user_id)) return;
        handleScraperCommand(connector, a, pool, msg, text);
    } else if (std.mem.eql(u8, text, "/remind") or std.mem.startsWith(u8, text, "/remind ")) {
        handleRemindCommand(connector, a, config, pool, chat_id, identity_id, now, msg, text);
    } else if (std.mem.eql(u8, text, "/reminders")) {
        handleRemindersList(connector, a, pool, chat_id, now, msg.chat_id, msg.message_id);
    } else if (std.mem.eql(u8, text, "/convert") or std.mem.startsWith(u8, text, "/convert ")) {
        handleConvertCommand(connector, a, tool_ctx, msg, text);
    } else if (text.len > 0 and text[0] == '/') {
        // Unrecognized slash command: ignore rather than forwarding to the
        // LLM as if it were a question.
        return;
    } else if (isAddressedToBot(a, pool, chat_id, msg, text)) {
        // The bot's free-form LLM Q&A is owner-only by default (toggle via
        // WARDEN_LLM_OWNER_ONLY) — every other command above this stays
        // open to anyone (unchanged). Silent, not an error reply: an
        // unaddressed mention from someone else shouldn't announce "I only
        // answer my owner" to the whole group.
        if (config.llm_owner_only and !auth.isOwner(config, connector.platform(), msg.user_id)) return;
        const replied_to = if (msg.reply_to_is_me) msg.reply_to_text else null;
        // Captionless attachment: give the model something to read instead
        // of an empty "Question: " (see `qa.answer`'s `user_content`
        // formatting) so it still knows a file just came in and can reach
        // for convert_file if that's what makes sense.
        const question = if (text.len > 0)
            text
        else if (msg.attachment) |att|
            attachmentPlaceholder(a, att) catch text
        else
            text;
        replyWithAnswer(connector, a, pool, chat_id, llm_provider, tool_ctx, tools, config.system_prompt, io, now, config.retention_messages, max_message_len, msg.chat_id, msg.message_id, question, replied_to);
    }
}

/// Gate for every group-management command (/mute, /kick, /ban, etc.) —
/// the bot owner always passes (no network round trip needed), otherwise
/// this asks Telegram directly whether the sender currently administers
/// this chat. Queried fresh each time rather than cached, since admin
/// status can change at any moment; any error (network hiccup, or a
/// platform connector that doesn't implement `isGroupAdmin` at all) fails
/// closed — treated as "not authorized" rather than silently allowing the
/// action through. Silent on rejection, matching /token's and /scraper's
/// existing owner-gate convention rather than announcing "you're not
/// allowed" to the chat.
fn isAuthorizedForGroupAdmin(connector: iface.Connector, a: std.mem.Allocator, config: *const config_mod.Config, msg: iface.Message) bool {
    if (auth.isOwner(config, connector.platform(), msg.user_id)) return true;
    return connector.isGroupAdmin(a, msg.chat_id, msg.user_id) catch |err| {
        std.log.warn("group_admin: admin check failed for user {s} in chat {s}: {t}", .{ msg.user_id, msg.chat_id, err });
        return false;
    };
}

/// A non-command message deserves a reply when it's a DM, mentions the bot,
/// replies to one of the bot's messages, or says the chat's configured
/// magic word (a per-chat setting; see /magicword).
fn isAddressedToBot(a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, msg: iface.Message, text: []const u8) bool {
    if (!msg.is_group) return true;
    if (msg.mentions_me or msg.reply_to_is_me) return true;

    const magic = chat_settings.getMagicWord(pool, a, chat_id) orelse return false;
    return containsWordIgnoreCase(text, magic);
}

const magic_word_key = "magic_word";
const max_magic_word_len = 64;

fn handleMagicWord(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/magicword".len..], " ");

    if (arg.len == 0) {
        const reply_text = if (chat_settings.getMagicWord(pool, a, chat_id)) |word|
            std.fmt.allocPrint(a, "Magic word: \"{s}\" — say it in any message and I'll answer. You can also mention me or reply to my messages. Change it with /magicword <word>, disable with /magicword off.", .{word}) catch return
        else
            "No magic word set — mention me or reply to my messages to get an answer. Set one with /magicword <word>.";
        connector.sendMessage(a, msg.chat_id, reply_text, msg.message_id);
        return;
    }

    if (!auth.isOwner(config, connector.platform(), msg.user_id)) {
        reply(connector, a, msg.chat_id, msg.message_id, "Only the bot owner can change the magic word.");
        return;
    }

    if (std.mem.eql(u8, arg, "off")) {
        chat_settings.setMagicWord(pool, chat_id, null) catch |err| {
            std.log.err("magicword: failed to clear for chat {s}: {t}", .{ msg.chat_id, err });
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Magic word disabled — I'll still answer mentions and replies.");
        return;
    }

    if (arg.len > max_magic_word_len or std.mem.indexOfScalar(u8, arg, ' ') != null) {
        reply(connector, a, msg.chat_id, msg.message_id, "The magic word must be a single word (max 64 bytes).");
        return;
    }

    chat_settings.setMagicWord(pool, chat_id, arg) catch |err| {
        std.log.err("magicword: failed to set for chat {s}: {t}", .{ msg.chat_id, err });
        return;
    };
    const confirmation = std.fmt.allocPrint(a, "Magic word set to \"{s}\" — I'll answer any message that contains it.", .{arg}) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

/// Owner-only, unlike /magicword: the whole command (including viewing) is
/// gated in the dispatcher above, since the config here can include a
/// remote endpoint/API key that shouldn't be visible to random chat
/// members. Bot-wide, not per-chat — see `store/bot_config.zig`.
fn handleScraperCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/scraper".len..], " ");

    if (arg.len == 0) {
        const snap = bot_config.loadScraperConfig(pool, a);
        const remote_desc = snap.remote_url orelse "(not set)";
        const key_desc = if (snap.remote_api_key != null) "set" else "not set";
        const status = std.fmt.allocPrint(
            a,
            "Scraper mode: {s}\nRemote endpoint: {s}\nRemote API key: {s}\n\nUsage:\n/scraper mode local|remote\n/scraper url <endpoint>\n/scraper apikey <key>|off",
            .{ @tagName(snap.mode), remote_desc, key_desc },
        ) catch return;
        connector.sendMessage(a, msg.chat_id, status, msg.message_id);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const sub = it.first();
    const rest = std.mem.trim(u8, it.rest(), " ");

    if (std.mem.eql(u8, sub, "mode")) {
        if (std.mem.eql(u8, rest, "remote")) {
            const snap = bot_config.loadScraperConfig(pool, a);
            if (snap.remote_url == null) {
                reply(connector, a, msg.chat_id, msg.message_id, "Set a remote endpoint first with /scraper url <endpoint>.");
                return;
            }
            bot_config.setScraperMode(pool, .remote) catch |err| {
                std.log.err("scraper: failed to set mode for global settings: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update the scraper mode, try again.");
                return;
            };
            const confirmation = std.fmt.allocPrint(a, "Scraper mode set to remote ({s}).", .{snap.remote_url.?}) catch return;
            connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
        } else if (std.mem.eql(u8, rest, "local")) {
            bot_config.setScraperMode(pool, .local) catch |err| {
                std.log.err("scraper: failed to set mode for global settings: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't update the scraper mode, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Scraper mode set to local (on-device extraction).");
        } else {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /scraper mode local|remote");
        }
    } else if (std.mem.eql(u8, sub, "url")) {
        if (rest.len == 0) {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /scraper url <endpoint>");
            return;
        }
        bot_config.setScraperRemoteUrl(pool, rest) catch |err| {
            std.log.err("scraper: failed to set remote url: {t}", .{err});
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that endpoint, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper endpoint saved. Switch to it with /scraper mode remote.");
    } else if (std.mem.eql(u8, sub, "apikey")) {
        if (rest.len == 0 or std.mem.eql(u8, rest, "off")) {
            bot_config.setScraperRemoteApiKey(pool, null) catch |err| {
                std.log.err("scraper: failed to clear remote api key: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't clear the API key, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper API key cleared.");
        } else {
            bot_config.setScraperRemoteApiKey(pool, rest) catch |err| {
                std.log.err("scraper: failed to set remote api key: {t}", .{err});
                reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save the API key, try again.");
                return;
            };
            reply(connector, a, msg.chat_id, msg.message_id, "Remote scraper API key saved.");
        }
    } else {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: /scraper [mode local|remote] [url <endpoint>] [apikey <key>|off]");
    }
}

fn handleToken(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    now: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const target = replyTarget(msg) orelse {
        reply(connector, a, msg.chat_id, msg.message_id, "Reply to the user you want to view/change tokens for.");
        return;
    };
    const arg = std.mem.trim(u8, text["/token".len..], " ");
    const target_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), target.user_id, target.label, false, now) catch |err| {
        std.log.err("token: failed to resolve identity for user {s}: {t}", .{ target.user_id, err });
        return;
    };
    // If there is no argument, get the current token count and reply with it.
    if (arg.len == 0) {
        const count = chat_members.getTokens(pool, chat_id, target_identity_id, 0);
        const message = std.fmt.allocPrint(a, "Current token count: {}", .{count}) catch |err| {
            std.debug.print("Failed to allocate message string: {}\n", .{err});
            return; // Exit the function early since we couldn't format the message
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
        return;
    }
    // Else just set the token count to the parsed value and reply with a confirmation.
    else {
        const count = std.fmt.parseInt(i64, arg, 10) catch 0;
        std.log.info("Detected the count to be {}", .{count});
        chat_members.setTokens(pool, chat_id, target_identity_id, count) catch |err| {
            std.log.err("Failed to set tokens on the databse: {}\n", .{err});
            return;
        };
        const message = std.fmt.allocPrint(a, "token count updated to {}", .{count}) catch |err| {
            std.log.err("Failed to allocate message string: {}\n", .{err});
            return; // Exit the function early since we couldn't format the message
        };
        connector.sendMessage(a, msg.chat_id, message, msg.message_id);
    }
}

fn handleDigestCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    digest_scheduler: *scheduler.DigestScheduler,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    now: i64,
    max_message_len: usize,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/digest".len..], " ");

    if (std.mem.eql(u8, arg, "on")) {
        digest_scheduler.enable(connector.platform(), native_chat_id) catch |err| {
            std.log.err("digest: failed to enable for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't enable digests, try again.", reply_to);
            return;
        };
        chat_settings.setDigestEnabled(pool, chat_id, true) catch |err| {
            std.log.err("digest: failed to persist enabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        const hours = @divTrunc(digest_scheduler.interval_seconds, 3600);
        const msg_text = std.fmt.allocPrint(a, "Digest enabled — I'll post one roughly every {d}h.", .{hours}) catch return;
        connector.sendMessage(a, native_chat_id, msg_text, reply_to);
    } else if (std.mem.eql(u8, arg, "off")) {
        digest_scheduler.disable(a, connector.platform(), native_chat_id);
        chat_settings.setDigestEnabled(pool, chat_id, false) catch |err| {
            std.log.err("digest: failed to persist disabled flag for chat {s}: {t}", .{ native_chat_id, err });
        };
        connector.sendMessage(a, native_chat_id, "Digest disabled.", reply_to);
    } else if (std.mem.eql(u8, arg, "now")) {
        const digest_text = digest.generate(llm_provider, a, tool_ctx, pool, chat_id) catch |err| {
            std.log.err("digest: generate failed for chat {s}: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, "Couldn't generate a digest just now.", reply_to);
            return;
        };
        sendTextOrFile(connector, a, native_chat_id, digest_text, reply_to, max_message_len, "digest.txt");
        chat_settings.setLastDigestTs(pool, chat_id, now) catch |err| {
            std.log.err("digest: failed to persist last_digest_ts for chat {s}: {t}", .{ native_chat_id, err });
        };
    } else {
        const enabled = digest_scheduler.isEnabled(a, connector.platform(), native_chat_id);
        const last = chat_settings.getLastDigestTs(pool, chat_id);
        const msg_text = if (last == 0)
            std.fmt.allocPrint(
                a,
                "Digest is {s}. Never sent yet. Use /digest on, /digest off, or /digest now.",
                .{if (enabled) "on" else "off"},
            ) catch return
        else
            std.fmt.allocPrint(
                a,
                "Digest is {s}. Last sent {d}s ago. Use /digest on, /digest off, or /digest now.",
                .{ if (enabled) "on" else "off", now - last },
            ) catch return;
        connector.sendMessage(a, native_chat_id, msg_text, reply_to);
    }
}

const max_reminder_message_len = 500;

/// `/remind <duration|clock-time> <message>` sets a one-off reminder;
/// `/remind every <interval> <message>` sets a recurring one; `/remind
/// cancel <id>` cancels one. Open to anyone in the chat to create
/// (utility-level, like /wordcloud), but only its own creator or the bot
/// owner may cancel it — matches `/token`'s reply-to-target pattern of
/// trusting the sender's own identity_id rather than requiring group-admin
/// standing.
fn handleRemindCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    config: *const config_mod.Config,
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    now: i64,
    msg: iface.Message,
    text: []const u8,
) void {
    const usage = "Usage: /remind <duration e.g. 30m/2h/1d, or a clock time like 14:30> <message>, /remind every <interval> <message>, or /remind cancel <id>";
    const arg = std.mem.trim(u8, text["/remind".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }

    var it = std.mem.splitScalar(u8, arg, ' ');
    const first_word = it.first();

    if (std.mem.eql(u8, first_word, "cancel")) {
        const rest = std.mem.trim(u8, it.rest(), " ");
        const id = std.fmt.parseInt(i64, rest, 10) catch {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /remind cancel <id> (see /reminders for ids).");
            return;
        };
        const rem = (reminders.get(pool, a, id) catch |err| {
            std.log.err("remind: lookup failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't look up that reminder, try again.");
            return;
        }) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "No pending reminder with that id.");
            return;
        };
        if (rem.chat_id != chat_id) {
            reply(connector, a, msg.chat_id, msg.message_id, "No pending reminder with that id.");
            return;
        }
        if (rem.identity_id != identity_id and !auth.isOwner(config, connector.platform(), msg.user_id)) {
            reply(connector, a, msg.chat_id, msg.message_id, "Only whoever set that reminder (or the owner) can cancel it.");
            return;
        }
        reminders.cancel(pool, id) catch |err| {
            std.log.err("remind: cancel failed for id {d}: {t}", .{ id, err });
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't cancel that reminder, try again.");
            return;
        };
        reply(connector, a, msg.chat_id, msg.message_id, "Reminder canceled.");
        return;
    }

    var recur_interval: ?i64 = null;
    var when_str = first_word;
    if (std.mem.eql(u8, first_word, "every")) {
        when_str = it.next() orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Usage: /remind every <interval e.g. 1d> <message>");
            return;
        };
        recur_interval = reminder_format.parseDuration(when_str) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that interval — use e.g. 30m, 2h, or 1d.");
            return;
        };
    }

    const message = std.mem.trim(u8, it.rest(), " ");
    if (message.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, usage);
        return;
    }
    if (message.len > max_reminder_message_len) {
        reply(connector, a, msg.chat_id, msg.message_id, "That reminder text is too long (max 500 bytes).");
        return;
    }

    const due_at = if (recur_interval) |interval|
        now + interval
    else
        reminder_format.parseWhen(when_str, now) orelse {
            reply(connector, a, msg.chat_id, msg.message_id, "Couldn't parse that time — use a duration like 30m/2h/1d, or a 24h clock time like 14:30.");
            return;
        };

    const id = reminders.create(pool, chat_id, identity_id, message, due_at, recur_interval) catch |err| {
        std.log.err("remind: failed to create reminder for chat {d}: {t}", .{ chat_id, err });
        reply(connector, a, msg.chat_id, msg.message_id, "Couldn't save that reminder, try again.");
        return;
    };

    const confirmation = if (recur_interval) |interval|
        std.fmt.allocPrint(a, "Reminder #{d} set, repeating every {s}.", .{ id, reminder_format.formatInterval(a, interval) }) catch return
    else if (reminder_format.parseDuration(when_str) != null)
        std.fmt.allocPrint(a, "Reminder #{d} set for {s} from now.", .{ id, when_str }) catch return
    else
        std.fmt.allocPrint(a, "Reminder #{d} set for {s}.", .{ id, when_str }) catch return;
    connector.sendMessage(a, msg.chat_id, confirmation, msg.message_id);
}

fn handleRemindersList(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    now: i64,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const pending = reminders.listPending(pool, a, chat_id) catch |err| {
        std.log.err("reminders: list failed for chat {d}: {t}", .{ chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't load reminders, try again.", reply_to);
        return;
    };
    connector.sendMessage(a, native_chat_id, formatPendingReminders(a, pending, now), reply_to);
}

/// Direct entry point to `convert_file` (see `tools/convert_file.zig`) for
/// people who'd rather type an explicit command than phrase a request in
/// natural language — same file (`tool_ctx.attachment_path`, downloaded by
/// `processMessageTask` before `handleMessage` ever runs) and same
/// conversion logic, just skipping the LLM round trip. `text` is the
/// caption Telegram delivered on the attached photo/document/voice/audio/
/// video, e.g. "/convert pdf".
fn handleConvertCommand(
    connector: iface.Connector,
    a: std.mem.Allocator,
    tool_ctx: tool_registry.ToolContext,
    msg: iface.Message,
    text: []const u8,
) void {
    const arg = std.mem.trim(u8, text["/convert".len..], " ");
    if (arg.len == 0) {
        reply(connector, a, msg.chat_id, msg.message_id, "Usage: send a photo, document, voice note, audio, or video with \"/convert <format>\" as its caption, e.g. /convert pdf.");
        return;
    }
    const input_json = std.json.Stringify.valueAlloc(a, .{ .target_format = arg }, .{}) catch return;
    const result = convert_file.tool.execute(tool_ctx, input_json) catch |err| {
        std.log.err("convert: /convert command failed: {t}", .{err});
        reply(connector, a, msg.chat_id, msg.message_id, "Something went wrong converting that file, try again.");
        return;
    };
    connector.sendMessage(a, msg.chat_id, result, msg.message_id);
}

/// Shared by `/reminders` and the `set_reminder` LLM tool's `action=list`.
fn formatPendingReminders(a: std.mem.Allocator, pending: []const reminders.PendingReminder, now: i64) []const u8 {
    if (pending.len == 0) return "No pending reminders. Set one with /remind <duration> <message> (or just ask).";

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Pending reminders:\n", .{}) catch return "";
    for (pending) |r| {
        if (r.recur_interval_seconds) |interval| {
            w.print("  #{d} in {s} (repeats every {s}): {s}\n", .{ r.id, reminder_format.formatRemaining(a, r.due_at - now), reminder_format.formatInterval(a, interval), r.message }) catch return "";
        } else {
            w.print("  #{d} in {s}: {s}\n", .{ r.id, reminder_format.formatRemaining(a, r.due_at - now), r.message }) catch return "";
        }
    }
    return buf.writer.buffered();
}

/// Wires the `set_reminder` LLM tool (see `tools/remind.zig`) to real
/// Postgres-backed reminders for one specific message's chat/sender —
/// constructed fresh per message in `processMessageTask` since `chat_id`/
/// `identity_id`/`is_owner` all vary per sender, then handed to the tool
/// loop as a `registry.ReminderSink`.
const ReminderToolAdapter = struct {
    pool: *store_pool.PgPool,
    chat_id: i64,
    identity_id: i64,
    is_owner: bool,
    now: i64,

    fn sink(self: *ReminderToolAdapter) tool_registry.ReminderSink {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt: tool_registry.ReminderSink.VTable = .{
        .create = createFn,
        .cancel = cancelFn,
        .listPending = listPendingFn,
    };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, message: []const u8, due_at: i64, recur_interval_seconds: ?i64) anyerror!i64 {
        const self: *ReminderToolAdapter = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return reminders.create(self.pool, self.chat_id, self.identity_id, message, due_at, recur_interval_seconds);
    }

    fn cancelFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!tool_registry.ReminderSink.CancelResult {
        const self: *ReminderToolAdapter = @ptrCast(@alignCast(ptr));
        const rem = (try reminders.get(self.pool, allocator, id)) orelse return .not_found;
        if (rem.chat_id != self.chat_id) return .not_found;
        if (rem.identity_id != self.identity_id and !self.is_owner) return .not_authorized;
        try reminders.cancel(self.pool, id);
        return .canceled;
    }

    fn listPendingFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *ReminderToolAdapter = @ptrCast(@alignCast(ptr));
        const pending = try reminders.listPending(self.pool, allocator, self.chat_id);
        return formatPendingReminders(allocator, pending, self.now);
    }
};

/// Delivers through whichever of `connectors` owns each due reminder's
/// platform — see `checkAndSendDueDigests`'s doc comment for the same
/// reasoning. A reminder whose platform has no active connector is left
/// undelivered (not marked delivered) so it retries next cycle instead of
/// being silently lost.
fn checkAndSendDueReminders(
    connectors: []const iface.Connector,
    gpa: std.mem.Allocator,
    pool: *store_pool.PgPool,
    now: i64,
) void {
    const due = reminders.dueUndelivered(pool, gpa, now) catch |err| {
        std.log.err("remind: failed to query due reminders: {t}", .{err});
        return;
    };
    defer {
        for (due) |r| {
            gpa.free(r.native_chat_id);
            gpa.free(r.message);
        }
        gpa.free(due);
    }

    for (due) |r| {
        const connector = findConnector(connectors, r.platform) orelse {
            std.log.warn("remind: no active connector for platform {s}, leaving reminder {d} pending", .{ @tagName(r.platform), r.id });
            continue;
        };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();

        const text = std.fmt.allocPrint(a, "⏰ Reminder: {s}", .{r.message}) catch continue;
        connector.sendMessage(a, r.native_chat_id, text, null);

        if (r.recur_interval_seconds) |interval| {
            const next_due = reminder_format.nextOccurrence(r.due_at, interval, now);
            reminders.reschedule(pool, r.id, next_due) catch |err| {
                std.log.err("remind: failed to reschedule recurring reminder {d}: {t}", .{ r.id, err });
            };
        } else {
            reminders.markDelivered(pool, r.id, now) catch |err| {
                std.log.err("remind: failed to mark reminder {d} delivered: {t}", .{ r.id, err });
            };
        }
    }
}

/// Shown while waiting on the model with nothing more specific to show (see
/// `TickerState`/`tickerLoop`). Used to cycle through several dot-count
/// frames, re-editing the message every tick — but that meant the ticker
/// kept hitting Telegram's edit rate limit even when nothing had actually
/// changed, sometimes causing edits (including the final answer) to get
/// dropped. Now static, so `tickerLoop`'s dedupe against `last_sent` means
/// no edit is sent at all until real progress (a tool call) has something
/// new to show.
const thinking_text = "🤔 Thinking...";
/// Telegram's edits are throttled to roughly 1/sec per chat in practice;
/// this keeps a comfortable margin under that.
const ticker_interval_ms: i64 = 1200;

/// Shared between `replyWithAnswer` (which owns it), the ticker task, and
/// the `toolcall.Progress` callback that updates it — all touching `status`
/// only through the mutex, since the ticker runs as an independent
/// concurrent task. `allocator` backs the "using X" text `onProgressEvent`
/// formats; `onProgressEvent` only ever runs on the main per-message task
/// (synchronously inside `qa.answer`/`toolcall.run`), never the ticker
/// task, so it's safe for this to be the same per-message arena the rest
/// of that task uses — see `tickerLoop`'s doc comment for why the ticker
/// itself must NOT share it.
const TickerState = struct {
    io: Io,
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    /// null = show the generic thinking animation; set = show this until
    /// the model moves past the tool call that set it.
    status: ?[]const u8 = null,

    fn setStatus(self: *TickerState, text: ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.status = text;
    }

    fn getStatus(self: *TickerState) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.status;
    }
};

fn onProgressEvent(ptr: *anyopaque, event: toolcall.Progress.Event) void {
    const state: *TickerState = @ptrCast(@alignCast(ptr));
    switch (event) {
        .thinking => state.setStatus(null),
        .tool_use => |name| {
            const text = std.fmt.allocPrint(state.allocator, "🔧 using {s}…", .{name}) catch return;
            state.setStatus(text);
        },
    }
}

/// Runs until canceled (see `replyWithAnswer`), editing `message_id` no
/// more than once per `ticker_interval_ms` — the generic thinking
/// animation, or whatever `state.status` currently says, whichever's
/// current. Dedupes against the last text it actually sent so a run of
/// identical statuses (or a tick where nothing changed) doesn't trigger a
/// wasted edit — besides being pointless, Telegram rejects a no-op edit
/// ("message is not modified"), which `editMessage` can't distinguish from
/// a real failure (see its doc comment).
///
/// Deliberately does NOT take the per-message arena `replyWithAnswer` and
/// `qa.answer` use — this runs as a genuinely concurrent task (a real OS
/// thread under `Io.Threaded`), and `std.heap.ArenaAllocator` has no
/// internal locking, so two threads allocating from the same arena at once
/// corrupts its bookkeeping. That was the actual cause of a reported hang:
/// no timeout ever fired because the corruption happened inside allocator
/// internals, nowhere near the network code the timeouts guard. Every
/// allocation `editMessage`'s call chain makes is `defer`-freed by itself
/// (no reliance on arena-wholesale-free), so a plain thread-safe allocator
/// works fine here — no arena needed.
fn tickerLoop(connector: iface.Connector, chat_id: []const u8, message_id: []const u8, state: *TickerState) void {
    var last_sent: []const u8 = thinking_text;
    while (true) {
        Io.sleep(state.io, .fromMilliseconds(ticker_interval_ms), .awake) catch return;

        const status = state.getStatus();
        const text = status orelse thinking_text;

        if (!std.mem.eql(u8, text, last_sent)) {
            connector.editMessage(std.heap.page_allocator, chat_id, message_id, text) catch |err| {
                std.log.warn("ticker: edit failed for chat {s}: {t}", .{ chat_id, err });
            };
            last_sent = text;
        }
    }
}

fn replyWithAnswer(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    llm_provider: llm.Provider,
    tool_ctx: tool_registry.ToolContext,
    tools: []const tool_registry.ToolDef,
    system_prompt: ?[]const u8,
    io: Io,
    now: i64,
    retention_messages: i64,
    max_message_len: usize,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
    question: []const u8,
    replied_to: ?[]const u8,
) void {
    // The placeholder + ticker only work when the platform supports
    // editing (Telegram does); anything that doesn't falls back to
    // exactly the old behavior — one blocking call, one send at the end.
    const placeholder_id = connector.sendMessageReturningId(a, native_chat_id, thinking_text, reply_to) catch |err| blk: {
        std.log.warn("qa: couldn't send a placeholder for chat {s}, falling back to a plain reply: {t}", .{ native_chat_id, err });
        break :blk null;
    };
    std.log.info("qa: placeholder for chat {s} = {?s}", .{ native_chat_id, placeholder_id });

    var state = TickerState{ .io = io, .allocator = a };
    var progress: toolcall.Progress = .{};
    var ticker_future: ?Io.Future(void) = null;
    if (placeholder_id) |pid| {
        progress = .{ .ptr = &state, .onEvent = onProgressEvent };
        ticker_future = Io.concurrent(io, tickerLoop, .{ connector, native_chat_id, pid, &state }) catch |err| blk: {
            std.log.warn("qa: couldn't start the thinking animation for chat {s}: {t}", .{ native_chat_id, err });
            break :blk null;
        };
    }

    std.log.info("qa: calling the model for chat {s}", .{native_chat_id});
    const raw_answer_or_err = qa.answer(llm_provider, a, tool_ctx, tools, pool, chat_id, system_prompt, max_message_len, question, replied_to, progress);

    // Stop the ticker before touching the placeholder ourselves — it's the
    // sole owner of that Future until this point (see `Future.cancel`'s
    // "not threadsafe" note), and cancel() blocks until it has actually
    // stopped, so there's no risk of it clobbering the final edit below.
    if (ticker_future) |*f| _ = f.cancel(io);
    std.log.info("qa: model call for chat {s} returned", .{native_chat_id});

    const raw_answer = raw_answer_or_err catch |err| {
        std.log.err("qa: failed to answer in chat {s}: {t}", .{ native_chat_id, err });
        const error_text = "Sorry, I couldn't reach the model just now.";
        if (placeholder_id) |pid| {
            if (connector.editMessage(a, native_chat_id, pid, error_text)) |_| {
                std.log.info("qa: error message edited into placeholder for chat {s}", .{native_chat_id});
            } else |edit_err| {
                std.log.warn("qa: editing error message into placeholder failed for chat {s}: {t}, sending a new message instead", .{ native_chat_id, edit_err });
                connector.sendMessage(a, native_chat_id, error_text, reply_to);
            }
        } else {
            connector.sendMessage(a, native_chat_id, error_text, reply_to);
        }
        return;
    };

    // Models occasionally produce a whitespace-only answer (e.g. after a
    // photo-sending tool already did the visible work); Telegram rejects
    // empty text with a 400, so don't try to send it — and don't leave the
    // placeholder stuck showing "thinking" forever either.
    const answer = std.mem.trim(u8, raw_answer, " \t\r\n");
    std.log.info("qa: answer for chat {s} is {d} bytes (raw {d})", .{ native_chat_id, answer.len, raw_answer.len });
    if (answer.len == 0) {
        std.log.info("qa: empty answer for chat {s}, deleting placeholder", .{native_chat_id});
        if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
            // Previously swallowed silently — if this fails (network
            // hiccup, message already gone), the placeholder is stuck
            // showing "thinking" forever with zero trace of why. At least
            // log it; there's no good fallback text to edit in instead
            // since there was never a real answer to show.
            std.log.warn("qa: failed to delete empty-answer placeholder for chat {s}: {t}", .{ native_chat_id, err });
        };
        return;
    }

    if (answer.len > max_message_len) {
        // Too long for this platform's limit — editing the placeholder
        // in-place with it would just fail the same way sending it fresh
        // would, so drop the placeholder and attach it as a file instead.
        std.log.info("qa: answer for chat {s} exceeds max_message_len ({d} > {d}), sending as a file", .{ native_chat_id, answer.len, max_message_len });
        if (placeholder_id) |pid| connector.deleteMessage(a, native_chat_id, pid) catch |err| {
            std.log.warn("qa: failed to delete placeholder before file fallback for chat {s}: {t}", .{ native_chat_id, err });
        };
        sendTextOrFile(connector, a, native_chat_id, answer, reply_to, max_message_len, "answer.txt");
    } else if (placeholder_id) |pid| {
        if (connector.editMessage(a, native_chat_id, pid, answer)) |_| {
            std.log.info("qa: final answer edited into placeholder for chat {s}", .{native_chat_id});
        } else |err| {
            std.log.warn("qa: final edit failed for chat {s}, sending a new message instead: {t}", .{ native_chat_id, err });
            connector.sendMessage(a, native_chat_id, answer, reply_to);
        }
    } else {
        connector.sendMessage(a, native_chat_id, answer, reply_to);
    }

    // Log the bot's own reply too, so follow-up questions see it in the
    // history window (inbound polling never echoes our own sends back).
    // Resolved to a real identity row (the bot's own), not the old
    // hardcoded `user_id = "warden"` placeholder.
    const bot_username = connector.selfUsername() orelse "warden";
    const bot_identity_id = identities.getOrCreateMinimal(pool, connector.platform(), connector.selfId() orelse "warden", bot_username, true, now) catch |err| {
        std.log.err("qa: failed to resolve bot identity for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };
    recordMessage(pool, chat_id, bot_identity_id, null, answer, now, retention_messages);
}

fn replyWithWordcloud(
    connector: iface.Connector,
    a: std.mem.Allocator,
    pool: *store_pool.PgPool,
    chat_id: i64,
    tmp_dir: []const u8,
    io: Io,
    native_chat_id: []const u8,
    reply_to: ?[]const u8,
) void {
    const words = wordcloud.topWords(a, pool, chat_id, 60) catch |err| {
        std.log.err("wordcloud: tokenize failed for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };
    if (words.len == 0) {
        connector.sendMessage(a, native_chat_id, "Not enough logged messages yet to build a word cloud.", reply_to);
        return;
    }
    const png = wordcloud.render(a, io, tmp_dir, words) catch |err| {
        std.log.err("wordcloud: render failed for chat {s}: {t}", .{ native_chat_id, err });
        connector.sendMessage(a, native_chat_id, "Couldn't render the word cloud (is Node installed?).", reply_to);
        return;
    };
    connector.sendPhoto(a, native_chat_id, png, "Word cloud of recent messages");
}

fn replyWithStats(connector: iface.Connector, a: std.mem.Allocator, pool: *store_pool.PgPool, chat_id: i64, native_chat_id: []const u8, reply_to: ?[]const u8) void {
    const s = stats.compute(pool, a, chat_id, 5) catch |err| {
        std.log.err("stats: query failed for chat {s}: {t}", .{ native_chat_id, err });
        return;
    };

    var buf: std.Io.Writer.Allocating = .init(a);
    const w = &buf.writer;
    w.print("Messages logged: {d}\nActive users: {d}\nTop users:\n", .{ s.total_messages, s.distinct_users }) catch return;
    for (s.top_users) |u| {
        if (u.username.len > 0) {
            w.print("  @{s}: {d}\n", .{ u.username, u.message_count }) catch return;
        } else {
            w.print("  {s}: {d}\n", .{ u.user_id, u.message_count }) catch return;
        }
    }

    connector.sendMessage(a, native_chat_id, buf.writer.buffered(), reply_to);
}

// Zig's test collector only walks `test` blocks reachable from the file
// passed to `addTest` — it does NOT transitively pull in tests from files
// that are merely `@import`ed for their declarations. Each module below
// that has its own `test` blocks must be explicitly re-referenced here (or
// `zig build test` silently runs zero of its tests, no error, no warning).
test {
    _ = auth;
    _ = @import("store/pool.zig");
    _ = @import("store/migrate.zig");
    _ = @import("store/identities.zig");
    _ = @import("store/chats.zig");
    _ = @import("store/chat_members.zig");
    _ = @import("store/chat_settings.zig");
    _ = @import("store/bot_config.zig");
    _ = @import("store/messages.zig");
    _ = @import("store/stats.zig");
    _ = @import("store/reminders.zig");
    _ = @import("features/reminder_format.zig");
    _ = @import("tools/remind.zig");
    _ = @import("features/convert.zig");
    _ = @import("tools/convert_file.zig");
    _ = @import("llm/anthropic.zig");
    _ = @import("llm/openai_compat.zig");
    _ = @import("tools/calculator.zig");
    _ = @import("llm/toolcall.zig");
    _ = @import("features/group_admin.zig");
    _ = @import("features/wordcloud.zig");
    _ = @import("tools/weather.zig");
    _ = @import("tools/currency.zig");
    _ = @import("tools/fetch_url.zig");
    _ = @import("tools/draw_diagram.zig");
    _ = @import("tools/web_search.zig");
    _ = @import("tools/air_quality.zig");
    _ = @import("tools/crypto_price.zig");
    _ = @import("tools/qr_code.zig");
    _ = @import("tools/word_cloud.zig");
    _ = @import("tools/dictionary.zig");
    _ = @import("tools/urban_dictionary.zig");
    _ = @import("tools/hackernews.zig");
    _ = @import("platform/telegram.zig");
    _ = @import("http_util.zig");
    _ = @import("features/scheduler.zig");
    _ = @import("features/digest.zig");
    _ = @import("tools/html_extract.zig");
    _ = @import("tools/scrape_site.zig");
    _ = @import("platform/interface.zig");
    _ = @import("domain/identity.zig");
    _ = @import("domain/telegram_profile.zig");
    _ = @import("platform/matrix.zig");
    _ = @import("platform/xmpp.zig");
}

/// ASCII whitespace/punctuation counts as a boundary; bytes >= 0x80 do NOT,
/// so a UTF-8 word (e.g. Persian) embedded inside a longer word isn't a
/// false match, while the same word delimited by spaces/punctuation is.
fn isWordBoundary(c: u8) bool {
    return c < 0x80 and !std.ascii.isAlphanumeric(c);
}

/// Whole-word, ASCII-case-insensitive search — used for magic-word
/// detection so "Hassan," matches a magic word of "hassan" but
/// "hassanabad" doesn't.
fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;

    var start: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(haystack, start, needle)) |abs_idx| {
        const end_idx = abs_idx + needle.len;

        const left_ok = (abs_idx == 0) or isWordBoundary(haystack[abs_idx - 1]);
        const right_ok = (end_idx == haystack.len) or isWordBoundary(haystack[end_idx]);

        if (left_ok and right_ok) {
            return true;
        }

        start = abs_idx + 1;
    }

    return false;
}

test "containsWordIgnoreCase matches whole words in any ASCII case" {
    try std.testing.expect(containsWordIgnoreCase("hey Hassan, got a sec?", "hassan"));
    try std.testing.expect(containsWordIgnoreCase("HASSAN!", "hassan"));
    try std.testing.expect(containsWordIgnoreCase("hassan", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("hassanabad is a city", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("ahassan", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("nothing relevant", "hassan"));
    try std.testing.expect(!containsWordIgnoreCase("anything", ""));
}

test "containsWordIgnoreCase handles UTF-8 magic words" {
    // Persian "حسن" delimited by spaces/punctuation matches...
    try std.testing.expect(containsWordIgnoreCase("سلام حسن جان", "حسن"));
    try std.testing.expect(containsWordIgnoreCase("حسن!", "حسن"));
    // ...but the same bytes inside a longer word ("محسن") do not.
    try std.testing.expect(!containsWordIgnoreCase("محسن اومد", "حسن"));
}

fn replyTarget(msg: iface.Message) ?struct { user_id: []const u8, label: []const u8 } {
    const user_id = msg.reply_to_user_id orelse return null;
    const label = msg.reply_to_username orelse user_id;
    return .{ .user_id = user_id, .label = label };
}

fn reply(connector: iface.Connector, a: std.mem.Allocator, chat_id: []const u8, reply_to: ?[]const u8, comptime txt: []const u8) void {
    connector.sendMessage(a, chat_id, txt, reply_to);
}
