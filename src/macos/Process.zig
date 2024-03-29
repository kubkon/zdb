const Process = @This();

const std = @import("std");
const assert = std.debug.assert;
const darwin = std.os.darwin;
const log = std.log.scoped(.process);
const mem = std.mem;
const ps = @import("posix_spawn.zig");

const Allocator = mem.Allocator;
const Message = @import("Message.zig");
const Task = @import("Task.zig");
const Thread = @import("Thread.zig");

gpa: Allocator,
arena: std.heap.ArenaAllocator,
child_pid: std.os.pid_t,
task: Task,

state: enum {
    invalid,
    stopped,
    suspended,
    running,
    stepping,
} = .invalid,

exception_messages: std.ArrayListUnmanaged(Message) = .{},

/// The main thread of execution of the debugged process. Normally,
/// this will be a thread list, but for now, we are dealing with single-threaded
/// simple programs.
main_thread: ?Thread = null,

pub fn init(gpa: Allocator) Process {
    var arena = std.heap.ArenaAllocator.init(gpa);
    return .{
        .gpa = gpa,
        .arena = arena,
        .child_pid = -1,
        .task = undefined,
    };
}

pub fn deinit(process: *Process) void {
    process.arena.deinit();
    process.task.deinit();
    process.exception_messages.deinit(process.gpa);
}

pub fn spawn(process: *Process, args: []const []const u8) !void {
    process.child_pid = try spawnPosixSpawn(process.arena.allocator(), args);
    // process.child_pid = try spawnFork(process.arena.allocator(), args);

    process.task = Task{ .gpa = process.gpa, .process = process };
    process.task.startExceptionHandler() catch |err| {
        log.err("failed to start exception handler with error: {s}", .{@errorName(err)});
        log.err("  killing process", .{});
        std.os.ptrace(darwin.PT.KILL, process.child_pid, 0, 0) catch {};
        return err;
    };

    try std.os.ptrace(darwin.PT.ATTACHEXC, process.child_pid, 0, 0);
    log.debug("successfully attached with ptrace", .{});
}

/// Spawn the child process using posix_spawn syscall.
/// TODO handle piping, etc.
fn spawnPosixSpawn(arena: Allocator, args: []const []const u8) !std.os.pid_t {
    var attr = try ps.Attr.init();
    defer attr.deinit();
    var flags: u16 = darwin.POSIX_SPAWN.SETSIGDEF |
        darwin.POSIX_SPAWN.SETSIGMASK |
        darwin.POSIX_SPAWN.DISABLE_ASLR |
        darwin.POSIX_SPAWN.START_SUSPENDED;
    try attr.set(flags);

    const args_buf = try arena.allocSentinel(?[*:0]u8, args.len, null);
    for (args, 0..) |arg, i| args_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const pid = try ps.spawn(args[0], null, attr, args_buf, std.c.environ);
    log.debug("child PID: {d}", .{pid});
    return pid;
}

fn spawnFork(arena: Allocator, args: []const []const u8) !i32 {
    _ = arena;
    _ = args;
    return error.Todo;
}

pub fn @"resume"(process: *Process) !void {
    log.debug("resume({*})", .{process});
    log.debug("  (state {s})", .{@tagName(process.state)});
    switch (process.state) {
        .stopped => { // can resume
            return process.resumeImpl();
        },
        .running => { // aiready running
        },
        else => { // cannot continue
            return error.CannotContinue;
        },
    }
}

pub fn kill(process: Process) void {
    std.os.ptrace(darwin.PT.KILL, process.child_pid, 0, 0) catch {};
}

pub fn appendExceptionMessage(process: *Process, msg: Message) !void {
    if (process.exception_messages.items.len == 0) {
        try process.task.@"suspend"();
    }
    try process.exception_messages.append(process.gpa, msg);
}

pub fn notifyExceptionMessageBundleComplete(process: *Process) !void {
    log.debug("notifyExceptionMessageBundleComplete", .{});

    if (process.exception_messages.items.len > 0) {
        var num_task_exceptions: usize = 0;

        for (process.exception_messages.items) |msg| {
            if (msg.state.task_port.port != process.task.mach_task.?.port) continue;

            num_task_exceptions += 1;

            if (try msg.state.getSoftSignal()) |signo| switch (signo) {
                darwin.SIG.TRAP => {
                    log.debug("received signo SIGTRAP({d})", .{signo});
                    // TODO handle
                    unreachable;
                },
                else => {
                    log.debug("received signo {d}", .{signo});
                },
            };
        }
    }

    try process.didStop();

    for (process.exception_messages.items) |msg| {
        if (msg.state.task_port.port != process.task.mach_task.?.port) continue;
        try process.main_thread.?.notifyException(msg.state);
    }

    if (process.main_thread.?.shouldStop()) {
        process.state = .stopped;
        log.debug("  (state {s})", .{@tagName(process.state)});
    } else {
        try process.resumeImpl();
    }
}

fn resumeImpl(process: *Process) !void {
    const main_thread = process.main_thread orelse unreachable;

    while (process.exception_messages.popOrNull()) |const_msg| {
        var msg = const_msg;
        var thread_reply_signal: usize = 0;
        if (main_thread.port.port == msg.state.thread_port.port) {
            log.debug("msg belongs to main thread {any}", .{main_thread.port});
            try msg.reply(process, thread_reply_signal);
        } else {
            log.debug("unnmatched msg {any}", .{msg});
        }
    }

    try process.main_thread.?.willResume();
    process.state = .running;

    try process.task.@"resume"();
}

fn didStop(process: *Process) !void {
    try process.updateMainThread(true);
    try process.main_thread.?.didStop();
}

fn updateMainThread(process: *Process, update: bool) !void {
    const curr_threads = try process.task.mach_task.?.getThreads();
    defer curr_threads.deinit();

    assert(curr_threads.buf.len == 1); // TODO we do not yet know how to handle multi-threading

    const thread = curr_threads.buf[0];
    const info = try thread.getIdentifierInfo();

    const curr_main_thread = process.main_thread orelse {
        process.main_thread = Thread{ .guid = info.thread_id, .port = thread };
        return;
    };

    if (update and curr_main_thread.guid != info.thread_id) {
        process.main_thread = Thread{ .guid = info.thread_id, .port = thread };
    }
}
