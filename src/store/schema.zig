const Db = @import("db.zig").Db;

/// Applied on every open; all statements are idempotent so this doubles as
/// the migration mechanism for now (no separate migration files/versioning
/// yet — fine at this schema size).
pub fn migrate(db: *Db) !void {
    try db.exec("PRAGMA journal_mode=WAL;");
    try db.exec("PRAGMA foreign_keys=ON;");

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS messages (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  user_id TEXT NOT NULL,
        \\  username TEXT,
        \\  text TEXT,
        \\  ts INTEGER NOT NULL
        \\);
    );
    try db.exec("CREATE INDEX IF NOT EXISTS idx_messages_user_id ON messages(user_id);");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts);");

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\  user_id TEXT PRIMARY KEY,
        \\  username TEXT,
        \\  last_seen INTEGER,
        \\  tokens INTEGER
        \\);
    );

    try db.exec(
        \\CREATE TABLE IF NOT EXISTS chat_settings (
        \\  key TEXT PRIMARY KEY,
        \\  value TEXT
        \\);
    );
}
