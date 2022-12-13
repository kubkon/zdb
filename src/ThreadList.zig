const ThreadList = @import("ThreadList.zig");

const std = @import("std");
const darwin = std.os.darwin;
const log = std.log.scoped(.thread_list);
const mem = std.mem;

const Allocator = mem.Allocator;
const Process = @import("Process.zig");

threads: std.ArrayListUnmanaged(Thread) = .{},
threads_mutex: std.Thread.Mutex = .{},

pub const Thread = struct {};

pub fn deinit(list: *ThreadList, gpa: Allocator) void {
    list.threads.deinit(gpa);
}

pub fn processDidStop(list: *ThreadList, gpa: Allocator, process: *Process) !void {
    try list.update(gpa, process, true);
    // for (list.threads.items) |*thread| {
    //     thread.didStop();
    // }
}

pub fn update(list: *ThreadList, gpa: Allocator, process: *Process, should_update: bool) !void {
    _ = gpa;

    list.threads_mutex.lock();
    defer list.threads_mutex.unlock();

    if (list.threads.items.len == 0 or should_update) {
        const curr_threads = try process.task.mach_task.?.getThreads();
        for (curr_threads) |thr| {
            log.debug("thr = {}", .{thr});
        }
    }
}
