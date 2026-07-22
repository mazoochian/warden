const std = @import("std");
const Io = std.Io;

pub const c = @cImport({
    @cInclude("libpq-fe.h");
});

/// Max bound parameters any single query in this codebase uses. libpq has
/// no incremental bind API like SQLite's `sqlite3_bind_*` — every parameter
/// has to be handed to `PQexecParams` at once — so `Stmt` buffers bound
/// values by index until `step()` first runs the query.
const max_params = 16;

/// How often `runWithDeadline` re-checks the background thread's done flag
/// — same idiom/value as `pool.zig`'s `acquire` poll loop and
/// `http_util.zig`'s `fetchWithTimeout`.
const poll_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// Slack added on top of `statement_timeout_seconds` to get
/// `Db.query_timeout_ns`. `statement_timeout` is a *server-side* clock that
/// only starts once Postgres actually receives a query — it does nothing
/// for a query lost in transit (see `db.zig`'s module-level `open` doc
/// comment) — so the client-side deadline in `runWithDeadline` has to be
/// somewhat longer than it, to give a query that *did* arrive time to hit
/// its own server-side timeout and have the result travel back, rather
/// than the client giving up first on an otherwise-healthy slow query.
const query_timeout_slack_ns: u64 = 15 * std.time.ns_per_s;

