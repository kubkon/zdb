const std = @import("std");

pub const Target = @This();

allocator: std.mem.Allocator,
pid: std.os.pid_t,

pub fn init(allocator: std.mem.Allocator) !Target {
    return Target{
        .allocator = allocator,
        .pid = undefined,
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
    const pid = try std.os.fork();
    if (pid == 0) { // child
        _ = try ptrace(PTRACE_TRACEME, 0, null, null);

        const argv_buf = try self.allocator.allocSentinel(?[*:0]u8, args.len, null);
        for (args, 0..) |arg, i| argv_buf[i] = (try self.allocator.dupeZ(u8, arg)).ptr;

        _ = std.os.execvpeZ_expandArg0(.expand, argv_buf.ptr[0].?, argv_buf.ptr, @ptrCast([*:null]?[*:0]u8, std.os.environ.ptr)) catch {};
    } else {
        self.pid = pid;
        std.debug.print("{}", .{std.os.waitpid(pid, 0)});
    }
}

pub fn @"suspend"(self: *Target) !void {
    _ = self;
}

pub fn @"resume"(self: *Target) !void {
    _ = try ptrace(PTRACE_CONT, self.pid, null, null);
}

pub fn kill(self: *Target) !void {
    _ = self;
}

const PTRACE_TRACEME = 0;
const PTRACE_PEEKTEXT = 1;
const PTRACE_PEEKDATA = 2;
const PTRACE_PEEKUSR = 3;
const PTRACE_POKETEXT = 4;
const PTRACE_POKEDATA = 5;
const PTRACE_POKEUSR = 6;
const PTRACE_CONT = 7;
const PTRACE_KILL = 8;
const PTRACE_SINGLESTEP = 9;

const PTRACE_ATTACH = 0x10;
const PTRACE_DETACH = 0x11;

pub fn ptrace(request: usize, pid: std.os.pid_t, addr: ?*anyopaque, data: ?*anyopaque) !usize {
    const rc =
        std.os.linux.syscall4(.ptrace, request, @as(usize, @bitCast(u32, pid)), @ptrToInt(addr), @ptrToInt(data));

    return switch (std.os.errno(rc)) {
        .SUCCESS => return @intCast(usize, rc),
        .BUSY => error.Busy,
        .FAULT => error.InvalidAddress,
        .INVAL => error.InvalidArguments,
        .IO => error.InvalidRequest,
        .PERM => error.NoPermission,
        .SRCH => error.NotFound,
        else => |err| return std.os.unexpectedErrno(err),
    };
}

