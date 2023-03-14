const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const enable_logging = b.option(bool, "log", "Whether to enable logging") orelse false;

    const exe = b.addExecutable(.{
        .name = "zdb",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });

    switch (target.getOsTag()) {
        .macos => {
            exe.addCSourceFiles(&.{
                "src/macos/mach_excUser.c",
                "src/macos/mach_excServer.c",
            }, &[0][]const u8{});
            exe.addIncludePath("src");
            exe.entitlements = "resources/Info.plist";
        },
        else => {},
    }
    exe.install();

    const exe_opts = b.addOptions();
    exe.addOptions("build_options", exe_opts);
    exe_opts.addOption(bool, "enable_logging", enable_logging);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
