const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mem = std.mem;

const Zdb = @import("Zdb.zig");

const usage =
    \\zdb [file] [options]
    \\
    \\General options:
    \\ --debug-log [scope]     Enable logging of [scope] logs
;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = general_purpose_allocator.allocator();

var log_scopes: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(gpa);

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Hide debug messages unless:
    // * logging enabled with `-Dlog`.
    // * the --debug-log arg for the scope has been provided
    if (@enumToInt(level) > @enumToInt(std.log.level) or
        @enumToInt(level) > @enumToInt(std.log.Level.info))
    {
        if (!build_options.enable_logging) return;

        const scope_name = @tagName(scope);
        for (log_scopes.items) |log_scope| {
            if (mem.eql(u8, log_scope, scope_name)) break;
        } else return;
    }

    // We only recognize 4 log levels in this application.
    const level_txt = switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
    const prefix1 = level_txt;
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    ret: {
        const msg = std.fmt.allocPrint(gpa, format, args) catch break :ret;
        std.io.getStdErr().writeAll(msg) catch {};
    }
    std.process.exit(1);
}

pub fn main() !void {
    const all_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, all_args);

    doMain(all_args[1..]) catch |err| fatal("unexpected error: {s}", .{@errorName(err)});
}

fn doMain(args: []const []const u8) !void {
    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var argv = std.ArrayList([]const u8).init(arena);

    const ArgsIterator = struct {
        args: []const []const u8,
        i: usize = 0,
        fn next(it: *@This()) ?[]const u8 {
            if (it.i >= it.args.len) {
                return null;
            }
            defer it.i += 1;
            return it.args[it.i];
        }
    };

    var args_iter = ArgsIterator{ .args = args };

    while (args_iter.next()) |arg| {
        if (mem.eql(u8, arg, "--debug-log")) {
            const scope = args_iter.next() orelse fatal("expected log scope after {s}", .{arg});
            try log_scopes.append(scope);
        } else try argv.append(arg);
    }

    var zdb = Zdb.init(gpa, .{
        .args = argv.items,
    });
    defer zdb.deinit();
    try zdb.loop();
}
