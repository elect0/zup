const std = @import("std");

const testing = std.testing;

pub const TokenType = enum {
    eof,
    word, // e.g: "ls"
    pipe, // |
    redirect_in, // <
    redirect_out, // >,
    redirect_heredoc, // <<,
    redirect_append, // >>,
    background, // &
    logic_and, // &&
    logic_or, // ||
    // variable, // e.g: $HOME
};

const Token = struct {
    text: []const u8,
    tag: TokenType,
};

pub const Redirect = struct {
    type: TokenType,
    fd: i32,
    target: []const u8,
};

pub const AstNode = union(enum) {
    command: struct { args: [][]const u8, redirect: Redirect },

    background: struct { left: *AstNode },

    pipeline: struct { left: *AstNode, right: *AstNode },
    logic_and: struct { left: *AstNode, right: *AstNode },
    logic_or: struct { left: *AstNode, right: *AstNode },
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
        };
    }

    pub fn next(self: *Lexer, allocator: std.mem.Allocator) !Token {
        self.pos = skipWhitespaceSimd(self.input, self.pos);

        if (self.pos == self.input.len) return .{ .tag = .eof, .text = "" };

        if ((self.pos + 1) < self.input.len) {
            const symbol = self.input[self.pos..(self.pos + 2)];

            if (std.mem.eql(u8, symbol, ">>")) {
                self.pos += 2;
                return .{ .tag = .redirect_append, .text = ">>" };
            }
            if (std.mem.eql(u8, symbol, "<<")) {
                self.pos += 2;
                return .{ .tag = .redirect_heredoc, .text = "<<" };
            }
            if (std.mem.eql(u8, symbol, "||")) {
                self.pos += 2;
                return .{ .tag = .logic_or, .text = "||" };
            }
            if (std.mem.eql(u8, symbol, "&&")) {
                self.pos += 2;
                return .{ .tag = .logic_and, .text = "&&" };
            }
        }

        const char = self.input[self.pos];

        switch (char) {
            '>' => {
                self.pos += 1;
                return .{ .tag = .redirect_out, .text = ">" };
            },
            '<' => {
                self.pos += 1;
                return .{ .tag = .redirect_in, .text = "<" };
            },
            '|' => {
                self.pos += 1;
                return .{ .tag = .pipe, .text = "|" };
            },
            '&' => {
                self.pos += 1;
                return .{ .tag = .background, .text = "&" };
            },
            '$' => {
                const start = self.pos;
                self.pos = findWhitespaceSimd(self.input, start);

                const word = self.input[start..self.pos];

                return .{ .tag = .word, .text = word };
            },
            else => {},
        }

        var fallbackStack = std.heap.stackFallback(2048, allocator);
        const fallback_allocator = fallbackStack.get();

        var word_buffer: std.ArrayList(u8) = try .initCapacity(fallback_allocator, 2048);
        defer word_buffer.deinit(fallback_allocator);

        while (self.pos < self.input.len) {
            self.pos = skipWhitespaceSimd(self.input, self.pos);
            const c = self.input[self.pos];

            switch (c) {
                ' ', '\t', '\n', '\r', '>', '<', '|', '&', ';' => {
                    break;
                },
                '\'' => {
                    self.pos += 1;
                    const start = self.pos;
                    const end = findCharSimd(self.input, start, '\'') orelse return error.Unclosed;
                    const word = self.input[start..end];
                    try word_buffer.appendSlice(fallback_allocator, word);

                    self.pos = end;
                    self.pos += 1;
                },
                '\"' => {
                    self.pos += 1;
                    while (self.pos < self.input.len) {
                        const end = findAnySimd(self.input, self.pos, "\"") orelse return error.Unclosed;
                        const word = self.input[self.pos..end];
                        try word_buffer.appendSlice(fallback_allocator, word);
                        self.pos = end;

                        if (self.input[self.pos] == '\"') {
                            self.pos += 1;
                            break;
                        } else {
                            self.pos += 1;
                            if (self.pos < self.input.len) {
                                const escaped = self.input[self.pos];

                                if (std.mem.findScalar(u8, "$\"`\\", escaped) != null) {
                                    try word_buffer.append(fallback_allocator, escaped);
                                } else {
                                    try word_buffer.append(fallback_allocator, '\\');
                                    try word_buffer.append(fallback_allocator, escaped);
                                }
                                self.pos += 1;
                            }
                        }
                    }
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.input.len) try word_buffer.append(fallback_allocator, self.input[self.pos]);
                    self.pos += 1;
                },
                else => {
                    const start = self.pos;
                    const end = findWhitespaceSimd(self.input, start);

                    if (findAnySimd(self.input[start..end], 0, "'\"\\")) |pos| {
                        self.pos += pos;
                        const word = self.input[start..self.pos];
                        try word_buffer.appendSlice(allocator, word);
                        continue;
                    }

                    self.pos = end;
                    const word = self.input[start..self.pos];

                    if (start == 0 or (start > 0 and isWhitespace(self.input[start - 1]))) {
                        return .{ .tag = .word, .text = word };
                    } else {
                        try word_buffer.appendSlice(allocator, word);
                        continue;
                    }
                },
            }
        }

        return .{ .tag = .word, .text = try word_buffer.toOwnedSlice(fallback_allocator) };
    }
};
inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn skipWhitespaceSimd(input: []const u8, start: usize) usize {
    var i = start;
    const len = input.len;

    if (i < len and !isWhitespace(input[i])) return i;

    const VectorSize = 16;
    const V = @Vector(VectorSize, u8);
    while (i + VectorSize < len) {
        const chunk: V = input[i..][0..VectorSize].*;

        const is_space = chunk == @as(V, @splat(' '));
        const is_tab = chunk == @as(V, @splat('\t'));
        const is_nl = chunk == @as(V, @splat('\n'));
        const is_cr = chunk == @as(V, @splat('\r'));

        const is_ws = is_space | is_tab | is_nl | is_cr;

        // Create bitmask (1 = non-whitespace)
        const mask: u16 = @bitCast(~is_ws);

        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += VectorSize;
    }

    while (i < len) {
        if (!isWhitespace(input[i])) return i;
        i += 1;
    }

    return i;
}