pub const Db = struct {
    conn: *c.PGconn,
    /// Used to own per-`Stmt` scratch allocations (bound param text) — each
    /// `Stmt` gets its own arena off this, freed on `finalize()`.
    allocator: std.mem.Allocator,
    io: Io,
    /// Wall-clock deadline `runWithDeadline` enforces around every `exec`/
    /// `Stmt.step` on this connection — see `query_timeout_slack_ns`.
    query_timeout_ns: u64,
    /// Set by `runWithDeadline` when a query blows its deadline. The
    /// abandoned thread may still be mid-syscall on `conn` at any point in
    /// the future, so once this is true `conn` must never be touched again
    /// (no more queries, no `close`) — `PgPool.release` checks this and
    /// retires the slot instead of returning it to the free list.
    poisoned: bool = false,

    /// `statement_timeout_seconds` bounds every query run on this connection
    /// server-side (via a session `SET` right after connecting) — without
    /// it, a single wedged query (lock contention, a network stall between
    /// warden and Postgres) blocks the calling thread forever with no
    /// recourse: these are plain blocking `libpq` C calls, entirely outside
    /// `Io`, so there's no cancellation or timeout wrapper possible from the
    /// caller's side the way `http_util.zig` manages for HTTP — or rather,
    /// there wasn't; `exec`/`Stmt.step` now run through `runWithDeadline`,
    /// which gives them exactly that. Confirmed live (2026-07-22) as the
    /// likely cause of a production hang where a message-handling task
    /// never returned, never logged an error, and permanently froze its
    /// platform's poll loop (see `PgPool`'s doc comment for the full
    /// chain). A `connect_timeout` is applied the same way, so even the
    /// initial TCP handshake can't hang indefinitely either.
    ///
    /// Confirmed live again (2026-07-23), on the same VPS: even with
    /// `statement_timeout` and `connect_timeout` both in place, the bot
    /// still wedged in a way only a Postgres *container* restart (not a
    /// warden restart) cleared — the Postgres server had zero TCP
    /// keepalives configured, and this DSN set none either, on a network
    /// path (Docker bridge, behind a CGNAT-ish NAT — see
    /// `warden-vps-ssh-keepalive`) already known to silently drop idle
    /// connections with no FIN/RST. A connection that dies while sitting
    /// idle in `PgPool` looks perfectly healthy right up until the next
    /// query is sent into the void: Postgres never receives it, so
    /// `statement_timeout`'s clock never starts, and the client blocks in a
    /// raw `recv()` with nothing to interrupt it. `appendConnectionOptions`
    /// below now adds `keepalives_*` so a dead peer gets detected in ~50s
    /// instead of never, and `runWithDeadline` adds a client-side backstop
    /// on top in case keepalives themselves are ever unavailable (e.g. a
    /// LISTEN/NOTIFY-style long call, or the far side just never sending
    /// keepalive ACKs back).
    pub fn open(allocator: std.mem.Allocator, io: Io, dsn: [:0]const u8, statement_timeout_seconds: i64) !Db {
        const dsn_with_options = try appendConnectionOptions(allocator, dsn);
        defer allocator.free(dsn_with_options);

        const conn = c.PQconnectdb(dsn_with_options.ptr) orelse return error.PgConnectFailed;
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            std.log.err("PQconnectdb failed: {s}", .{std.mem.span(c.PQerrorMessage(conn))});
            c.PQfinish(conn);
            return error.PgConnectFailed;
        }
        var db: Db = .{
            .conn = conn,
            .allocator = allocator,
            .io = io,
            .query_timeout_ns = @as(u64, @intCast(@max(statement_timeout_seconds, 5))) * std.time.ns_per_s + query_timeout_slack_ns,
        };

        const timeout_sql = std.fmt.allocPrintSentinel(allocator, "SET statement_timeout = {d}", .{statement_timeout_seconds * std.time.ms_per_s}, 0) catch {
            // Allocation failure setting a safety timeout shouldn't fail the
            // whole connection — the connection itself is already good.
            return db;
        };
        defer allocator.free(timeout_sql);
        db.exec(timeout_sql) catch |err| {
            std.log.warn("pg: failed to set statement_timeout: {t}", .{err});
            // If setting the timeout is itself what blew the deadline,
            // `conn` is now poisoned before it was ever handed to a caller
            // — fail the open outright rather than returning a `Db` that
            // looks fine but can never safely be queried.
            if (db.poisoned) return error.PgConnectFailed;
        };
        return db;
    }

    /// `libpq` accepts `connect_timeout` (seconds) and `keepalives_*` as DSN
    /// keywords; a keyword/value DSN can just have them appended as more
    /// space-separated pairs, and a URI-style DSN (`postgresql://...`)
    /// accepts them as query parameters — both forms are handled by the
    /// same `key=value` append since libpq's URI parser treats trailing
    /// query parameters as connection options identically to the
    /// keyword/value form. `connect_timeout=10` is generous for even a slow
    /// LAN/VPN hop while still bounding what used to be an unbounded TCP
    /// connect. `keepalives_idle=20`/`keepalives_interval=10`/
    /// `keepalives_count=3` has the OS start probing an idle connection
    /// after 20s of silence and give up (erroring out any blocked
    /// send/recv) after 3 more unanswered probes 10s apart — ~50s to detect
    /// a peer that's gone dark, instead of relying on OS defaults that can
    /// take hours (see `open`'s doc comment for why this matters here
    /// specifically).
    fn appendConnectionOptions(allocator: std.mem.Allocator, dsn: [:0]const u8) ![:0]u8 {
        const is_uri = std.mem.startsWith(u8, dsn, "postgresql://") or std.mem.startsWith(u8, dsn, "postgres://");
        const first_sep: u8 = if (is_uri) (if (std.mem.indexOfScalar(u8, dsn, '?') != null) '&' else '?') else ' ';
        const join: u8 = if (is_uri) '&' else ' ';
        return std.fmt.allocPrintSentinel(
            allocator,
            "{s}{c}connect_timeout=10{c}keepalives=1{c}keepalives_idle=20{c}keepalives_interval=10{c}keepalives_count=3",
            .{ dsn, first_sep, join, join, join, join },
            0,
        );
    }

    pub fn close(self: *Db) void {
        c.PQfinish(self.conn);
    }

    /// Runs a statement with no bound parameters and no result rows (DDL,
    /// multi-statement migration bodies, etc). For anything with bound
    /// parameters, use `prepare`.
    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        try runWithDeadline(void, self, execBlocking, .{ self.conn, sql });
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) !Stmt {
        return .{
            .db = self,
            .sql = sql,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
    }
};

