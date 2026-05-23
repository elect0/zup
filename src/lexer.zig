const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

pub const Context = enum { base, sq, dq, arithmetic, dollar_sq, subshell, vs_1, vs_2, vs_arg_uq, vs_arg_dq, comment, backtick };

pub const TokenType = enum {
    eof,
    newline,
    word, // e.g: "ls"

    pipe, // |
    ampersand, // &
    semi, // ;
    d_semi, // ;;
    logic_and, // &&
    logic_or, // ||

    l_paren, // (
    r_paren, // )
    d_lparen, // ((
    d_rparen, // ))
    d_lbracket, // [[
    d_rbracket, // ]]
    l_brace, // {
    r_brace, // }

    redirect_in, // <
    redirect_out, // >
    append_out, // >>
    heredoc, // <<,
    heredoc_strip, // <<-
    redir_out_force, // >|
    dup_in, // <&
    dup_out, // >&

    k_if,
    k_then,
    k_else,
    k_elif,
    k_fi,
    k_for,
    k_while,
    k_until,
    k_do,
    k_done,
    k_case,
    k_esac,
    k_in,
};

pub const Token = struct {
    tag: TokenType,
    text: []const u8,
};

const keywords = std.static_string_map.StaticStringMap(TokenType).initComptime(.{
    .{ "if", .k_if },
    .{ "then", .k_then },
    .{ "else", .k_else },
    .{ "elif", .k_elif },
    .{ "fi", .k_fi },
    .{ "for", .k_for },
    .{ "while", .k_while },
    .{ "until", .k_until },
    .{ "do", .k_do },
    .{ "done", .k_done },
    .{ "case", .k_case },
    .{ "esac", .k_esac },
    .{ "in", .k_in },
});

