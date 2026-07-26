//! A hand-rolled regex engine for `/redact regex`, deliberately built as a
//! Thompson-construction NFA simulated via Pike's VM — never backtracking —
//! so it's immune to catastrophic backtracking (ReDoS) *by construction*,
//! not by blacklisting dangerous-looking patterns. Matching a compiled
//! pattern against N bytes of text always costs O(states × N), regardless
//! of how the pattern is shaped: classic backtracking-engine worst cases
//! like `(a+)+$` against a long non-matching run compile to a handful of
//! states here and match/reject in linear time (see this file's own
//! non-hang regression test).
//!
//! Three defenses, all enforced at `compile()` time, not just documented:
//!   - `max_pattern_len`: the raw pattern string itself can't be absurdly
//!     long.
//!   - `max_repetition_bound`: a single `{n,m}` can't specify an absurd
//!     bound.
//!   - `max_nfa_states`: the *compiled* state count is checked as states
//!     are allocated, which is what actually catches compounding blow-ups
//!     (e.g. nested repetition) that no single `{n,m}` bound-check alone
//!     would — `compile()` fails with `error.TooManyStates` the instant the
//!     ceiling would be crossed, mid-compilation.
//!
//! Deliberate v1 scope, not full PCRE: literals, `.`, `[abc]`/`[^abc]`/
//! ranges, `*`/`+`/`?`/`{n,m}`/`{n,}`, alternation `|`, non-capturing
//! `(...)` grouping (precedence only — no backreferences, which are
//! exactly what forces real regex engines into backtracking), anchors
//! `^`/`$`. No capture groups (nothing here needs submatches, only a yes/
//! no `isMatch`). Matching is byte-wise (raw UTF-8 bytes), not Unicode-
//! codepoint-wise — `.` and classes operate on single bytes, and there's no
//! `\d`/`\w`/`\s` shorthand. Acceptable for a moderation tool where
//! patterns are overwhelmingly ASCII; both are addable later without
//! touching the matching core. `isMatch` is an unanchored *search* (matches
//! anywhere in the text) unless the pattern itself uses `^`/`$` — same
//! default as grep/most regex engines, appropriate for "does this message
//! contain a match" rather than "does this message consist entirely of a
//! match".

const std = @import("std");

pub const CompileError = error{
    PatternTooLong,
    TooManyStates,
    UnboundedRepetition,
    UnsupportedSyntax,
    UnbalancedGroup,
    UnbalancedClass,
    OutOfMemory,
};

pub const max_pattern_len: usize = 200;
pub const max_nfa_states: usize = 10_000;
pub const max_repetition_bound: usize = 1000;

const Range = struct { lo: u8, hi: u8 };

const ClassSpec = struct {
    ranges: []const Range,
    negate: bool,
};

/// Parse-time tree, allocated in a short-lived arena — see `compile`'s doc
/// comment on why `Compiler` copies anything from here that needs to
/// outlive it (the arena is freed before `compile` returns).
const Ast = union(enum) {
    literal: u8,
    any_byte,
    class: ClassSpec,
    assert_start,
    assert_end,
    concat: []const Ast,
    alt: []const Ast,
    star: *const Ast,
    plus: *const Ast,
    opt: *const Ast,
    repeat: struct { node: *const Ast, min: usize, max: ?usize }, // max == null: unbounded ("{n,}")
};

