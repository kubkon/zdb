const std = @import("std");

pub const Target = @This();

pub fn init(allocator: std.mem.Allocator) !Target {
    _ = allocator;
    return Target{
    };
}

pub fn deinit(self: *Target) void {
    _ = self;
}

pub fn attach(self: *Target, pid: usize) !void {
    _ = self;
    _ = pid;
}

pub fn spawn(self: *Target, args: []const []const u8) !void {
    _ = self;
    _ = args;
}

pub fn @"suspend"(self: *Target) !void {
    _ = self;
}

pub fn @"resume"(self: *Target) !void {
    _ = self;
}

pub fn kill(self: *Target) !void {
    _ = self;
}


