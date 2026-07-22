const std = @import("std");

pub const c = @cImport({
    @cInclude("libpq-fe.h");
});

/// Max bound parameters any single query in this codebase uses. libpq has
/// no incremental bind API like SQLite's `sqlite3_bind_*` — every parameter
/// has to be handed to `PQexecParams` at once — so `Stmt` buffers bound
/// values by index until `step()` first runs the query.
const max_params = 16;

pub const Db = struct {
    conn: *c.PGconn,
    /// Used to own per-`Stmt` scratch allocations (bound param text) — each
    /// `Stmt` gets its own arena off this, freed on `finalize()`.
    allocator: std.mem.Allocator,

    /// `statement_timeout_seconds` bounds every query run on this connection
    /// server-side (via a session `SET` right after connecting) — without
    /// it, a single wedged query (lock contention, a network stall between
    /// warden and Postgres) blocks the calling thread forever with no
    /// recourse: these are plain blocking `libpq` C calls, entirely outside
    /// `Io`, so there's no cancellation or timeout wrapper possible from the
    /// caller's side the way `http_util.zig` manages for HTTP. Confirmed
    /// live (2026-07-22) as the likely cause of a production hang where a
    /// message-handling task never returned, never logged an error, and
    /// permanently froze its platform's poll loop (see `PgPool`'s doc
    /// comment for the full chain). A `connect_timeout` is applied the same
    /// way, so even the initial TCP handshake can't hang indefinitely
    /// either.
    pub fn open(allocator: std.mem.Allocator, dsn: [:0]const u8, statement_timeout_seconds: i64) !Db {
        const dsn_with_timeout = try appendConnectTimeout(allocator, dsn);
        defer allocator.free(dsn_with_timeout);

        const conn = c.PQconnectdb(dsn_with_timeout.ptr) orelse return error.PgConnectFailed;
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            std.log.err("PQconnectdb failed: {s}", .{std.mem.span(c.PQerrorMessage(conn))});
            c.PQfinish(conn);
            return error.PgConnectFailed;
        }
        var db: Db = .{ .conn = conn, .allocator = allocator };

        const timeout_sql = std.fmt.allocPrintSentinel(allocator, "SET statement_timeout = {d}", .{statement_timeout_seconds * std.time.ms_per_s}, 0) catch {
            // Allocation failure setting a safety timeout shouldn't fail the
            // whole connection — the connection itself is already good.
            return db;
        };
        defer allocator.free(timeout_sql);
        db.exec(timeout_sql) catch |err| {
            std.log.warn("pg: failed to set statement_timeout: {t}", .{err});
        };
        return db;
    }

    /// `libpq` accepts `connect_timeout` (seconds) as a DSN keyword; a
    /// keyword/value DSN can just have it appended as another
    /// space-separated pair, and a URI-style DSN (`postgresql://...`)
    /// accepts it as a query parameter — both forms are handled by the
    /// same `key=value` append since libpq's URI parser treats trailing
    /// query parameters as connection options identically to the
    /// keyword/value form. 10s is generous for even a slow LAN/VPN hop
    /// while still bounding what used to be an unbounded TCP connect.
    fn appendConnectTimeout(allocator: std.mem.Allocator, dsn: [:0]const u8) ![:0]u8 {
        const is_uri = std.mem.startsWith(u8, dsn, "postgresql://") or std.mem.startsWith(u8, dsn, "postgres://");
        const sep: u8 = if (is_uri) (if (std.mem.indexOfScalar(u8, dsn, '?') != null) '&' else '?') else ' ';
        return std.fmt.allocPrintSentinel(allocator, "{s}{c}connect_timeout=10", .{ dsn, sep }, 0);
    }

    pub fn close(self: *Db) void {
        c.PQfinish(self.conn);
    }

    /// Runs a statement with no bound parameters and no result rows (DDL,
    /// multi-statement migration bodies, etc). For anything with bound
    /// parameters, use `prepare`.
    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        const res = c.PQexec(self.conn, sql.ptr);
        defer c.PQclear(res);
        const status = c.PQresultStatus(res);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            std.log.err("pg exec failed ({s}): {s}", .{ sql, std.mem.span(c.PQerrorMessage(self.conn)) });
            return error.PgExecFailed;
        }
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) !Stmt {
        return .{
            .conn = self.conn,
            .sql = sql,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
    }
};

pub const Stmt = struct {
    conn: *c.PGconn,
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

        var ptrs: [max_params]?[*:0]const u8 = undefined;
        for (0..self.count) |i| {
            ptrs[i] = if (self.values[i]) |v| v.ptr else null;
        }

        const res = c.PQexecParams(
            self.conn,
            self.sql.ptr,
            @intCast(self.count),
            null,
            @ptrCast(&ptrs),
            null,
            null,
            0,
        );
        const status = c.PQresultStatus(res);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            std.log.err("pg exec failed ({s}): {s}", .{ self.sql, std.mem.span(c.PQerrorMessage(self.conn)) });
            c.PQclear(res);
            return error.PgExecFailed;
        }
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

test "appendConnectTimeout appends a query param to a URI-style DSN" {
    const out = try Db.appendConnectTimeout(testing.allocator, "postgresql://warden:pw@postgres/warden");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("postgresql://warden:pw@postgres/warden?connect_timeout=10", out);
}

test "appendConnectTimeout uses '&' when the URI-style DSN already has query params" {
    const out = try Db.appendConnectTimeout(testing.allocator, "postgresql://postgres/warden?sslmode=disable");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("postgresql://postgres/warden?sslmode=disable&connect_timeout=10", out);
}

test "appendConnectTimeout uses a space-separated keyword for a non-URI DSN" {
    const out = try Db.appendConnectTimeout(testing.allocator, "host=postgres dbname=warden");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("host=postgres dbname=warden connect_timeout=10", out);
}