const Parser = struct {
    pattern: []const u8,
    pos: usize,
    allocator: std.mem.Allocator, // arena — see `Ast`'s doc comment

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.pattern.len) self.pattern[self.pos] else null;
    }

    fn advance(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        return c;
    }

    fn eat(self: *Parser, c: u8) bool {
        if (self.peek() == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn dupe(self: *Parser, value: Ast) CompileError!*const Ast {
        const p = try self.allocator.create(Ast);
        p.* = value;
        return p;
    }

    fn parseAlt(self: *Parser) CompileError!*const Ast {
        const first = try self.parseConcat();
        if (self.peek() != '|') return first;

        var branches: std.ArrayList(Ast) = .empty;
        try branches.append(self.allocator, first.*);
        while (self.eat('|')) {
            const branch = try self.parseConcat();
            try branches.append(self.allocator, branch.*);
        }
        return self.dupe(.{ .alt = try branches.toOwnedSlice(self.allocator) });
    }

    fn parseConcat(self: *Parser) CompileError!*const Ast {
        var nodes: std.ArrayList(Ast) = .empty;
        while (true) {
            const c = self.peek() orelse break;
            if (c == '|' or c == ')') break;
            const node = try self.parseRepeat();
            try nodes.append(self.allocator, node.*);
        }
        if (nodes.items.len == 0) return self.dupe(.{ .concat = &.{} });
        if (nodes.items.len == 1) return self.dupe(nodes.items[0]);
        return self.dupe(.{ .concat = try nodes.toOwnedSlice(self.allocator) });
    }

    fn parseRepeat(self: *Parser) CompileError!*const Ast {
        const atom = try self.parseAtom();
        const c = self.peek() orelse return atom;
        switch (c) {
            '*' => {
                self.pos += 1;
                return self.dupe(.{ .star = atom });
            },
            '+' => {
                self.pos += 1;
                return self.dupe(.{ .plus = atom });
            },
            '?' => {
                self.pos += 1;
                return self.dupe(.{ .opt = atom });
            },
            '{' => return self.parseBoundedRepeat(atom),
            else => return atom,
        }
    }

    fn parseNumber(self: *Parser) ?usize {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(usize, self.pattern[start..self.pos], 10) catch null;
    }

    /// Always treats `{` as the start of a bounded-repeat expression rather
    /// than trying to guess whether malformed content means a literal `{`
    /// was intended — rejecting ambiguous input outright is the safer
    /// default for a security-focused engine.
    fn parseBoundedRepeat(self: *Parser, atom: *const Ast) CompileError!*const Ast {
        self.pos += 1; // consume '{'
        const min = self.parseNumber() orelse return error.UnsupportedSyntax;
        var max: ?usize = min;
        if (self.eat(',')) {
            max = self.parseNumber(); // null: unbounded "{min,}"
        }
        if (!self.eat('}')) return error.UnsupportedSyntax;

        if (min > max_repetition_bound) return error.UnboundedRepetition;
        if (max) |m| {
            if (m > max_repetition_bound) return error.UnboundedRepetition;
            if (m < min) return error.UnsupportedSyntax;
        }
        return self.dupe(.{ .repeat = .{ .node = atom, .min = min, .max = max } });
    }

    fn parseAtom(self: *Parser) CompileError!*const Ast {
        const c = self.advance() orelse return error.UnsupportedSyntax;
        return switch (c) {
            '.' => self.dupe(.any_byte),
            '^' => self.dupe(.assert_start),
            '$' => self.dupe(.assert_end),
            '(' => blk: {
                const inner = try self.parseAlt();
                if (!self.eat(')')) return error.UnbalancedGroup;
                break :blk inner;
            },
            '[' => self.parseClass(),
            '*', '+', '?' => error.UnsupportedSyntax, // quantifier with nothing to quantify
            '\\' => blk: {
                // Escapes any char to its literal (`\.`, `\\`, `\(`, ...) —
                // no `\d`/`\w`/`\s` shorthand, see this file's module doc.
                const esc = self.advance() orelse return error.UnsupportedSyntax;
                break :blk self.dupe(.{ .literal = esc });
            },
            else => self.dupe(.{ .literal = c }),
        };
    }

    /// A leading `]` is always the closing bracket here (no POSIX "`]`
    /// right after `[`/`[^` is a literal member" special case) — an
    /// explicit `\]` is required to include a literal bracket, which is
    /// simpler and less surprising than that convention.
    fn parseClass(self: *Parser) CompileError!*const Ast {
        var negate = false;
        if (self.eat('^')) negate = true;

        var ranges: std.ArrayList(Range) = .empty;
        while (true) {
            const c = self.peek() orelse return error.UnbalancedClass;
            if (c == ']') {
                self.pos += 1;
                break;
            }
            self.pos += 1;
            var lo = c;
            if (c == '\\') lo = self.advance() orelse return error.UnbalancedClass;

            var hi = lo;
            if (self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                self.pos += 1; // consume '-'
                var hi_c = self.advance() orelse return error.UnbalancedClass;
                if (hi_c == '\\') hi_c = self.advance() orelse return error.UnbalancedClass;
                hi = hi_c;
            }
            if (hi < lo) return error.UnsupportedSyntax;
            try ranges.append(self.allocator, .{ .lo = lo, .hi = hi });
        }
        if (ranges.items.len == 0) return error.UnsupportedSyntax; // "[]"/"[^]"
        return self.dupe(.{ .class = .{ .ranges = try ranges.toOwnedSlice(self.allocator), .negate = negate } });
    }
};

const ClassState = struct { ranges: []const Range, negate: bool, out: usize };

/// One compiled NFA state. `out`/`out1`/`out2` are indices into
/// `Regex.states`. Built via Thompson construction with a continuation-
/// passing compiler (`Compiler.compileNode` takes the state to transition
/// to on success as an explicit `next` parameter) rather than the classic
/// "patch list of dangling pointers" formulation — equivalent NFA shape,
/// simpler to implement correctly in Zig.
const State = union(enum) {
    byte: struct { value: u8, out: usize },
    any_byte: struct { out: usize },
    class: ClassState,
    assert_start: struct { out: usize },
    assert_end: struct { out: usize },
    split: struct { out1: usize, out2: usize },
    match,
};

const Compiler = struct {
    allocator: std.mem.Allocator, // long-lived — see `Regex`'s doc comment
    states: std.ArrayList(State) = .empty,

    fn addState(self: *Compiler, state: State) CompileError!usize {
        if (self.states.items.len >= max_nfa_states) return error.TooManyStates;
        try self.states.append(self.allocator, state);
        return self.states.items.len - 1;
    }

    /// Reserves a slot to be filled in later — needed for `*`/`+`, whose
    /// loop-back split must exist (so its index is known) before the body
    /// it loops into is compiled.
    fn addPlaceholder(self: *Compiler) CompileError!usize {
        return self.addState(undefined);
    }

    fn compileStar(self: *Compiler, node: *const Ast, next: usize) CompileError!usize {
        const split_id = try self.addPlaceholder();
        const body_id = try self.compileNode(node, split_id);
        self.states.items[split_id] = .{ .split = .{ .out1 = body_id, .out2 = next } };
        return split_id;
    }

    /// Builds `count` nested optional copies of `node`, each one skippable
    /// straight through to `next` — backs the "up to `max - min` extra
    /// optional copies" half of a bounded `{min,max}` repeat.
    fn compileOptionalTail(self: *Compiler, node: *const Ast, count: usize, next: usize) CompileError!usize {
        if (count == 0) return next;
        const inner = try self.compileOptionalTail(node, count - 1, next);
        const body_id = try self.compileNode(node, inner);
        return self.addState(.{ .split = .{ .out1 = body_id, .out2 = inner } });
    }

    fn compileRepeat(self: *Compiler, node: *const Ast, min: usize, max: ?usize, next: usize) CompileError!usize {
        const tail = if (max) |m| try self.compileOptionalTail(node, m - min, next) else try self.compileStar(node, next);
        var id = tail;
        var i: usize = 0;
        while (i < min) : (i += 1) {
            id = try self.compileNode(node, id);
        }
        return id;
    }

    fn compileNode(self: *Compiler, node: *const Ast, next: usize) CompileError!usize {
        return switch (node.*) {
            .literal => |b| self.addState(.{ .byte = .{ .value = b, .out = next } }),
            .any_byte => self.addState(.{ .any_byte = .{ .out = next } }),
            // Ranges are copied into the long-lived allocator here — `c`
            // itself (and its `ranges` slice) lives in the parser's arena,
            // which is freed once `compile()` returns; the compiled `State`
            // must not keep pointing into it. `Regex.deinit` frees this
            // copy (see its own doc comment).
            .class => |c| self.addState(.{ .class = .{ .ranges = try self.allocator.dupe(Range, c.ranges), .negate = c.negate, .out = next } }),
            .assert_start => self.addState(.{ .assert_start = .{ .out = next } }),
            .assert_end => self.addState(.{ .assert_end = .{ .out = next } }),
            .concat => |children| blk: {
                var id = next;
                var i = children.len;
                while (i > 0) {
                    i -= 1;
                    id = try self.compileNode(&children[i], id);
                }
                break :blk id;
            },
            .alt => |children| blk: {
                std.debug.assert(children.len >= 2);
                var id = try self.compileNode(&children[children.len - 1], next);
                var i = children.len - 1;
                while (i > 0) {
                    i -= 1;
                    const left_id = try self.compileNode(&children[i], next);
                    id = try self.addState(.{ .split = .{ .out1 = left_id, .out2 = id } });
                }
                break :blk id;
            },
            .star => |child| self.compileStar(child, next),
            .plus => |child| blk: {
                // One mandatory pass through `child`, then optionally loop
                // — same split-based loop as `compileStar`, but the entry
                // point is the body (not the split), so it always runs at
                // least once.
                const split_id = try self.addPlaceholder();
                const body_id = try self.compileNode(child, split_id);
                self.states.items[split_id] = .{ .split = .{ .out1 = body_id, .out2 = next } };
                break :blk body_id;
            },
            .opt => |child| blk: {
                const body_id = try self.compileNode(child, next);
                break :blk try self.addState(.{ .split = .{ .out1 = body_id, .out2 = next } });
            },
            .repeat => |r| self.compileRepeat(r.node, r.min, r.max, next),
        };
    }
};

fn matchesClass(spec: ClassState, byte: u8) bool {
    var found = false;
    for (spec.ranges) |r| {
        if (byte >= r.lo and byte <= r.hi) {
            found = true;
            break;
        }
    }
    return found != spec.negate;
}

pub const Regex = struct {
    allocator: std.mem.Allocator,
    states: []const State,
    start: usize,
    /// Per-state "last-seen generation" — reused across `isMatch` calls
    /// (cleared implicitly by bumping `generation` rather than by zeroing
    /// the whole array each time) to dedupe the epsilon closure without
    /// which a `*`/`+`-induced cycle in the state graph would recurse
    /// forever.
    gen_marks: []usize,
    generation: usize = 0,
    /// Scratch state-id lists, reused (not reallocated) across `isMatch`
    /// calls — this engine is meant to run against many candidate messages
    /// per `/redact regex` invocation (see `store/messages.zig`'s
    /// `recentForScan`), so avoiding a fresh allocation per call matters.
    clist: std.ArrayList(usize) = .empty,
    nlist: std.ArrayList(usize) = .empty,

    pub fn deinit(self: *Regex) void {
        for (self.states) |s| {
            if (s == .class) self.allocator.free(s.class.ranges);
        }
        self.allocator.free(self.states);
        self.allocator.free(self.gen_marks);
        self.clist.deinit(self.allocator);
        self.nlist.deinit(self.allocator);
    }

    /// Unanchored substring search (matches anywhere in `text`) unless the
    /// pattern itself anchors with `^`/`$` — see this file's module doc.
    /// Pointer receiver: matching mutates the reused scratch buffers above.
    pub fn isMatch(self: *Regex, text: []const u8) bool {
        self.clist.clearRetainingCapacity();
        self.generation += 1;
        self.addThread(&self.clist, self.start, 0, text.len, self.generation);

        var pos: usize = 0;
        while (true) {
            for (self.clist.items) |sid| {
                if (self.states[sid] == .match) return true;
            }
            if (pos >= text.len) break;
            const byte = text[pos];

            self.nlist.clearRetainingCapacity();
            self.generation += 1;
            for (self.clist.items) |sid| {
                switch (self.states[sid]) {
                    .byte => |b| if (b.value == byte) self.addThread(&self.nlist, b.out, pos + 1, text.len, self.generation),
                    .any_byte => |b| self.addThread(&self.nlist, b.out, pos + 1, text.len, self.generation),
                    .class => |c| if (matchesClass(c, byte)) self.addThread(&self.nlist, c.out, pos + 1, text.len, self.generation),
                    else => {},
                }
            }
            // Unanchored search: also start a fresh match attempt at the
            // next position. Naturally a no-op for a `^`-anchored pattern
            // — `assert_start` below only lets the closure through at
            // pos == 0, so re-injecting `start` at pos+1 > 0 dead-ends
            // immediately without adding anything new.
            self.addThread(&self.nlist, self.start, pos + 1, text.len, self.generation);

            std.mem.swap(std.ArrayList(usize), &self.clist, &self.nlist);
            pos += 1;
        }
        return false;
    }

    /// Follows epsilon transitions (`split`/`assert_start`/`assert_end`)
    /// from `state_id`, adding every byte-consuming state (and `match`) it
    /// can reach at `pos` to `list`. `gen_marks`-based dedup is what keeps
    /// this from recursing forever around a `*`/`+` loop, and is also
    /// exactly what bounds total work per position to O(states) — each
    /// state is visited at most once per position, regardless of how many
    /// different paths reach it.
    fn addThread(self: *Regex, list: *std.ArrayList(usize), state_id: usize, pos: usize, text_len: usize, gen: usize) void {
        if (self.gen_marks[state_id] == gen) return;
        self.gen_marks[state_id] = gen;
        switch (self.states[state_id]) {
            .split => |s| {
                self.addThread(list, s.out1, pos, text_len, gen);
                self.addThread(list, s.out2, pos, text_len, gen);
            },
            .assert_start => |s| if (pos == 0) self.addThread(list, s.out, pos, text_len, gen),
            .assert_end => |s| if (pos == text_len) self.addThread(list, s.out, pos, text_len, gen),
            .byte, .any_byte, .class, .match => list.append(self.allocator, state_id) catch {},
        }
    }
};

/// Compiles `pattern` into a `Regex`. `allocator` owns the returned
/// `Regex`'s memory for its whole lifetime (freed by `Regex.deinit`) — a
/// separate, short-lived arena backs parsing only (the AST never needs to
/// outlive this function; `Compiler.compileNode` copies anything that does,
/// e.g. character-class ranges, into `allocator`).
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) CompileError!Regex {
    if (pattern.len == 0) return error.UnsupportedSyntax;
    if (pattern.len > max_pattern_len) return error.PatternTooLong;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Parser{ .pattern = pattern, .pos = 0, .allocator = arena.allocator() };
    const ast = try parser.parseAlt();
    // Leftover input after a full parse means something didn't balance,
    // e.g. a stray ')' with no matching '(' (parseConcat stops at ')'
    // without consuming it, so an unmatched one is left dangling here).
    if (parser.pos != pattern.len) return error.UnbalancedGroup;

    var compiler = Compiler{ .allocator = allocator };
    errdefer compiler.states.deinit(allocator);

    const match_id = try compiler.addState(.match);
    const start = try compiler.compileNode(ast, match_id);

    const states_slice = try compiler.states.toOwnedSlice(allocator);
    errdefer allocator.free(states_slice);
    const gen_marks = try allocator.alloc(usize, states_slice.len);
    @memset(gen_marks, 0);

    return .{
        .allocator = allocator,
        .states = states_slice,
        .start = start,
        .gen_marks = gen_marks,
    };
}