pub const Lexer = struct {
    input: []const u8,
    pos: usize,
    stack: std.ArrayList(Context),

    pub fn init(allocator: Allocator, input: []const u8) !Lexer {
        var stack: std.ArrayList(Context) = try .initCapacity(allocator, 16);
        try stack.append(allocator, .base);

        return .{
            .input = input,
            .pos = 0,
            .stack = stack,
        };
    }

    pub fn deinit(self: *Lexer, allocator: Allocator) void {
        self.stack.deinit(allocator);
    }

    pub fn next(self: *Lexer, allocator: Allocator) !Token {
        while (self.pos < self.input.len) : (self.pos += 1) {
            if (!isWhitespace(self.input[self.pos])) break;
        }

        if (self.pos == self.input.len) return .{ .tag = .eof, .text = "" };

        var context: Context = self.stack.getLast() orelse .base;

        const start = self.pos;

        while (self.pos < self.input.len) {
            const char = self.input[self.pos];

            switch (context) {
                .base => {
                    switch (char) {
                        '\'' => {
                            context = .sq;
                            try self.stack.append(allocator, context);
                            continue;
                        },
                        '\"' => {
                            context = .dq;
                            try self.stack.append(allocator, context);
                            continue;
                        },
                        '$' => {
                            if (self.peek(1)) |c| {
                                switch (c) {
                                    '(' => {
                                        if (self.peek(2) == '(') {
                                            context = .arithmetic;
                                            try self.stack.append(allocator, context);
                                            continue;
                                        }

                                        var depth_counter: i32 = 1;

                                        while (self.pos < self.input.len) : (self.pos += 1) {
                                            if (self.input[self.pos] == '(') {
                                                depth_counter += 1;
                                            }

                                            if (self.input[self.pos] == ')') {
                                                depth_counter -= 1;
                                            }
                                        }

                                        if (depth_counter != 0) {
                                            return error.UnclosedParen;
                                        }

                                        return .{ .tag = .word, .text = self.input[start..self.pos] };
                                    },
                                    '{' => {
                                        context = .vs_1;
                                        try self.stack.append(allocator, context);
                                        continue;
                                    },
                                    '\'' => {
                                        context = .dollar_sq;
                                        try self.stack.append(allocator, context);
                                        continue;
                                    },
                                    else => {
                                        while (self.pos < self.input.len) : (self.pos += 1) {
                                            switch (self.input[self.pos]) {
                                                '&',
                                                '<',
                                                '>',
                                                '|',
                                                ';',
                                                ' ',
                                                '\n',
                                                '\t',
                                                '\r',
                                                '(',
                                                => {
                                                    const word = self.input[start..self.pos];
                                                    return .{ .tag = .word, .text = word };
                                                },
                                                '\'', '\"' => {
                                                    break;
                                                },
                                                else => {},
                                            }
                                        }
                                    },
                                }
                            } else {
                                return .{ .tag = .word, .text = "$" };
                            }
                        },
                        '|' => {
                            if (self.peek(1) == '|') {
                                self.pos += 1;
                                return .{ .tag = .logic_or, .text = self.input[start..self.pos] };
                            }

                            return .{ .tag = .pipe, .text = "|" };
                        },
                        '&' => {
                            if (self.peek(1) == '&') {
                                self.pos += 1;
                                return .{ .tag = .logic_and, .text = self.input[start..self.pos] };
                            }

                            return .{ .tag = .ampersand, .text = "&" };
                        },
                        ';' => {
                            if (self.peek(1) == ';') {
                                self.pos += 1;
                                return .{ .tag = .d_semi, .text = self.input[start..self.pos] };
                            }

                            return .{ .tag = .semi, .text = ";" };
                        },
                        '(' => {
                            if (self.peek(1) == '(') {
                                self.pos += 2;
                                context = .arithmetic;
                                try self.stack.append(allocator, context);
                                return .{ .tag = .d_lparen, .text = self.input[start .. self.pos - 1] };
                            }

                            self.pos += 1;
                            context = .subshell;
                            try self.stack.append(allocator, context);
                            return .{ .tag = .l_paren, .text = "(" };
                        },
                        '{' => {
                            self.pos += 1;
                            return .{ .tag = .l_brace, .text = "{" };
                        },
                        '<' => {
                            if (self.peek(1)) |c| {
                                switch (c) {
                                    '<' => {
                                        if (self.peek(2) == '-') {
                                            self.pos += 3;
                                            return .{ .tag = .heredoc_strip, .text = self.input[start .. self.pos - 1] };
                                        }

                                        self.pos += 2;
                                        return .{ .tag = .heredoc, .text = self.input[start .. self.pos - 1] };
                                    },
                                    '&' => {
                                        self.pos += 2;
                                        return .{ .tag = .dup_in, .text = self.input[start .. self.pos - 1] };
                                    },
                                    else => {
                                        self.pos += 1;
                                        return .{ .tag = .redirect_in, .text = "<" };
                                    },
                                }
                            } else {
                                self.pos += 1;
                                return .{ .tag = .redirect_in, .text = "<" };
                            }
                        },
                        '>' => {
                            if (self.peek(1)) |c| {
                                switch (c) {
                                    '>' => {
                                        self.pos += 2;
                                        return .{ .tag = .dup_in, .text = self.input[start .. self.pos - 1] };
                                    },
                                    '|' => {
                                        self.pos += 2;
                                        return .{ .tag = .redir_out_force, .text = self.input[start .. self.pos - 1] };
                                    },
                                    '&' => {
                                        self.pos += 2;
                                        return .{ .tag = .dup_out, .text = self.input[start .. self.pos - 1] };
                                    },
                                    else => {
                                        self.pos += 1;
                                        return .{ .tag = .redirect_out, .text = ">" };
                                    },
                                }
                            } else {
                                self.pos += 1;
                                return .{ .tag = .redirect_out, .text = ">" };
                            }
                        },
                        ')', ']', '}' => return error.Unexpected,
                        else => {
                            while (self.pos < self.input.len) {
                                switch (self.input[self.pos]) {
                                    ' ', '\n', '\r', '\t', '|', ';', '&', '<', '>', '\'', '\"', '$', '`' => {
                                        break;
                                    },
                                    else => {
                                        self.pos += 1;
                                    },
                                }
                            }

                            const c = self.input[self.pos - 1];

                            if (c == '\'' or c == '\"' or c == '$' or c == '`') {
                                continue;
                            }
                        },
                    }
                },
                .sq => {
                    self.pos += 1;
                    while (self.pos < self.input.len) : (self.pos += 1) {
                        if (self.input[self.pos] == '\'') {
                            _ = self.stack.pop();
                            context = self.stack.getLast() orelse .base;
                            self.pos += 1;

                            std.debug.print("String: {s}\n", .{self.input[start..self.pos]});
                            break;
                        }
                    }

                    continue;
                },
                else => std.debug.print("Woops!\n", .{}),
            }

            break;
        }

        const word = self.input[start..self.pos];

        if (keywords.get(word)) |keyword| {
            return .{ .tag = keyword, .text = word };
        }

        return .{ .tag = .word, .text = word };
    }

    fn peek(self: *Lexer, offset: usize) ?u8 {
        if ((self.pos + offset) < self.input.len) {
            return self.input[(self.pos + offset)];
        } else {
            return null;
        }
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == '\r';
}

test "basic test" {
    const gpa = testing.allocator;
    const input = "ls -la --color=auto";

    var lexer: Lexer = try .init(gpa, input);
    defer lexer.deinit(gpa);

    var token: Token = undefined;

    while (true) {
        token = try lexer.next(gpa);

        std.debug.print("Token type: {s: <16}, Text: {s}\n", .{ @tagName(token.tag), token.text });

        if (token.tag == .eof) {
            break;
        }
    }
}
