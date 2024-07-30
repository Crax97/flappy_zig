const std = @import("std");

const engine_sdk = @import("engine/build.zig");
// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    const sdk = engine_sdk.setup(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "gamefun",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const check = b.addExecutable(.{
        .name = "gamefun",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sdk.add_to_target(exe);
    sdk.add_to_target(check);
    try setup_compile(exe, b, target);
    try setup_compile(check, b, target);

    // Shaders
    try build_shaders(b, exe);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const check_step = b.step("check", "Check if the application compiles");
    check_step.dependOn(&check.step);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    try setup_compile(unit_tests, b, target);
    unit_tests.linkLibC();
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    test_step.dependOn(&run_unit_tests.step);
}

fn setup_compile(exe: *std.Build.Step.Compile, b: *std.Build, target: std.Build.ResolvedTarget) !void {

    // Freetype
    const b_freetype = b.dependency("freetype", .{});
    exe.linkLibrary(b_freetype.artifact("freetype"));
    exe.addIncludePath(.{ .cwd_relative = "thirdparty/zig-freetype/include" });

    _ = target;
}

fn build_shaders(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    const base_rel_path = "engine/renderer/shaders";
    const out_dir = "engine/renderer/spirv";
    const iterator = try b.build_root.handle.openDir(base_rel_path, .{ .iterate = true });
    var it = iterator.iterate();

    while (try it.next()) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            const full_path = try std.fs.path.join(b.allocator, &.{ base_rel_path, entry.name });
            if (is_shader_ext_valid(ext)) {
                std.debug.print("Compiling {s}\n", .{full_path});

                add_shader(b, exe, out_dir, full_path);
            }
        }
    }
}

fn is_shader_ext_valid(ext: []const u8) bool {
    const valid_exts = [3][]const u8{ ".vert", ".frag", ".comp" };

    for (valid_exts) |ve| {
        if (std.mem.eql(u8, ve, ext)) {
            return true;
        }
    }
    return false;
}

fn add_shader(b: *std.Build, exe: *std.Build.Step.Compile, out_dir: []const u8, full_path: []const u8) void {
    const name = std.fs.path.basename(full_path);
    const outpath = std.fmt.allocPrint(b.allocator, "{s}/{s}.spv", .{ out_dir, name }) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    shader_compilation.addArg(outpath);
    shader_compilation.addArg(full_path);
    exe.step.dependOn(&shader_compilation.step);
}
