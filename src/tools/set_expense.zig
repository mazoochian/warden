const std = @import("std");
const json = std.json;

const registry = @import("registry.zig");

const max_description_len = 500;

const Args = struct {
    action: []const u8,
    /// Dollars (or whatever the chat's currency actually is), not cents --
    /// converted to integer cents by `execute` below before ever reaching
    /// the sink. Only for action=create.
    amount: ?f64 = null,
    category: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Only for action=delete.
    id: ?i64 = null,
};

/// ROADMAP.md's Phase 17 (finance trackers): lets the model log an
/// expense from a plain statement ("I spent $12 on lunch") or a receipt
/// photo it can already read via Phase 10's vision support -- no separate
/// receipt-OCR plumbing needed, the model just extracts the amount/
/// category itself and calls this tool the same way it would from typed
/// text.
pub const tool: registry.ToolDef = .{
    .name = "set_expense",
    .description = "Logs, lists, or deletes manual expense entries for this chat's finance tracker. Use action=create when the user mentions spending money (including describing a receipt/photo you can see) -- amount is a plain number in the chat's currency (e.g. 12.50), not cents. Use action=list to show recent expenses, action=delete with an id from a previous list to remove one.",
    .input_schema_json =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["create","list","delete"],"description":"What to do"},"amount":{"type":"number","description":"Only for action=create. The amount spent, e.g. 12.50 (not cents)"},"category":{"type":"string","description":"Only for action=create. A short category label, e.g. food, transport"},"description":{"type":"string","description":"Only for action=create. Optional short note about what this was"},"id":{"type":"integer","description":"Only for action=delete. The expense id to delete"}},"required":["action"]}
    ,
    .execute = execute,
};

/// Rounds a dollar amount to the nearest cent -- see
/// `registry.ExpenseSink`'s doc comment on why every store-layer boundary
/// past this point only ever deals in integer cents, never a float.
fn centsFromAmount(amount: f64) ?i64 {
    if (!std.math.isFinite(amount)) return null;
    const cents: i64 = @intFromFloat(@round(amount * 100.0));
    if (cents <= 0) return null;
    return cents;
}

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    const sink = ctx.expenses orelse return error.MissingToolContext;

    var parsed = try json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.eql(u8, args.action, "list")) {
        return sink.listAll(ctx.allocator);
    }

    if (std.mem.eql(u8, args.action, "delete")) {
        const id = args.id orelse return "Missing id — use action=list to find the expense's id first.";
        return switch (try sink.delete(ctx.allocator, id)) {
            .deleted => "Expense deleted.",
            .not_found => "No expense with that id in this chat.",
            .not_authorized => "Only whoever logged that expense (or the bot owner) can delete it.",
        };
    }

    if (!std.mem.eql(u8, args.action, "create")) {
        return "Unknown action — use \"create\", \"list\", or \"delete\".";
    }

    const amount = args.amount orelse return "Missing amount — say how much was spent.";
    const cents = centsFromAmount(amount) orelse return "That amount doesn't look valid — it must be a positive number.";
    const category = args.category orelse return "Missing category — say what kind of expense this was (e.g. food, transport).";
    if (category.len == 0) return "Missing category — say what kind of expense this was (e.g. food, transport).";
    const description = if (args.description) |d| (if (d.len > 0) d else null) else null;
    if (description) |d| {
        if (d.len > max_description_len) return "That description is too long (max 500 bytes).";
    }

    const id = try sink.create(ctx.allocator, cents, category, description);
    return std.fmt.allocPrint(ctx.allocator, "Expense #{d} logged.", .{id});
}

test "tool schema is valid JSON" {
    var parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tool.input_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "centsFromAmount rounds to the nearest cent and rejects non-positive/non-finite amounts" {
    try std.testing.expectEqual(@as(?i64, 1250), centsFromAmount(12.50));
    try std.testing.expectEqual(@as(?i64, 1250), centsFromAmount(12.501)); // rounds down
    try std.testing.expectEqual(@as(?i64, 1251), centsFromAmount(12.505)); // rounds up
    try std.testing.expectEqual(@as(?i64, null), centsFromAmount(0));
    try std.testing.expectEqual(@as(?i64, null), centsFromAmount(-5));
    try std.testing.expectEqual(@as(?i64, null), centsFromAmount(std.math.inf(f64)));
    try std.testing.expectEqual(@as(?i64, null), centsFromAmount(std.math.nan(f64)));
}

const testing = std.testing;

const FakeSink = struct {
    created_cents: ?i64 = null,
    created_category: ?[]const u8 = null,
    delete_result: registry.ExpenseSink.DeleteResult = .deleted,
    list_text: []const u8 = "Recent expenses:\n  #1 12.50 USD (food)\n",

    fn sink(self: *FakeSink) registry.ExpenseSink {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt: registry.ExpenseSink.VTable = .{ .create = createFn, .delete = deleteFn, .listAll = listAllFn };

    fn createFn(ptr: *anyopaque, allocator: std.mem.Allocator, amount_cents: i64, category: []const u8, description: ?[]const u8) anyerror!i64 {
        _ = description;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        self.created_cents = amount_cents;
        self.created_category = try allocator.dupe(u8, category);
        return 7;
    }
    fn deleteFn(ptr: *anyopaque, allocator: std.mem.Allocator, id: i64) anyerror!registry.ExpenseSink.DeleteResult {
        _ = allocator;
        _ = id;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        return self.delete_result;
    }
    fn listAllFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        _ = allocator;
        const self: *FakeSink = @ptrCast(@alignCast(ptr));
        return self.list_text;
    }
};

test "execute create converts dollars to cents and forwards the category" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .expenses = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"create\",\"amount\":12.5,\"category\":\"food\"}");
    try testing.expectEqualStrings("Expense #7 logged.", out);
    try testing.expectEqual(@as(?i64, 1250), fake.created_cents);
    try testing.expectEqualStrings("food", fake.created_category.?);
}

test "execute create rejects a missing or non-positive amount without touching the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .expenses = fake.sink() };

    const missing = try execute(ctx, "{\"action\":\"create\",\"category\":\"food\"}");
    try testing.expect(std.mem.indexOf(u8, missing, "Missing amount") != null);

    const zero = try execute(ctx, "{\"action\":\"create\",\"amount\":0,\"category\":\"food\"}");
    try testing.expect(std.mem.indexOf(u8, zero, "doesn't look valid") != null);
    try testing.expectEqual(@as(?i64, null), fake.created_cents);
}

test "execute list forwards straight to the sink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fake = FakeSink{};
    const ctx = registry.ToolContext{ .allocator = a, .io = testing.io, .expenses = fake.sink() };

    const out = try execute(ctx, "{\"action\":\"list\"}");
    try testing.expectEqualStrings(fake.list_text, out);
}