fn execBlocking(conn: *c.PGconn, sql: [:0]const u8) !void {
    const res = c.PQexec(conn, sql.ptr);
    defer c.PQclear(res);
    const status = c.PQresultStatus(res);
    if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
        std.log.err("pg exec failed ({s}): {s}", .{ sql, std.mem.span(c.PQerrorMessage(conn)) });
        return error.PgExecFailed;
    }
}

fn execParamsBlocking(conn: *c.PGconn, sql: [:0]const u8, count: usize, ptrs: [max_params]?[*:0]const u8) !*c.PGresult {
    var mutable_ptrs = ptrs;
    const res = c.PQexecParams(conn, sql.ptr, @intCast(count), null, @ptrCast(&mutable_ptrs), null, null, 0) orelse return error.PgExecFailed;
    const status = c.PQresultStatus(res);
    if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
        std.log.err("pg exec failed ({s}): {s}", .{ sql, std.mem.span(c.PQerrorMessage(conn)) });
        c.PQclear(res);
        return error.PgExecFailed;
    }
    return res;
}

/// Runs `func(args)` on a real `std.Thread` with a hard wall-clock deadline
/// of `db.query_timeout_ns`, mirroring `http_util.zig`'s `fetchWithTimeout`
/// — see that module's doc comment for why detaching-and-abandoning beats
/// `Io.concurrent`+`Future.cancel` for a plain blocking C call with no
/// `Io`-native cancellation point. `PQexecParams`/`PQexec` are exactly that:
/// once a query is in flight there is no way to interrupt the underlying
/// `send`/`recv` from here. On timeout the thread is detached (never
/// joined, never touches `conn` from this side again) and `db.poisoned` is
/// set so `PgPool.release` retires the connection instead of handing it
/// back out — see `Db.poisoned`'s doc comment for why reuse isn't safe.
fn runWithDeadline(comptime T: type, db: *Db, comptime func: anytype, args: anytype) !T {
    const Outcome = struct {
        done: std.atomic.Value(bool) = .init(false),
        result: anyerror!T = undefined,
    };
    const Runner = struct {
        fn run(a: @TypeOf(args), outcome: *Outcome) void {
            outcome.result = @call(.auto, func, a);
            outcome.done.store(true, .release);
        }
    };

    const outcome = try db.allocator.create(Outcome);
    errdefer db.allocator.destroy(outcome);
    outcome.* = .{};
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ args, outcome });

    var waited_ns: u64 = 0;
    while (!outcome.done.load(.acquire) and waited_ns < db.query_timeout_ns) {
        const step = @min(poll_interval_ns, db.query_timeout_ns - waited_ns);
        Io.sleep(db.io, .fromNanoseconds(@intCast(step)), .awake) catch break;
        waited_ns += step;
    }

    if (outcome.done.load(.acquire)) {
        thread.join();
        defer db.allocator.destroy(outcome);
        return outcome.result;
    }

    // Deliberately not joined, closed, or reused from here on — see this
    // function's doc comment and `Db.poisoned`.
    thread.detach();
    db.poisoned = true;
    return error.QueryTimedOut;
}