const testing = std.testing;

test "literal matching, anywhere in the text (unanchored search)" {
    var re = try compile(testing.allocator, "cat");
    defer re.deinit();
    try testing.expect(re.isMatch("cat"));
    try testing.expect(re.isMatch("a cat sat"));
    try testing.expect(!re.isMatch("dog"));
    try testing.expect(!re.isMatch("ca"));
}

test "'.' matches any single byte" {
    var re = try compile(testing.allocator, "c.t");
    defer re.deinit();
    try testing.expect(re.isMatch("cat"));
    try testing.expect(re.isMatch("cot"));
    try testing.expect(!re.isMatch("ct"));
}

test "character classes: set, range, negation" {
    var set = try compile(testing.allocator, "[abc]");
    defer set.deinit();
    try testing.expect(set.isMatch("b"));
    try testing.expect(!set.isMatch("d"));

    var range = try compile(testing.allocator, "[a-z]+");
    defer range.deinit();
    try testing.expect(range.isMatch("hello"));
    try testing.expect(!range.isMatch("HELLO"));

    var negated = try compile(testing.allocator, "[^0-9]+");
    defer negated.deinit();
    try testing.expect(negated.isMatch("abc"));
    try testing.expect(!negated.isMatch("123"));
}

test "quantifiers: *, +, ?" {
    var star = try compile(testing.allocator, "ab*c");
    defer star.deinit();
    try testing.expect(star.isMatch("ac"));
    try testing.expect(star.isMatch("abc"));
    try testing.expect(star.isMatch("abbbbc"));
    try testing.expect(!star.isMatch("adc"));

    var plus = try compile(testing.allocator, "ab+c");
    defer plus.deinit();
    try testing.expect(!plus.isMatch("ac"));
    try testing.expect(plus.isMatch("abc"));
    try testing.expect(plus.isMatch("abbbbc"));

    var opt = try compile(testing.allocator, "colou?r");
    defer opt.deinit();
    try testing.expect(opt.isMatch("color"));
    try testing.expect(opt.isMatch("colour"));
    try testing.expect(!opt.isMatch("colouur"));
}

