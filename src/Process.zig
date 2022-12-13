const Process = @This();

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.process);
const mem = std.mem;

const Allocator = mem.Allocator;
const Message = @import("Message.zig");
const Task = @import("Task.zig");
const ThreadList = @import("ThreadList.zig");

gpa: Allocator,
arena: std.heap.ArenaAllocator,
child: std.ChildProcess,
task: Task,

exception_messages: std.ArrayListUnmanaged(Message) = .{},
exception_messages_mutex: std.Thread.Mutex = .{},

thread_list: ThreadList = .{},

pub fn deinit(self: *Process) void {
    self.arena.deinit();
    self.task.deinit();

    self.exception_messages.deinit(self.gpa);
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

    var process = Process{
        .gpa = gpa,
        .arena = arena,
        .child = child,
        .task = undefined,
    };
    process.task = Task{ .gpa = gpa, .process = &process };
    process.task.startExceptionHandler() catch |err| {
        log.err("failed to start exception handler with error: {s}", .{@errorName(err)});
        log.err("  killing process", .{});
        std.os.ptrace.ptrace(darwin.PT_KILL, child.pid) catch {};
        return err;
    };

    try std.os.ptrace.ptrace(darwin.PT_ATTACHEXC, child.pid);
    log.debug("successfully attached with ptrace", .{});

    return process;
}

pub fn getPid(process: Process) i32 {
    return process.child.pid;
}

pub fn @"resume"(process: *Process) !void {
    process.exception_messages_mutex.lock();
    defer process.exception_messages_mutex.unlock();

    return process.task.@"resume"();
}

pub fn kill(process: Process) void {
    std.os.ptrace.ptrace(darwin.PT_KILL, process.child.pid) catch {};
}

pub fn appendExceptionMessage(process: *Process, msg: Message) !void {
    process.exception_messages_mutex.lock();
    defer process.exception_messages_mutex.unlock();

    if (process.exception_messages.items.len == 0) {
        try process.task.@"suspend"();
    }

    try process.exception_messages.append(process.gpa, msg);
}

pub fn notifyExceptionMessageBundleComplete(process: *Process) !void {
    process.exception_messages_mutex.lock();
    defer process.exception_messages_mutex.unlock();

    log.debug("notifyExceptionMessageBundleComplete", .{});

    if (process.exception_messages.items.len > 0) {
        var num_task_exceptions: usize = 0;

        for (process.exception_messages.items) |msg| {
            if (msg.state.task_port.port != process.task.mach_task.?.port) continue;

            num_task_exceptions += 1;
            const signo = msg.state.getSoftSignal().?; // TODO handle
            log.debug("signo {d}", .{signo});
        }

        try process.thread_list.processDidStop(process.gpa, process);
    }
}
