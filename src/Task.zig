const Task = @This();

const std = @import("std");
const darwin = os.darwin;
const log = std.log.scoped(.task);
const os = std.os;

pid: os.pid_t,
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
    const mach_task = try darwin.machTaskForPid(self.pid);
    log.debug("Mach task for pid {d}: {any}", .{ self.pid, mach_task });
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
    log.warn("task = {*}{any}", .{ task, task.* });
}