pub fn findWhitespaceSimd(input: []const u8, start: usize) usize {
    var i = start;
    const len = input.len;

    if (i < len and isWhitespace(input[i])) return i;

    const VectorSize = 16;
    const V = @Vector(VectorSize, u8);

    while (i + VectorSize < len) {
        const chunk = input[i..][0..VectorSize].*;

        const is_space = chunk == @as(V, @splat(' '));
        const is_tab = chunk == @as(V, @splat('\t'));
        const is_nl = chunk == @as(V, @splat('\n'));
        const is_cr = chunk == @as(V, @splat('\r'));

        const is_ws = is_space | is_tab | is_nl | is_cr;

        const mask: u16 = @bitCast(is_ws);

        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += VectorSize;
    }

    while (i < len) {
        if (isWhitespace(input[i])) return i;
        i += 1;
    }

    return i;
}

fn findCharSimd(input: []const u8, start: usize, target: u8) ?usize {
    var i = start;
    const len = input.len;

    const VectorSize = 16;
    const V = @Vector(VectorSize, u8);

    while (i + VectorSize < len) {
        const chunk = input[i..][0..VectorSize].*;

        const is_target = chunk == @as(V, @splat(target));

        const mask: u16 = @bitCast(is_target);

        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += VectorSize;
    }

    while (i < len) {
        if (input[i] == target) break;
        i += 1;
    }

    if (i == len) return undefined;

    return i;
}

fn findAnySimd(input: []const u8, start: usize, comptime targets: []const u8) ?usize {
    var i = start;
    const len = input.len;
    const VectorSize = 16;
    const V = @Vector(VectorSize, u8);

    while ((i + VectorSize) < len) {
        const chunk = input[i..][0..VectorSize].*;

        var match_mask: @Vector(VectorSize, bool) = @splat(false);

        inline for (targets) |target| {
            match_mask |= (chunk == @as(V, @splat(target)));
        }

        const mask: u16 = @bitCast(match_mask);

        if (mask != 0) {
            return i + @ctz(mask);
        }

        i += VectorSize;
    }

    while (i < len) {
        for (targets) |t| {
            if (input[i] == t) return i;
        }

        i += 1;
    }

    return null;
}

test "lexer: basic shell command" {
    const gpa = testing.allocator;

    const input = "ls -la";
    var l: Lexer = .init(input);

    var token: Token = undefined;

    // First token: 'ls'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("ls", token.text);

    // Second token: 'ls'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("-la", token.text);
}

test "lexer: mixing quotes" {
    const gpa = testing.allocator;

    const input = "echo \"double\"'single'normal";
    var l: Lexer = .init(input);

    var token: Token = undefined;

    // First token: 'echo'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("echo", token.text);

    // Second token: 'doublesinglenormal' (string concatenation since there is
    // no space)
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("doublesinglenormal", token.text);
}

test "lexer: multiple spaces" {
    const gpa = testing.allocator;

    const input = "ls                 -la                 /var/log";
    var l: Lexer = .init(input);

    var token: Token = undefined;

    // First token: 'ls'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("ls", token.text);

    // Second token: 'ls'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("-la", token.text);

    // Third token: '/var/log'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("/var/log", token.text);
}

test "lexer: pipes and redirections" {
    const gpa = testing.allocator;

    const input = "fc-list | grep '0xProto' > list.txt";
    var l: Lexer = .init(input);

    var token: Token = undefined;

    // First token: 'fc-list'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("fc-list", token.text);

    // Second token: '|' (pipe)
    token = try l.next(gpa);
    try testing.expect(token.tag == .pipe);

    // Third token: 'grep'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("grep", token.text);

    // Fifth token: '0xProto'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("0xProto", token.text);

    // Sixth token: '>' (redirect_out)
    token = try l.next(gpa);
    try testing.expect(token.tag == .redirect_out);

    // Seventh token: 'list.txt'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("list.txt", token.text);
}

test "lexer: logical operations and vars" {
    const gpa = testing.allocator;

    const input = "$HOME/test.sh & || echo \"warning\"";
    var l: Lexer = .init(input);

    var token: Token = undefined;

    // First token: '$HOME/test.sh'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("$HOME/test.sh", token.text);

    // Second token: '&' (background)
    token = try l.next(gpa);
    try testing.expect(token.tag == .background);

    // Third token: '||' (logic_or)
    token = try l.next(gpa);
    try testing.expect(token.tag == .logic_or);

    // Fourth token: 'echo'
    token = try l.next(gpa);
    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("echo", token.text);

    // Fifth token: 'warning'
    token = try l.next(gpa);

    try testing.expect(token.tag == .word);
    try testing.expectEqualStrings("echo", token.text);
}

// while (true) {
//     const token = try l.next(gpa);
//     std.debug.print("Token type: {s: <16}, Text: '{s}'\n", .{ @tagName(token.tag), token.text });
//
//     if (token.tag == .eof) {
//         break;
//     }
// }
