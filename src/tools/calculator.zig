const std = @import("std");
const registry = @import("registry.zig");

const Args = struct { expression: []const u8 };

pub const tool: registry.ToolDef = .{
    .name = "calculator",
    .description = "Evaluates a basic arithmetic expression (+ - * / and parentheses, decimals, negatives). Use this for any math instead of computing it yourself.",
    .input_schema_json =
        \\{"type":"object","properties":{"expression":{"type":"string","description":"An arithmetic expression, e.g. \"(2 + 3) * 4\""}},"required":["expression"]}
    ,
    .execute = execute,
};

fn execute(ctx: registry.ToolContext, input_json: []const u8) anyerror![]const u8 {
    var parsed = try std.json.parseFromSlice(
        Args,
        ctx.allocator,
        input_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const result = try eval(ctx.allocator, parsed.value.expression);
    return std.fmt.allocPrint(ctx.allocator, "{d}", .{result});
}

const EvalError = error{
    UnexpectedEnd,
    ExpectedNumber,
    ExpectedCloseParen,
    TrailingGarbage,
    DivisionByZero,
    InvalidCharacter,
    Overflow,
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn skipWs(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t') p.i += 1 else break;
        }
    }

    fn parseExpr(p: *Parser) EvalError!f64 {
        var value = try p.parseTerm();
        while (true) {
            p.skipWs();
            const c = p.peek() orelse break;
            if (c == '+') {
                p.i += 1;
                value += try p.parseTerm();
            } else if (c == '-') {
                p.i += 1;
                value -= try p.parseTerm();
            } else break;
        }
        return value;
    }

    fn parseTerm(p: *Parser) EvalError!f64 {
        var value = try p.parseFactor();
        while (true) {
            p.skipWs();
            const c = p.peek() orelse break;
            if (c == '*') {
                p.i += 1;
                value *= try p.parseFactor();
            } else if (c == '/') {
                p.i += 1;
                const d = try p.parseFactor();
                if (d == 0) return error.DivisionByZero;
                value /= d;
            } else break;
        }
        return value;
    }

    fn parseFactor(p: *Parser) EvalError!f64 {
        p.skipWs();
        const c = p.peek() orelse return error.UnexpectedEnd;
        if (c == '(') {
            p.i += 1;
            const v = try p.parseExpr();
            p.skipWs();
            if (p.peek() != ')') return error.ExpectedCloseParen;
            p.i += 1;
            return v;
        }
        if (c == '-') {
            p.i += 1;
            return -(try p.parseFactor());
        }
        if (c == '+') {
            p.i += 1;
            return try p.parseFactor();
        }
        return p.parseNumber();
    }

    fn parseNumber(p: *Parser) EvalError!f64 {
        const start = p.i;
        while (p.peek()) |c| {
            if ((c >= '0' and c <= '9') or c == '.') p.i += 1 else break;
        }
        if (p.i == start) return error.ExpectedNumber;
        return std.fmt.parseFloat(f64, p.s[start..p.i]) catch error.ExpectedNumber;
    }
};

fn eval(allocator: std.mem.Allocator, expression: []const u8) EvalError!f64 {
    _ = allocator;
    var p = Parser{ .s = expression };
    const v = try p.parseExpr();
    p.skipWs();
    if (p.i != p.s.len) return error.TrailingGarbage;
    return v;
}

const testing = std.testing;

test "eval handles precedence, parens, negatives" {
    try testing.expectApproxEqAbs(@as(f64, 14), try eval(testing.allocator, "2 + 3 * 4"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), try eval(testing.allocator, "(2 + 3) * 4"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1), try eval(testing.allocator, "-1"), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.5), try eval(testing.allocator, "5 / 2"), 1e-9);
}

test "eval rejects division by zero and garbage" {
    try testing.expectError(error.DivisionByZero, eval(testing.allocator, "1/0"));
    try testing.expectError(error.TrailingGarbage, eval(testing.allocator, "1 2"));
    try testing.expectError(error.ExpectedCloseParen, eval(testing.allocator, "(1 + 2"));
}

test "calculator tool executes end to end via its JSON args" {
    const result = try execute(.{ .allocator = testing.allocator, .io = testing.io }, "{\"expression\":\"(2+3)*4\"}");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("20", result);
}
