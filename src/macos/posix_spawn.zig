const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const system = os.system;
const errno = system.getErrno;
const fd_t = system.fd_t;
const mode_t = system.mode_t;
const pid_t = system.pid_t;
const unexpectedErrno = os.unexpectedErrno;
const UnexpectedError = os.UnexpectedError;
const toPosixPath = os.toPosixPath;
const WaitPidResult = os.WaitPidResult;

pub const Error = error{
    SystemResources,
    InvalidFileDescriptor,
    NameTooLong,
    TooBig,
    PermissionDenied,
    InputOutput,
    FileSystem,
    FileNotFound,
    InvalidExe,
    NotDir,
    FileBusy,
    /// Returned when the child fails to execute either in the pre-exec() initialization step, or
    /// when exec(3) is invoked.
    ChildExecFailed,
} || UnexpectedError;

pub const Attr = struct {
    attr: system.posix_spawnattr_t,

    pub fn init() Error!Attr {
        var attr: system.posix_spawnattr_t = undefined;
        switch (errno(system.posix_spawnattr_init(&attr))) {
            .SUCCESS => return Attr{ .attr = attr },
            .NOMEM => return error.SystemResources,
            .INVAL => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn deinit(self: *Attr) void {
        defer self.* = undefined;
        switch (errno(system.posix_spawnattr_destroy(&self.attr))) {
            .SUCCESS => return,
            .INVAL => unreachable, // Invalid parameters.
            else => unreachable,
        }
    }

    pub fn get(self: Attr) Error!u16 {
        var flags: c_short = undefined;
        switch (errno(system.posix_spawnattr_getflags(&self.attr, &flags))) {
            .SUCCESS => return @bitCast(u16, flags),
            .INVAL => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn set(self: *Attr, flags: u16) Error!void {
        switch (errno(system.posix_spawnattr_setflags(&self.attr, @bitCast(c_short, flags)))) {
            .SUCCESS => return,
            .INVAL => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
};

pub const Actions = struct {
    actions: system.posix_spawn_file_actions_t,

    pub fn init() Error!Actions {
        var actions: system.posix_spawn_file_actions_t = undefined;
        switch (errno(system.posix_spawn_file_actions_init(&actions))) {
            .SUCCESS => return Actions{ .actions = actions },
            .NOMEM => return error.SystemResources,
            .INVAL => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn deinit(self: *Actions) void {
        defer self.* = undefined;
        switch (errno(system.posix_spawn_file_actions_destroy(&self.actions))) {
            .SUCCESS => return,
            .INVAL => unreachable, // Invalid parameters.
            else => unreachable,
        }
    }

    pub fn open(self: *Actions, fd: fd_t, path: []const u8, flags: u32, mode: mode_t) Error!void {
        const posix_path = try toPosixPath(path);
        return self.openZ(fd, &posix_path, flags, mode);
    }

    pub fn openZ(self: *Actions, fd: fd_t, path: [*:0]const u8, flags: u32, mode: mode_t) Error!void {
        switch (errno(system.posix_spawn_file_actions_addopen(&self.actions, fd, path, @bitCast(c_int, flags), mode))) {
            .SUCCESS => return,
            .BADF => return error.InvalidFileDescriptor,
            .NOMEM => return error.SystemResources,
            .NAMETOOLONG => return error.NameTooLong,
            .INVAL => unreachable, // the value of file actions is invalid
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn close(self: *Actions, fd: fd_t) Error!void {
        switch (errno(system.posix_spawn_file_actions_addclose(&self.actions, fd))) {
            .SUCCESS => return,
            .BADF => return error.InvalidFileDescriptor,
            .NOMEM => return error.SystemResources,
            .INVAL => unreachable, // the value of file actions is invalid
            .NAMETOOLONG => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn dup2(self: *Actions, fd: fd_t, newfd: fd_t) Error!void {
        switch (errno(system.posix_spawn_file_actions_adddup2(&self.actions, fd, newfd))) {
            .SUCCESS => return,
            .BADF => return error.InvalidFileDescriptor,
            .NOMEM => return error.SystemResources,
            .INVAL => unreachable, // the value of file actions is invalid
            .NAMETOOLONG => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn inherit(self: *Actions, fd: fd_t) Error!void {
        switch (errno(system.posix_spawn_file_actions_addinherit_np(&self.actions, fd))) {
            .SUCCESS => return,
            .BADF => return error.InvalidFileDescriptor,
            .NOMEM => return error.SystemResources,
            .INVAL => unreachable, // the value of file actions is invalid
            .NAMETOOLONG => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn chdir(self: *Actions, path: []const u8) Error!void {
        const posix_path = try toPosixPath(path);
        return self.chdirZ(&posix_path);
    }

    pub fn chdirZ(self: *Actions, path: [*:0]const u8) Error!void {
        switch (errno(system.posix_spawn_file_actions_addchdir_np(&self.actions, path))) {
            .SUCCESS => return,
            .NOMEM => return error.SystemResources,
            .NAMETOOLONG => return error.NameTooLong,
            .BADF => unreachable,
            .INVAL => unreachable, // the value of file actions is invalid
            else => |err| return unexpectedErrno(err),
        }
    }

    pub fn fchdir(self: *Actions, fd: fd_t) Error!void {
        switch (errno(system.posix_spawn_file_actions_addfchdir_np(&self.actions, fd))) {
            .SUCCESS => return,
            .BADF => return error.InvalidFileDescriptor,
            .NOMEM => return error.SystemResources,
            .INVAL => unreachable, // the value of file actions is invalid
            .NAMETOOLONG => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
};

pub fn spawn(
    path: []const u8,
    actions: ?Actions,
    attr: ?Attr,
    argv: [*:null]?[*:0]const u8,
    envp: [*:null]?[*:0]const u8,
) Error!pid_t {
    const posix_path = try toPosixPath(path);
    return spawnZ(&posix_path, actions, attr, argv, envp);
}

pub fn spawnZ(
    path: [*:0]const u8,
    actions: ?Actions,
    attr: ?Attr,
    argv: [*:null]?[*:0]const u8,
    envp: [*:null]?[*:0]const u8,
) Error!pid_t {
    var pid: pid_t = undefined;
    switch (errno(system.posix_spawn(
        &pid,
        path,
        if (actions) |a| &a.actions else null,
        if (attr) |a| &a.attr else null,
        argv,
        envp,
    ))) {
        .SUCCESS => return pid,
        .@"2BIG" => return error.TooBig,
        .NOMEM => return error.SystemResources,
        .BADF => return error.InvalidFileDescriptor,
        .ACCES => return error.PermissionDenied,
        .IO => return error.InputOutput,
        .LOOP => return error.FileSystem,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOEXEC => return error.InvalidExe,
        .NOTDIR => return error.NotDir,
        .TXTBSY => return error.FileBusy,
        .BADARCH => return error.InvalidExe,
        .BADEXEC => return error.InvalidExe,
        .FAULT => unreachable,
        .INVAL => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn waitpid(pid: pid_t, flags: u32) Error!WaitPidResult {
    const Status = if (builtin.link_libc) c_int else u32;
    var status: Status = undefined;
    while (true) {
        const rc = system.waitpid(pid, &status, if (builtin.link_libc) @intCast(c_int, flags) else flags);
        switch (errno(rc)) {
            .SUCCESS => return WaitPidResult{
                .pid = @intCast(pid_t, rc),
                .status = @bitCast(u32, status),
            },
            .INTR => continue,
            .CHILD => return error.ChildExecFailed,
            .INVAL => unreachable, // Invalid flags.
            else => unreachable,
        }
    }
}
