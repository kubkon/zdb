const Debuggee = @This();

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.debuggee);

const Allocator = std.mem.Allocator;

arena: std.heap.ArenaAllocator,
process: std.ChildProcess,
task: darwin.MachTask,
exception_port: darwin.MachTask,
exc_port_info: darwin.MachTask.PortInfo,

pub fn deinit(dbg: *Debuggee) void {
    dbg.arena.deinit();

    const self_task = darwin.machTaskForSelf();
    self_task.deallocatePort(dbg.exception_port);
}

pub fn spawn(gpa: Allocator, args: []const []const u8) !Debuggee {
    var dbg = Debuggee{
        .arena = undefined,
        .process = undefined,
        .task = undefined,
        .exception_port = undefined,
        .exc_port_info = undefined,
    };

    dbg.arena = std.heap.ArenaAllocator.init(gpa);
    dbg.process = std.ChildProcess.init(args, dbg.arena.allocator());
    dbg.process.stdin_behavior = .Inherit;
    dbg.process.stdout_behavior = .Inherit;
    dbg.process.stderr_behavior = .Inherit;
    dbg.process.disable_aslr = true;
    dbg.process.start_suspended = true;

    try dbg.process.spawn();
    log.debug("PID: {d}", .{dbg.process.pid});

    try dbg.startExceptionThread();

    try std.os.ptrace.ptrace(darwin.PT_ATTACHEXC, dbg.process.pid);
    log.debug("successfully attached with ptrace", .{});

    return dbg;
}

// fn @"continue"(dbg: Debuggee) !void {
//     try ptrace.ptrace(ptrace.PT_CONTINUE, dbg.process.pid);
// }

pub fn kill(dbg: Debuggee) void {
    std.os.ptrace.ptrace(darwin.PT_KILL, dbg.process.pid) catch {};
}

fn saveExceptionState(task: darwin.MachTask) !darwin.MachTask.PortInfo {
    // TODO handle different platforms
    return task.getExceptionPorts(darwin.EXC_MASK_ALL);
}

fn restoreExceptionState(task: darwin.MachTask, info: darwin.MachTask.PortInfo) !void {
    if (info.count == 0) return;
    var i: usize = 0;
    while (i < info.count) : (i += 1) {
        try task.setExceptionPorts(
            info.masks[i],
            info.ports[i],
            info.behaviors[i],
            info.flavors[i],
        );
    }
}

fn startExceptionThread(dbg: *Debuggee) !void {
    dbg.task = try darwin.machTaskForPid(dbg.process.pid);
    log.debug("Mach task: {any}", .{dbg.task});

    if (dbg.task.isValid()) {
        const self_task = darwin.machTaskForSelf();
        dbg.exception_port = try self_task.allocatePort(darwin.MACH_PORT_RIGHT.RECEIVE);

        log.debug("allocated exception port: {any}", .{dbg.exception_port});

        try self_task.insertRight(dbg.exception_port, darwin.MACH_MSG_TYPE.MAKE_SEND);

        dbg.exc_port_info = try saveExceptionState(dbg.task);
        log.debug("saved exception info for task: {any}", .{dbg.exc_port_info});
    } else return error.InvalidMachTask;
}

fn shutdownExceptionThread(dbg: Debuggee) !void {
    try restoreExceptionState(dbg.task, dbg.exc_port_info);
}