pub const Stmt = struct {
    db: *Db,
    sql: [:0]const u8,
    arena: std.heap.ArenaAllocator,
    values: [max_params]?[:0]const u8 = @splat(null),
    count: usize = 0,
    result: ?*c.PGresult = null,
    row_idx: c_int = -1,
    ntuples: c_int = 0,

    pub fn bindInt64(self: *Stmt, idx: c_int, value: i64) void {
        const i: usize = @intCast(idx - 1);
        self.values[i] = std.fmt.allocPrintSentinel(self.arena.allocator(), "{d}", .{value}, 0) catch unreachable;
        self.count = @max(self.count, i + 1);
    }

    pub fn bindText(self: *Stmt, idx: c_int, value: []const u8) void {
        const i: usize = @intCast(idx - 1);
        self.values[i] = self.arena.allocator().dupeZ(u8, value) catch unreachable;
        self.count = @max(self.count, i + 1);
    }

    pub fn bindNull(self: *Stmt, idx: c_int) void {
        const i: usize = @intCast(idx - 1);
        self.values[i] = null;
        self.count = @max(self.count, i + 1);
    }

    pub fn bindBool(self: *Stmt, idx: c_int, value: bool) void {
        self.bindText(idx, if (value) "true" else "false");
    }

    pub fn bindFloat64(self: *Stmt, idx: c_int, value: f64) void {
        const i: usize = @intCast(idx - 1);
        self.values[i] = std.fmt.allocPrintSentinel(self.arena.allocator(), "{d}", .{value}, 0) catch unreachable;
        self.count = @max(self.count, i + 1);
    }

    /// Runs the query against whatever's been bound so far — called lazily
    /// on the first `step()`, since libpq (unlike SQLite) executes all at
    /// once rather than being fed parameters incrementally.
    fn ensureExecuted(self: *Stmt) !void {
        if (self.result != null) return;

        var ptrs: [max_params]?[*:0]const u8 = @splat(null);
        for (0..self.count) |i| {
            ptrs[i] = if (self.values[i]) |v| v.ptr else null;
        }

        const res = try runWithDeadline(*c.PGresult, self.db, execParamsBlocking, .{ self.db.conn, self.sql, self.count, ptrs });
        self.result = res;
        self.ntuples = c.PQntuples(res);
        self.row_idx = -1;
    }

    /// Returns true if a row is available, false when done. Mirrors
    /// SQLite's step-per-row model even though libpq hands back the whole
    /// result set at once — callers loop `while (try stmt.step())` either way.
    pub fn step(self: *Stmt) !bool {
        try self.ensureExecuted();
        self.row_idx += 1;
        return self.row_idx < self.ntuples;
    }

    pub fn columnInt64(self: Stmt, idx: c_int) i64 {
        return std.fmt.parseInt(i64, self.columnText(idx), 10) catch 0;
    }

    /// Empty slice for both SQL NULL and zero-length text columns — matches
    /// the old SQLite wrapper's behavior so callers didn't need to change.
    /// Use `columnIsNull` where NULL must be told apart from `""`.
    pub fn columnText(self: Stmt, idx: c_int) []const u8 {
        if (self.result == null or c.PQgetisnull(self.result.?, self.row_idx, idx) != 0) return "";
        return std.mem.span(c.PQgetvalue(self.result.?, self.row_idx, idx));
    }

    pub fn columnIsNull(self: Stmt, idx: c_int) bool {
        return self.result == null or c.PQgetisnull(self.result.?, self.row_idx, idx) != 0;
    }

    pub fn columnFloat64(self: Stmt, idx: c_int) f64 {
        return std.fmt.parseFloat(f64, self.columnText(idx)) catch 0;
    }

    /// Postgres's text-format boolean output is a single 't'/'f' char.
    pub fn columnBool(self: Stmt, idx: c_int) bool {
        const txt = self.columnText(idx);
        return txt.len > 0 and txt[0] == 't';
    }

    pub fn finalize(self: *Stmt) void {
        if (self.result) |r| c.PQclear(r);
        self.arena.deinit();
    }
};

const testing = std.testing;

test "appendConnectionOptions appends timeout and keepalive query params to a URI-style DSN" {
    const out = try Db.appendConnectionOptions(testing.allocator, "postgresql://warden:pw@postgres/warden");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "postgresql://warden:pw@postgres/warden?connect_timeout=10&keepalives=1&keepalives_idle=20&keepalives_interval=10&keepalives_count=3",
        out,
    );
}

test "appendConnectionOptions uses '&' throughout when the URI-style DSN already has query params" {
    const out = try Db.appendConnectionOptions(testing.allocator, "postgresql://postgres/warden?sslmode=disable");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "postgresql://postgres/warden?sslmode=disable&connect_timeout=10&keepalives=1&keepalives_idle=20&keepalives_interval=10&keepalives_count=3",
        out,
    );
}

test "appendConnectionOptions uses space-separated keywords for a non-URI DSN" {
    const out = try Db.appendConnectionOptions(testing.allocator, "host=postgres dbname=warden");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "host=postgres dbname=warden connect_timeout=10 keepalives=1 keepalives_idle=20 keepalives_interval=10 keepalives_count=3",
        out,
    );
}
