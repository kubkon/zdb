const Message = @import("Message.zig");

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.message);
const mem = std.mem;

const Allocator = mem.Allocator;
const Process = @import("Process.zig");

exception_msg: MachMessage,
reply_msg: MachMessage,
state: Data,

extern "c" fn mach_exc_server(in_hdr: ?*darwin.mach_msg_header_t, out_hdr: ?*darwin.mach_msg_header_t) darwin.boolean_t;

export fn catch_mach_exception_raise_state(
    exc_port: darwin.mach_port_t,
    exc_type: darwin.exception_type_t,
    exc_data: darwin.mach_exception_data_t,
    exc_data_count: darwin.mach_msg_type_number_t,
    flavor: *c_int,
    old_state: darwin.thread_state_t,
    old_state_cnt: darwin.mach_msg_type_number_t,
    new_state: darwin.thread_state_t,
    new_state_cnt: *darwin.mach_msg_type_number_t,
) darwin.kern_return_t {
    _ = exc_port;
    _ = exc_type;
    _ = exc_data;
    _ = exc_data_count;
    _ = flavor;
    _ = old_state;
    _ = old_state_cnt;
    _ = new_state;
    _ = new_state_cnt;
    return @enumToInt(darwin.KernE.FAILURE);
}

export fn catch_mach_exception_raise_state_identity(
    exc_port: darwin.mach_port_t,
    thread_port: darwin.mach_port_t,
    task_port: darwin.mach_port_t,
    exc_type: darwin.exception_type_t,
    exc_data: darwin.mach_exception_data_t,
    exc_data_count: darwin.mach_msg_type_number_t,
    flavor: *c_int,
    old_state: darwin.thread_state_t,
    old_state_cnt: darwin.mach_msg_type_number_t,
    new_state: darwin.thread_state_t,
    new_state_cnt: darwin.mach_msg_type_number_t,
) darwin.kern_return_t {
    _ = exc_port;
    _ = thread_port;
    _ = task_port;
    _ = exc_type;
    _ = exc_data;
    _ = exc_data_count;
    _ = flavor;
    _ = old_state;
    _ = old_state_cnt;
    _ = new_state;
    _ = new_state_cnt;
    return @enumToInt(darwin.KernE.FAILURE);
}

export fn catch_mach_exception_raise(
    exc_port: darwin.mach_port_t,
    thread_port: darwin.mach_port_t,
    task_port: darwin.mach_port_t,
    exc_type: darwin.exception_type_t,
    exc_data: darwin.mach_exception_data_t,
    exc_data_count: darwin.mach_msg_type_number_t,
) darwin.kern_return_t {
    _ = exc_port;

    const msg = global_msg orelse return @enumToInt(darwin.KernE.FAILURE);
    msg.exception_type = .NULL;
    msg.exception_data.clearRetainingCapacity();

    if (task_port == msg.task_port.port) {
        msg.task_port = .{ .port = task_port };
        msg.thread_port = .{ .port = thread_port };
        msg.exception_type = @intToEnum(darwin.EXC, exc_type);
        msg.appendExceptionData(exc_data, exc_data_count) catch return @enumToInt(darwin.KernE.FAILURE);
        return @enumToInt(darwin.KernE.SUCCESS);
    }

    // TODO handle port changes
    return @enumToInt(darwin.KernE.FAILURE);
}

var global_msg: ?*Data = null;

const MachMessage = extern union {
    hdr: darwin.mach_msg_header_t,
    data: [1024]u8,
};

pub fn init(gpa: Allocator) Message {
    return .{
        .exception_msg = undefined,
        .reply_msg = undefined,
        .state = Data.init(gpa),
    };
}

pub fn deinit(msg: *Message) void {
    msg.state.deinit();
}

