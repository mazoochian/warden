//! Minimal read-only SQLite wrapper for the one-time data migration tool
//! (`zig build migrate-data`) — recreated from the pre-Postgres
//! `store/db.zig`/`store/schema.zig`, which are gone from the main `warden`
//! binary now that it talks to Postgres exclusively. This file (and the
//! vendored `third_party/sqlite` source it's compiled against — see
//! `build.zig`'s `migrate-data` step) exists purely so this tool can open
//! the old per-chat `.db` files one last time; nothing else in the
//! codebase depends on SQLite anymore.

const std = @import("std");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READONLY, null);
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

    pub fn columnIsNull(self: Stmt, idx: c_int) bool {
        return c.sqlite3_column_type(self.handle, idx) == c.SQLITE_NULL;
    }

    /// Empty slice for both NULL and zero-length text columns (matches the
    /// old app's convention).
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
