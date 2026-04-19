const std = @import("std");
const Io = std.Io;

const linux = std.os.linux;

const Command = @import("command.zig");

const zup = @import("zup");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const io = init.io;
    var stdin_buffer: [1024]u8 = undefined;
    var stdout_buffer: [1024]u8 = undefined;

    while (true) {
        var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
        var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);

        const stdin = &stdin_reader.interface;
        const stdout = &stdout_writer.interface;

        var command = Command.parseCommand(gpa, stdin) catch |err| {
            std.debug.print("Failed to parse command: {}\n", .{err});
            continue;
        };
        defer command.deinit(gpa);

        const child = try std.process.spawn(io, .{
            .argv = command.args,
            .stdin = .pipe,
            .stdout = .pipe,
        });

        var output = child.stdout.?.reader(io, &stdout_buffer);
        const outputer = &output.interface;

        const n = try outputer.readSliceShort(&stdout_buffer);

        std.debug.print("{s}\n", .{stdout_buffer[0..n]});

        try stdout.writeAll("test\n ");
    }
}