pub const Data = struct {
    task_port: darwin.MachTask,
    thread_port: darwin.MachThread,
    exception_type: darwin.EXC,
    exception_data: std.ArrayList(darwin.mach_exception_data_type_t),

    pub fn init(gpa: Allocator) Data {
        return .{
            .task_port = .{ .port = darwin.TASK_NULL },
            .thread_port = .{ .port = darwin.THREAD_NULL },
            .exception_type = .NULL,
            .exception_data = std.ArrayList(darwin.mach_exception_data_type_t).init(gpa),
        };
    }

    pub fn deinit(data: *Data) void {
        data.exception_data.deinit();
    }

    pub fn getSoftSignal(data: Data) ?i32 {
        if (data.exception_type == .SOFTWARE and
            data.exception_data.items.len == 2 and
            data.exception_data.items[0] == darwin.EXC_SOFT_SIGNAL)
        {
            return @intCast(i32, data.exception_data.items[1]);
        }
        return null;
    }

    pub fn isBreakpoint(data: Data) bool {
        return data.exception_type == .BREAKPOINT or
            (data.exception_type == .SOFTWARE and data.exception_data.items[0] == 1);
    }

    pub fn isValid(data: Data) bool {
        return data.task_port.isValid() and data.thread_port.isValid() and data.exception_type != .NULL;
    }

    pub fn appendExceptionData(
        data: *Data,
        in_data: darwin.mach_exception_data_t,
        count: darwin.mach_msg_type_number_t,
    ) error{OutOfMemory}!void {
        try data.exception_data.ensureUnusedCapacity(count);
        var buf: [@sizeOf(darwin.mach_exception_data_type_t)]u8 = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const ptr = @intToPtr([*]const u8, @ptrToInt(in_data.?)) + i * @sizeOf(darwin.mach_exception_data_t);
            mem.copy(u8, &buf, ptr[0..buf.len]);
            data.exception_data.appendAssumeCapacity(
                @ptrCast(*align(1) const darwin.mach_exception_data_type_t, &buf).*,
            );
        }
    }
};

pub fn catchExceptionRaise(msg: *Message, task: darwin.MachTask) bool {
    msg.state.task_port = task;
    global_msg = &msg.state;
    const success = mach_exc_server(&msg.exception_msg.hdr, &msg.reply_msg.hdr) == 1;
    global_msg = null;
    return success;
}

pub fn receive(
    msg: *Message,
    port: darwin.MachTask,
    options: darwin.mach_msg_option_t,
    timeout: darwin.mach_msg_timeout_t,
    notify_port: ?darwin.MachTask,
) !void {
    const actual_timeout = if (options & darwin.MACH_RCV_TIMEOUT != 0) timeout else 0;

    switch (darwin.getMachMsgError(darwin.mach_msg(
        &msg.exception_msg.hdr,
        options,
        0,
        msg.exception_msg.data.len,
        port.port,
        actual_timeout,
        if (notify_port) |p| p.port else darwin.TASK_NULL,
    ))) {
        .SUCCESS => {},
        .RCV_INTERRUPTED => return error.Interrupted,
        .RCV_TIMED_OUT => return error.TimedOut,
        else => |err| {
            log.err("mach_msg failed with error: {s}", .{@tagName(err)});
            return error.Unexpected;
        },
    }
}

pub fn reply(msg: *Message, process: *Process, signal: i32) !void {
    if (msg.state.getSoftSignal()) |soft_signal| {
        var actual_signal = soft_signal;
        const state_pid = if (process.task.mach_task.?.port == msg.state.task_port.port) blk: {
            actual_signal = signal;
            break :blk process.child_pid;
        } else try msg.state.task_port.pidForTask();

        try std.os.ptrace.ptrace(
            darwin.PT_THUPDATE,
            state_pid,
            @intToPtr([*]u8, msg.state.thread_port.port),
            soft_signal,
        );
    }

    switch (darwin.getMachMsgError(darwin.mach_msg(
        &msg.reply_msg.hdr,
        darwin.MACH_SEND_MSG | darwin.MACH_SEND_INTERRUPT,
        msg.reply_msg.hdr.msgh_size,
        0,
        darwin.MACH_PORT_NULL,
        darwin.MACH_MSG_TIMEOUT_NONE,
        darwin.MACH_PORT_NULL,
    ))) {
        .SUCCESS => {},
        .SEND_INTERRUPTED => return error.Interrupted,
        else => |err| {
            log.err("mach_msg failed with error: {s}", .{@tagName(err)});
            return error.Unexpected;
        },
    }
}
