const std = @import("std");

const LinuxTarget = @import("linux/Target.zig");
const MacosTarget = @import("macos/Target.zig");

pub const Target = @This();

const Impl = switch (@import("builtin").os.tag) {
    .linux => LinuxTarget,
    .macos => MacosTarget,
    else => @compileError("unsupported system"),
};

const Type = enum {
    local,
    remote,
};

// in the future we can make it a pointer and add support for "gdb stub" protocol
impl: Impl,
type: Type = .local,

pub fn init(allocator: std.mem.Allocator) !Target {
    return Target{
        .impl = try Impl.init(allocator),
    };
}

pub fn deinit(self: *Target) void {
    self.impl.deinit();
}

pub fn attach(self: *Target, pid: usize) !void {
    try self.impl.attach(pid);
}

pub fn spawn(self: *Target, args: []const []const u8) !void {
    try self.impl.spawn(args);
}

pub fn @"suspend"(self: *Target) !void {
    try self.impl.@"suspend"();
}

pub fn @"resume"(self: *Target) !void {
    try self.impl.@"resume"();
}

pub fn kill(self: *Target) !void {
    try self.impl.kill();
}