test "bounded repetition: {n}, {n,m}, {n,}" {
    var exact = try compile(testing.allocator, "a{3}");
    defer exact.deinit();
    try testing.expect(!exact.isMatch("aa"));
    try testing.expect(exact.isMatch("aaa"));

    var range = try compile(testing.allocator, "^a{2,4}$");
    defer range.deinit();
    try testing.expect(!range.isMatch("a"));
    try testing.expect(range.isMatch("aa"));
    try testing.expect(range.isMatch("aaaa"));
    try testing.expect(!range.isMatch("aaaaa"));

    var open = try compile(testing.allocator, "^a{2,}$");
    defer open.deinit();
    try testing.expect(!open.isMatch("a"));
    try testing.expect(open.isMatch("aa"));
    try testing.expect(open.isMatch("aaaaaaaaaa"));

    var zero = try compile(testing.allocator, "^a{0,0}$");
    defer zero.deinit();
    try testing.expect(zero.isMatch(""));
    try testing.expect(!zero.isMatch("a"));
}

test "alternation and grouping precedence" {
    var alt = try compile(testing.allocator, "cat|dog");
    defer alt.deinit();
    try testing.expect(alt.isMatch("I have a cat"));
    try testing.expect(alt.isMatch("I have a dog"));
    try testing.expect(!alt.isMatch("I have a fish"));

    var grouped = try compile(testing.allocator, "(ab)+c");
    defer grouped.deinit();
    try testing.expect(grouped.isMatch("abc"));
    try testing.expect(grouped.isMatch("ababc"));
    try testing.expect(!grouped.isMatch("abac"));
}

