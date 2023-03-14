const Process = @This();

const std = @import("std");
const log = std.log.scoped(.process);
const mem = std.mem;
const os = std.os;

const Allocator = mem.Allocator;
const MacosProcess = @import("macos/Process.zig");

gpa: Allocator,
arena: std.heap.ArenaAllocator,
child_pid: os.pid_t,
tag: Tag,

pub const Tag = enum {
    macos,
};

pub fn new(gpa: Allocator, tag: Tag) !*Process {
    var arena = std.heap.ArenaAllocator.init(gpa);
    return switch (tag) {
        .macos => &(try MacosProcess.new(gpa, arena)).base,
    };
}

pub fn deinit(base: *Process) void {
    switch (base.tag) {
        .macos => @fieldParentPtr(MacosProcess, "base", base).deinit(),
    }
    base.arena.deinit();
    base.gpa.destroy(base);
}

pub fn spawn(base: *Process, args: []const []const u8) !void {
    return switch (base.tag) {
        .macos => @fieldParentPtr(MacosProcess, "base", base).spawn(args),
    };
}

pub fn @"resume"(base: *Process) !void {
    return switch (base.tag) {
        .macos => @fieldParentPtr(MacosProcess, "base", base).@"resume"(),
    };
}

pub fn kill(base: *Process) void {
    switch (base.tag) {
        .macos => @fieldParentPtr(MacosProcess, "base", base).kill(),
    }
}
