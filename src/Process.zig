const Process = @This();

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.process);
const mem = std.mem;

const Allocator = mem.Allocator;
const Message = @import("Message.zig");
const Task = @import("Task.zig");

allocator: Allocator,
arena: std.heap.ArenaAllocator,
child: std.ChildProcess,
task: Task,

exception_messages: std.ArrayListUnmanaged(Message) = .{},
exception_messages_mutex: std.Thread.Mutex = .{},

pub fn deinit(self: *Process) void {
    self.arena.deinit();
    self.task.deinit();

    self.exception_messages.deinit(self.allocator);
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

    var self = Process{
        .allocator = gpa,
        .arena = arena,
        .child = child,
        .task = undefined,
    };
    self.task = Task{ .allocator = gpa, .process = &self };
    self.task.startExceptionHandler() catch |err| {
        log.err("failed to start exception handler with error: {s}", .{@errorName(err)});
        log.err("  killing process", .{});
        std.os.ptrace.ptrace(darwin.PT_KILL, child.pid) catch {};
        return err;
    };

    try std.os.ptrace.ptrace(darwin.PT_ATTACHEXC, child.pid);
    log.debug("successfully attached with ptrace", .{});

    return self;
}

pub fn getPid(self: Process) i32 {
    return self.child.pid;
}

pub fn @"resume"(self: *Process) !void {
    self.exception_messages_mutex.lock();
    defer self.exception_messages_mutex.unlock();

    return self.task.@"resume"();
}

pub fn kill(self: Process) void {
    std.os.ptrace.ptrace(darwin.PT_KILL, self.child.pid) catch {};
}

pub fn appendExceptionMessage(self: *Process, msg: Message) !void {
    self.exception_messages_mutex.lock();
    defer self.exception_messages_mutex.unlock();

    if (self.exception_messages.items.len == 0) {
        try self.task.@"suspend"();
    }

    try self.exception_messages.append(self.allocator, msg);
}

pub fn notifyExceptionMessageBundleComplete(self: *Process) !void {
    _ = self;
    log.debug("notifyExceptionMessageBundleComplete", .{});
}