test "anchors: ^, $, and both together" {
    var start_anchor = try compile(testing.allocator, "^abc");
    defer start_anchor.deinit();
    try testing.expect(start_anchor.isMatch("abc def"));
    try testing.expect(!start_anchor.isMatch("xyz abc"));

    var end_anchor = try compile(testing.allocator, "abc$");
    defer end_anchor.deinit();
    try testing.expect(end_anchor.isMatch("xyz abc"));
    try testing.expect(!end_anchor.isMatch("abc def"));

    var full = try compile(testing.allocator, "^abc$");
    defer full.deinit();
    try testing.expect(full.isMatch("abc"));
    try testing.expect(!full.isMatch("abcd"));
    try testing.expect(!full.isMatch("xabc"));
}

test "compile rejects a pattern over max_pattern_len" {
    const allocator = testing.allocator;
    const long = try allocator.alloc(u8, max_pattern_len + 1);
    defer allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(error.PatternTooLong, compile(allocator, long));
}

test "compile rejects a {n,m} bound over max_repetition_bound" {
    try testing.expectError(error.UnboundedRepetition, compile(testing.allocator, "a{5000}"));
    try testing.expectError(error.UnboundedRepetition, compile(testing.allocator, "a{1,5000}"));
}

test "compile rejects a pattern whose compiled NFA would exceed max_nfa_states" {
    // Nested large repetition: (a{999}){999} would compile to ~999*999
    // states if each outer copy fully re-expanded the inner one — exactly
    // the compounding blow-up max_nfa_states exists to catch (a single
    // {n,m} bound-check alone wouldn't, since neither 999 alone exceeds
    // max_repetition_bound).
    try testing.expectError(error.TooManyStates, compile(testing.allocator, "(a{999}){999}"));
}

