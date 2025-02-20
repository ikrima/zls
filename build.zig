const std = @import("std");
const builtin = @import("builtin");
const shared = @import("src/shared.zig");

const zls_version = std.builtin.Version{ .major = 0, .minor = 10, .patch = 0 };

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});

    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zls", "src/main.zig");
    exe.use_stage1 = true;
    const exe_options = b.addOptions();
    exe.addOptions("build_options", exe_options);

    exe_options.addOption(
        shared.ZigVersion,
        "data_version",
        b.option(shared.ZigVersion, "data_version", "The Zig version your compiler is.") orelse .master,
    );

    exe_options.addOption(
        std.log.Level,
        "log_level",
        b.option(std.log.Level, "log_level", "The Log Level to be used.") orelse .info,
    );

    const enable_tracy = b.option(bool, "enable_tracy", "Whether tracy should be enabled.") orelse false;

    exe_options.addOption(
        bool,
        "enable_tracy",
        enable_tracy,
    );

    exe_options.addOption(
        bool,
        "enable_tracy_allocation",
        b.option(bool, "enable_tracy_allocation", "Enable using TracyAllocator to monitor allocations.") orelse false,
    );

    exe_options.addOption(
        bool,
        "enable_tracy_callstack",
        b.option(bool, "enable_tracy_callstack", "Enable callstack graphs.") orelse false,
    );

    const version = v: {
        const version_string = b.fmt("{d}.{d}.{d}", .{ zls_version.major, zls_version.minor, zls_version.patch });

        var code: u8 = undefined;
        const git_describe_untrimmed = b.execAllowFail(&[_][]const u8{
            "git", "-C", b.build_root, "describe", "--match", "*.*.*", "--tags",
        }, &code, .Ignore) catch break :v version_string;

        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.count(u8, git_describe, "-")) {
            0 => {
                // Tagged release version (e.g. 0.10.0).
                std.debug.assert(std.mem.eql(u8, git_describe, version_string)); // tagged release must match version string
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.216+34ce200).
                var it = std.mem.split(u8, git_describe, "-");
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.builtin.Version.parse(tagged_ancestor);
                std.debug.assert(zls_version.order(ancestor_ver) == .gt); // zls version must be greater than its previous version
                std.debug.assert(std.mem.startsWith(u8, commit_id, "g")); // commit hash is prefixed with a 'g'

                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
                std.process.exit(1);
            },
        }
    };

    exe_options.addOption([:0]const u8, "version", try b.allocator.dupeZ(u8, version));

    const KNOWN_FOLDERS_DEFAULT_PATH = "src/known-folders/known-folders.zig";
    const known_folders_path = b.option([]const u8, "known-folders", "Path to known-folders package (default: " ++ KNOWN_FOLDERS_DEFAULT_PATH ++ ")") orelse KNOWN_FOLDERS_DEFAULT_PATH;
    exe.addPackage(.{ .name = "known-folders", .source = .{ .path = known_folders_path } });

    if (enable_tracy) {
        const client_cpp = "src/tracy/TracyClient.cpp";

        // On mingw, we need to opt into windows 7+ to get some features required by tracy.
        const tracy_c_flags: []const []const u8 = if (target.isWindows() and target.getAbi() == .gnu)
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addIncludePath("src/tracy");
        exe.addCSourceFile(client_cpp, tracy_c_flags);
        exe.linkSystemLibraryName("c++");
        exe.linkLibC();

        if (target.isWindows()) {
            exe.linkSystemLibrary("dbghelp");
            exe.linkSystemLibrary("ws2_32");
        }
    }

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(b.getInstallStep());

    var tests = b.addTest("tests/tests.zig");
    tests.use_stage1 = true;
    tests.addPackage(.{ .name = "zls", .source = .{ .path = "src/zls.zig" }, .dependencies = exe.packages.items });
    tests.addPackage(.{ .name = "helper", .source = .{ .path = "tests/helper.zig" } });
    tests.addPackage(.{ .name = "context", .source = .{ .path = "tests/context.zig" } });
    tests.setBuildMode(.Debug);
    tests.setTarget(target);
    test_step.dependOn(&tests.step);
}
