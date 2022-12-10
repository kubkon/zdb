const Zdb = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.zdb);

const Allocator = mem.Allocator;

allocator: Allocator,
options: Options,

debuggee: ?Debuggee = null,

const Debuggee = struct {
    arena: std.heap.ArenaAllocator,
    process: std.ChildProcess,
    task: std.os.darwin.MachTask,

    fn spawn(gpa: Allocator, args: []const []const u8) !Debuggee {
        var arena = std.heap.ArenaAllocator.init(gpa);
        var process = std.ChildProcess.init(args, arena.allocator());
        process.stdin_behavior = .Inherit;
        process.stdout_behavior = .Inherit;
        process.stderr_behavior = .Inherit;
        process.disable_aslr = true;
        process.start_suspended = true;

        try process.spawn();

        log.debug("Debuggee PID: {d}", .{process.pid});

        const task = try std.os.darwin.machTaskForPid(process.pid);
        if (task.isValid()) {}

        try std.os.ptrace.ptrace(std.os.darwin.PT_ATTACHEXC, process.pid);

        log.debug("Debuggee Mach task: {any}", .{task});

        return Debuggee{
            .arena = arena,
            .process = process,
            .task = task,
        };
    }

    // fn @"continue"(dbg: Debuggee) !void {
    //     try ptrace.ptrace(ptrace.PT_CONTINUE, dbg.process.pid);
    // }

    fn kill(dbg: Debuggee) void {
        std.os.ptrace.ptrace(std.os.darwin.PT_KILL, dbg.process.pid) catch {};
    }
};

pub const Options = struct {
    debuggee_args: []const []const u8,
};

pub fn init(allocator: Allocator, options: Options) Zdb {
    return .{
        .allocator = allocator,
        .options = options,
    };
}

pub fn deinit(zdb: *Zdb) void {
    if (zdb.debuggee) |*debuggee| {
        debuggee.arena.deinit();
    }
}

pub fn loop(zdb: *Zdb) !void {
    const gpa = zdb.allocator;
    const stdin = std.io.getStdIn().reader();
    const stderr = std.io.getStdErr().writer();
    var repl_buf: [1024]u8 = undefined;

    const ReplCmd = enum {
        run,
        help,
    };

    var last_cmd: ReplCmd = .help;

    zdb.debuggee = Debuggee.spawn(gpa, zdb.options.debuggee_args) catch |err| blk: {
        var cmd = std.ArrayList(u8).init(gpa);
        defer cmd.deinit();
        for (zdb.options.debuggee_args) |arg| {
            try cmd.appendSlice(arg);
            try cmd.append(' ');
        }
        try stderr.print("\nSpawning {s} failed with error: {s}\n", .{ cmd.items, @errorName(err) });
        break :blk null;
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
                .run => if (zdb.debuggee) |debuggee| {
                    _ = debuggee;
                } else {
                    try stderr.print("No process is running\n", .{});
                    continue;
                },
                .help => {},
            }
        }
    }

    if (zdb.debuggee) |debuggee| {
        debuggee.kill();
    }
}
