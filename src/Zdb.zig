const Zdb = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.zdb);

const Allocator = mem.Allocator;
const Target = @import("Target.zig");

gpa: Allocator,
options: Options,
target: Target,

pub const Options = struct {
    args: []const []const u8,
};

pub fn init(gpa: Allocator, options: Options) !Zdb {
    return .{
        .gpa = gpa,
        .options = options,
        .target = try Target.init(gpa),
    };
}

pub fn deinit(zdb: *Zdb) void {
    zdb.target.deinit();
}

pub fn loop(zdb: *Zdb) !void {
    const gpa = zdb.gpa;
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();
    var repl_buf: [1024]u8 = undefined;

    const ReplCmd = enum {
        run,
        help,
    };

    var last_cmd: ReplCmd = .help;

    zdb.target.spawn(zdb.options.args) catch |err| {
        var cmd = std.ArrayList(u8).init(gpa);
        defer cmd.deinit();
        for (zdb.options.args) |arg| {
            try cmd.appendSlice(arg);
            try cmd.append(' ');
        }
        try stderr.print("\nSpawning {s} failed with error: {s}\n", .{ cmd.items, @errorName(err) });
        return err;
    };

    while (true) {
        try stderr.print("(zdb) ", .{});

        if (stdin.readUntilDelimiterOrEof(&repl_buf, '\n') catch |err| {
            try stderr.print("\nUnable to parse command: {s}\n", .{@errorName(err)});
            continue;
        }) |line| {
            log.debug("line: {s}", .{line});
            const actual_line = mem.trimRight(u8, line, "\r\n ");
            const cmd: ReplCmd = blk: {
                if (mem.eql(u8, actual_line, "run")) {
                    break :blk .run;
                } else if (mem.eql(u8, actual_line, "help")) {
                    break :blk .help;
                } else if (mem.eql(u8, actual_line, "exit")) {
                    break;
                } else if (actual_line.len == 0) {
                    break :blk last_cmd;
                } else {
                    try stderr.print("Unknown command: {s}\n", .{actual_line});
                    continue;
                }
            };
            last_cmd = cmd;
            switch (cmd) {
                .run => {
                    try zdb.target.@"resume"();
                },
                .help => {},
            }
        }
    }

    try zdb.target.kill();
}
