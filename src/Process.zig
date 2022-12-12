const Process = @This();

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.process);
const mem = std.mem;

const Allocator = mem.Allocator;
const Task = @import("Task.zig");

arena: std.heap.ArenaAllocator,
child: std.ChildProcess,
task: Task,

pub fn deinit(self: *Process) void {
    self.arena.deinit();
    self.task.deinit();
}

pub fn spawn(gpa: Allocator, args: []const []const u8) !Process {
    var arena = std.heap.ArenaAllocator.init(gpa);
    var child = std.ChildProcess.init(args, arena.allocator());
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.disable_aslr = true;
    child.start_suspended = true;

    try child.spawn();
    log.debug("PID: {d}", .{child.pid});

    var task = Task{ .allocator = gpa, .pid = child.pid };
    task.startExceptionHandler() catch |err| {
        log.err("failed to start exception handler with error: {s}", .{@errorName(err)});
        log.err("  killing process", .{});
        std.os.ptrace.ptrace(darwin.PT_KILL, child.pid) catch {};
        return err;
    };

    try std.os.ptrace.ptrace(darwin.PT_ATTACHEXC, child.pid);
    log.debug("successfully attached with ptrace", .{});

    return Process{
        .arena = arena,
        .child = child,
        .task = task,
    };
}

pub fn @"resume"(self: Process) !void {
    return self.task.@"resume"();
}

pub fn kill(self: Process) void {
    std.os.ptrace.ptrace(darwin.PT_KILL, self.child.pid) catch {};
}
