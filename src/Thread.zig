const Thread = @import("Thread.zig");

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.thread);
const mem = std.mem;

const Allocator = mem.Allocator;

guid: u64,
port: darwin.ThreadId,

state: enum {
    stopped,
    suspended,
    running,
    stepping,
} = .running,

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
