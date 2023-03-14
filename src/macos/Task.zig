const Task = @This();

const std = @import("std");
const assert = std.debug.assert;
const darwin = os.darwin;
const log = std.log.scoped(.task);
const os = std.os;

const Allocator = std.mem.Allocator;
const Message = @import("Message.zig");
const Process = @import("Process.zig");

gpa: Allocator,
process: *Process,
mach_task: ?darwin.MachTask = null,
exception_handler: ?ExceptionHandler = null,

const ExceptionHandler = struct {
    mach_port: darwin.MachTask,
    mach_port_info: darwin.MachTask.PortInfo,
    thread: std.Thread,
};

pub fn deinit(self: *Task) void {
    if (self.exception_handler) |handler| {
        const self_mach_task = darwin.machTaskForSelf();
        self_mach_task.deallocatePort(handler.mach_port);
    }
    self.exception_handler = null;
}

pub fn startExceptionHandler(self: *Task) !void {
    const mach_task = try darwin.machTaskForPid(self.process.childPid());
    log.debug("Mach task for pid {d}: {any}", .{ self.process.childPid(), mach_task });
    self.mach_task = mach_task;

    if (mach_task.isValid()) {
        const self_mach_task = darwin.machTaskForSelf();
        const mach_port = try self_mach_task.allocatePort(darwin.MACH_PORT_RIGHT.RECEIVE);
        log.debug("allocated exception port: {any}", .{mach_port});

        try self_mach_task.insertRight(mach_port, darwin.MACH_MSG_TYPE.MAKE_SEND);

        const mach_port_info = try saveExceptionState(mach_task);
        log.debug("saved exception info for task: {any}", .{mach_port_info});

        try mach_task.setExceptionPorts(
            mach_port_info.mask,
            mach_port,
            darwin.EXCEPTION_DEFAULT | darwin.MACH_EXCEPTION_CODES,
            darwin.THREAD_STATE_NONE,
        );
        self.exception_handler = .{
            .mach_port = mach_port,
            .mach_port_info = mach_port_info,
            .thread = undefined,
        };
        self.exception_handler.?.thread = try std.Thread.spawn(.{}, exceptionThreadFn, .{self});
    } else return error.InvalidMachTask;
}

pub fn shutdownExceptionHandler(self: *Task) !void {
    const handler = self.exception_handler orelse unreachable;

    try restoreExceptionState(self.mach_task.?, handler.mach_port_info);
    handler.thread.join();

    const self_mach_task = darwin.machTaskForSelf();
    self_mach_task.deallocatePort(handler.mach_port);

    self.exception_handler = null;
}

fn saveExceptionState(mach_task: darwin.MachTask) !darwin.MachTask.PortInfo {
    // TODO handle different platforms
    return mach_task.getExceptionPorts(darwin.EXC_MASK_ALL);
}

fn restoreExceptionState(mach_task: darwin.MachTask, info: darwin.MachTask.PortInfo) !void {
    if (info.count == 0) return;
    var i: usize = 0;
    while (i < info.count) : (i += 1) {
        try mach_task.setExceptionPorts(
            info.masks[i],
            info.ports[i],
            info.behaviors[i],
            info.flavors[i],
        );
    }
}

fn exceptionThreadFn(task: *Task) void {
    log.debug("task = {*}", .{task});

    const mach_task = task.mach_task.?;
    var num_exceptions_received: u32 = 0;

    while (mach_task.isValid()) {
        var msg = Message.init(task.gpa);

        const err = err: {
            if (num_exceptions_received > 0) {
                msg.receive(
                    task.exception_handler.?.mach_port,
                    darwin.MACH_RCV_MSG | darwin.MACH_RCV_INTERRUPT | darwin.MACH_RCV_TIMEOUT,
                    1,
                    null,
                ) catch |err| break :err err;
            } else {
                msg.receive(
                    task.exception_handler.?.mach_port,
                    darwin.MACH_RCV_MSG | darwin.MACH_RCV_INTERRUPT,
                    0,
                    null,
                ) catch |err| break :err err;
            }

            if (msg.catchExceptionRaise(mach_task)) {
                assert(msg.state.task_port.port == mach_task.port);
                num_exceptions_received += 1;
                task.process.appendExceptionMessage(msg) catch unreachable;
            }
            continue;
        };
        defer msg.deinit();

        switch (err) {
            error.Interrupted => {
                if (!mach_task.isValid()) break;
            },
            error.TimedOut => {
                if (num_exceptions_received > 0) {
                    num_exceptions_received = 0;
                    task.process.notifyExceptionMessageBundleComplete() catch unreachable;

                    if (!mach_task.isValid()) break;
                }
            },
            else => {
                log.err("unexpected error when receiving exceptions: {s}", .{@errorName(err)});
            },
        }
    }
}

pub fn @"resume"(self: Task) !void {
    const mach_task = self.mach_task orelse return;
    const task_info = try mach_task.basicTaskInfo();

    log.debug("resuming task, got task info: {any}", .{task_info});

    if (task_info.suspend_count > 0) {
        try mach_task.@"resume"();
    }
}

pub fn @"suspend"(self: Task) !void {
    const mach_task = self.mach_task orelse return;
    log.debug("suspending task", .{});
    try mach_task.@"suspend"();
}
