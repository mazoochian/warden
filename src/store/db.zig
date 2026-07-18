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

    pub fn open(allocator: std.mem.Allocator, dsn: [:0]const u8) !Db {
        const conn = c.PQconnectdb(dsn.ptr) orelse return error.PgConnectFailed;
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            std.log.err("PQconnectdb failed: {s}", .{std.mem.span(c.PQerrorMessage(conn))});
            c.PQfinish(conn);
            return error.PgConnectFailed;
        }
        return .{ .conn = conn, .allocator = allocator };
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
