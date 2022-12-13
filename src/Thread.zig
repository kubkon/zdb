const Thread = @import("Thread.zig");

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.thread);
const mem = std.mem;

const Allocator = mem.Allocator;
const Message = @import("Message.zig");

guid: u64,
port: darwin.MachThread,

state: enum {
    stopped,
    suspended,
    running,
    stepping,
} = .running,

stop_exception: ?Message.Data = null,

pub fn didStop(thread: *Thread) !void {
    log.debug("didStop({*})", .{thread});
    const info = try thread.port.getBasicInfo();
    log.debug("  (suspend count {d})", .{info.suspend_count});
    if (info.suspend_count > 0) {
        thread.state = .suspended;
    } else {
        thread.state = .stopped;
    }
}

pub fn notifyException(thread: *Thread, exception: Message.Data) !void {
    switch (exception.exception_type) {
        .BREAKPOINT => {
            // TODO
        },
        else => {},
    }

    const curr_exc = thread.stop_exception orelse {
        thread.stop_exception = exception;
        return;
    };
    if (curr_exc.isValid()) {
        if (curr_exc.isBreakpoint()) {
            thread.stop_exception = exception;
        }
    } else {
        thread.stop_exception = exception;
    }
}
