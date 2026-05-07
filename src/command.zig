const std = @import("std");

const testing = std.testing;
const Reader = std.Io.Reader;

pub const Command = struct {
    args: []const []const u8,

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        for (self.args) |arg| {
            allocator.free(arg);
        }

        allocator.free(self.args);
    }

    pub fn count(self: *Command) usize {
        return self.args.len;
    }

    pub fn getArg(self: *Command, index: usize) []const u8 {
        return self.args[index];
    }
};

pub fn parseCommand(allocator: std.mem.Allocator, reader: *Reader) !Command {
    const line = reader.takeDelimiterExclusive('\n') catch |err| {
        if (err == error.EndOfStream) return error.EmptyCommand;
        return err;
    };

    var args = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    while (it.next()) |token| {
        const dupe = try allocator.dupe(u8, token);
        try args.append(allocator, dupe);
    }

    if (args.items.len == 0) return error.EmptyCommand;

    return .{ .args = try args.toOwnedSlice(allocator) };
}

test "parser: basic ls command" {
    const allocator = std.testing.allocator;

    const data = "ls -l /home/edu\n";

    var fixed_reader = Reader.fixed(data);

    var command = try parseCommand(allocator, &fixed_reader);
    defer command.deinit(allocator);

    try testing.expectEqual(command.count(), 3);
    try testing.expectEqualStrings("ls", command.getArg(0));
    try testing.expectEqualStrings("/home/edu", command.getArg(2));
}