test "compile rejects malformed syntax rather than guessing intent" {
    try testing.expectError(error.UnbalancedGroup, compile(testing.allocator, "(abc"));
    try testing.expectError(error.UnbalancedGroup, compile(testing.allocator, "abc)"));
    try testing.expectError(error.UnbalancedClass, compile(testing.allocator, "[abc"));
    try testing.expectError(error.UnsupportedSyntax, compile(testing.allocator, "[]"));
    try testing.expectError(error.UnsupportedSyntax, compile(testing.allocator, "*abc"));
    try testing.expectError(error.UnsupportedSyntax, compile(testing.allocator, "a{"));
    try testing.expectError(error.UnsupportedSyntax, compile(testing.allocator, "a{,5}"));
}

test "regression: a classically-catastrophic-for-backtracking-engines pattern completes instantly instead of hanging" {
    var re = try compile(testing.allocator, "(a+)+$");
    defer re.deinit();

    const allocator = testing.allocator;
    // Long run of 'a's followed by a non-matching character — the exact
    // shape that makes a backtracking engine explode trying every way to
    // partition the 'a's among the nested quantifiers before giving up.
    // This engine compiles (a+)+ to a handful of states regardless of
    // nesting depth, so this either matches or rejects in microseconds.
    const n = 5000;
    var text = try allocator.alloc(u8, n + 1);
    defer allocator.free(text);
    @memset(text[0..n], 'a');
    text[n] = '!';

    try testing.expect(!re.isMatch(text));
    // A prefix that actually does satisfy "one or more runs of one or more
    // a's, anchored at the end" should still match, confirming this isn't
    // just "everything returns false" — a's ending exactly at the string's
    // end.
    try testing.expect(re.isMatch(text[0..n]));
}
