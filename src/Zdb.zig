const Zdb = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.zdb);

const Allocator = mem.Allocator;

allocator: Allocator,
options: Options,

pub const Options = struct {
    debugee_args: []const []const u8,
};

pub fn init(allocator: Allocator, options: Options) Zdb {
    return .{
        .allocator = allocator,
        .options = options,
    };
}

pub fn deinit(zdb: *Zdb) void {
    _ = zdb;
}

pub fn loop(zdb: *Zdb) !void {
    var debugee_arena = std.heap.ArenaAllocator.init(zdb.allocator);
    defer debugee_arena.deinit();
    var debugee = std.ChildProcess.init(zdb.options.debugee_args, debugee_arena.allocator());
    debugee.stdin_behavior = .Pipe;
    debugee.stdout_behavior = .Pipe;
    debugee.stderr_behavior = .Pipe;
    debugee.disable_aslr = true;

    try debugee.spawn();

    log.debug("Debugee PID: {d}", .{debugee.pid});

    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();
    var repl_buf: [1024]u8 = undefined;

    const ReplCmd = enum {
        run,
        help,
    };

    var last_cmd: ReplCmd = .help;

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
                .run => {},
                .help => {},
            }
        }
    }

    _ = try debugee.kill();
}
