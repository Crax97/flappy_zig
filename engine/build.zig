const std = @import("std");

fn sdk_path(comptime path: []const u8) []const u8 {
    const src = @src();
    const source = comptime std.fs.path.dirname(src.file) orelse ".";
    return source ++ path;
}

fn build_core_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.addModule("core", .{
        .root_source_file = .{ .cwd_relative = sdk_path("/core/main.zig") },
        .target = target,
        .optimize = optimize,
    });
}

fn build_math_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.addModule("math", .{
        .root_source_file = .{ .cwd_relative = sdk_path("/math/main.zig") },
        .target = target,
        .optimize = optimize,
    });
}

fn build_ecs_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_module: *std.Build.Module) *std.Build.Module {
    const ecs = b.addModule("math", .{
        .root_source_file = .{ .cwd_relative = sdk_path("/ecs/main.zig") },
        .target = target,
        .optimize = optimize,
    });

    ecs.addImport("core", core_module);

    return ecs;
}

pub const EngineSdk = struct {
    core_module: *std.Build.Module,
    math_module: *std.Build.Module,
    ecs_module: *std.Build.Module,

    pub fn add_to_target(this: *const EngineSdk, compile: *std.Build.Step.Compile) void {
        compile.root_module.addImport("core", this.core_module);
        compile.root_module.addImport("math", this.math_module);
        compile.root_module.addImport("ecs", this.ecs_module);
    }
};

pub fn setup(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) EngineSdk {
    const core_module = build_core_module(b, target, optimize);
    const math_module = build_math_module(b, target, optimize);
    const ecs_module = build_ecs_module(b, target, optimize, core_module);

    return .{
        .core_module = core_module,
        .math_module = math_module,
        .ecs_module = ecs_module,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdk = setup(b, target, optimize);
    const test_step = b.step("test", "Run unit tests");

    add_test(b, &sdk, test_step, "core/main.zig", target, optimize);
    add_test(b, &sdk, test_step, "math/main.zig", target, optimize);
    add_test(b, &sdk, test_step, "ecs/main.zig", target, optimize);
}

fn add_test(b: *std.Build, sdk: *const EngineSdk, step: *std.Build.Step, comptime source: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const core_unit_tests = b.addTest(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });

    sdk.add_to_target(core_unit_tests);

    core_unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(core_unit_tests);

    step.dependOn(&run_unit_tests.step);
}
