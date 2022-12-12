const Message = @import("Message.zig");

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.message);
const mem = std.mem;

const Allocator = mem.Allocator;

exception_msg: MachMessage,
reply_msg: MachMessage,
state: Data,

extern "c" fn mach_exc_server(in_hdr: ?*darwin.mach_msg_header_t, out_hdr: ?*darwin.mach_msg_header_t) darwin.boolean_t;

const MachMessage = extern union {
    hdr: darwin.mach_msg_header_t,
    data: [1024]u8,
};

pub const empty = Message{
    .exception_msg = undefined,
    .reply_msg = undefined,
    .state = Data.empty,
};

pub const Data = struct {
    task_port: darwin.MachTask,
    thread_port: darwin.MachTask,
    exception_type: darwin.EXC,
    exception_data: std.ArrayListUnmanaged(darwin.mach_exception_data_type_t) = .{},

    pub const empty = Data{
        .task_port = .{ .port = darwin.TASK_NULL },
        .thread_port = .{ .port = darwin.THREAD_NULL },
        .exception_type = .NULL,
    };

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
            (data.exception_type == .SOFTWARE and data.exception_data[0] == 1);
    }

    pub fn appendExceptionData(
        data: *Data,
        gpa: Allocator,
        in_data: darwin.mach_exception_data_t,
        count: darwin.mach_msg_type_number_t,
    ) error{OutOfMemory}!void {
        try data.exception_data.ensureUnusedCapacity(gpa);
        var buf: [@sizeOf(darwin.mach_exception_data_type_t)]u8 = undefined;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const ptr = @intToPtr(*const u8, in_data) + i;
            mem.copy(u8, &buf, ptr);
            data.exception_data.appendAssumeCapacity(
                @ptrCast(*align(1) const darwin.mach_exception_data_type_t, &buf).*,
            );
        }
    }
};

var global_msg: ?*Data = null;

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
