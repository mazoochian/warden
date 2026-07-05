const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

/// SQLite's `SQLITE_TRANSIENT` is `((sqlite3_destructor_type)-1)`, a sentinel
/// pointer value rather than a real function — cImport can't translate that
/// cast reliably, so it's reconstructed by hand here (standard idiom for
/// Zig sqlite bindings).
const sqlite_transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path.ptr,
            &handle,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );
        if (rc != c.SQLITE_OK or handle == null) {
            if (handle) |h| _ = c.sqlite3_close(h);
            std.log.err("sqlite3_open_v2({s}) failed: rc={d}", .{ path, rc });
            return error.SqliteOpenFailed;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Runs a statement with no parameters and no result rows (DDL, PRAGMA,
    /// simple inserts). For anything with bound parameters, use `prepare`.
    pub fn exec(self: *Db, sql: [:0]const u8) !void {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            std.log.err("sqlite exec failed ({s}): {s}", .{ sql, errmsg });
            c.sqlite3_free(errmsg);
            return error.SqliteExecFailed;
        }
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK or stmt == null) {
            std.log.err("sqlite prepare failed ({s}): {s}", .{ sql, c.sqlite3_errmsg(self.handle) });
            return error.SqlitePrepareFailed;
        }
        return .{ .handle = stmt.? };
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn bindInt64(self: Stmt, idx: c_int, value: i64) void {
        _ = c.sqlite3_bind_int64(self.handle, idx, value);
    }

    pub fn bindText(self: Stmt, idx: c_int, value: []const u8) void {
        _ = c.sqlite3_bind_text(self.handle, idx, value.ptr, @intCast(value.len), sqlite_transient);
    }

    pub fn bindNull(self: Stmt, idx: c_int) void {
        _ = c.sqlite3_bind_null(self.handle, idx);
    }

    /// Returns true if a row is available (SQLITE_ROW), false when done.
    pub fn step(self: Stmt) !bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |rc| {
                std.log.err("sqlite step failed: rc={d}", .{rc});
                return error.SqliteStepFailed;
            },
        };
    }

    pub fn columnInt64(self: Stmt, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }

    /// Empty slice for both NULL and zero-length text columns.
    pub fn columnText(self: Stmt, idx: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        const len = c.sqlite3_column_bytes(self.handle, idx);
        if (ptr == null or len <= 0) return "";
        return @as([*]const u8, @ptrCast(ptr))[0..@intCast(len)];
    }

    pub fn finalize(self: Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }
};
