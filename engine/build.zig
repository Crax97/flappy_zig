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
    const ecs = b.addModule("ecs", .{
        .root_source_file = .{ .cwd_relative = sdk_path("/ecs/main.zig") },
        .target = target,
        .optimize = optimize,
    });

    ecs.addImport("core", core_module);

    return ecs;
}

fn build_renderer_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_module: *std.Build.Module, math_module: *std.Build.Module) *std.Build.Module {
    const renderer = b.addModule("renderer", .{
        .root_source_file = .{ .cwd_relative = sdk_path("/renderer/main.zig") },
        .target = target,
        .optimize = optimize,
    });
    renderer.link_libc = true;
    renderer.link_libcpp = true;

    const env_map = std.process.getEnvMap(b.allocator) catch @panic("OOM");

    // STB
    renderer.addIncludePath(.{ .cwd_relative = "thirdparty/stb" });
    renderer.addCSourceFile(.{ .file = .{ .cwd_relative = sdk_path("/cpp/stb_image.cpp") } });

    // SDL
    renderer.addIncludePath(.{ .cwd_relative = "thirdparty/sdl/include" });
    renderer.linkSystemLibrary("SDL2", .{});

    if (target.result.os.tag == .windows) {
        renderer.addLibraryPath(b.path("thirdparty/sdl/x86_64-w64/bin/"));
        renderer.addLibraryPath(b.path("thirdparty/sdl/x86_64-w64/lib/"));
        b.installBinFile("thirdparty/sdl/x86_64-w64/bin/SDL2.dll", "SDL2.dll");
    }

    // Vulkan
    const vk_lib_name = if (target.result.os.tag == .windows) "vulkan-1" else "vulkan";
    renderer.linkSystemLibrary(vk_lib_name, .{});
    if (env_map.get("VULKAN_SDK")) |path| {
        renderer.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{path}) catch @panic("OOM") });
        renderer.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/include", .{path}) catch @panic("OOM") });
    }

    // VMA
    renderer.addIncludePath(.{ .cwd_relative = "thirdparty/vma/include" });
    renderer.addCSourceFile(.{ .file = .{ .cwd_relative = sdk_path("/cpp/vma.cpp") } });

    // OpenAL
    renderer.addIncludePath(.{ .cwd_relative = "thirdparty/openal/include/" });
    if (target.result.os.tag == .windows) {
        // For now only x64 is supported
        renderer.addLibraryPath(b.path("thirdparty/openal/libs/Win64/"));
        b.installBinFile("thirdparty/openal/bin/Win64/soft_oal.dll", "OpenAL32.dll");

        renderer.linkSystemLibrary("openal32", .{});
    } else if (target.result.os.tag == .linux) {
        renderer.linkSystemLibrary("openal", .{});
    }

    renderer.addImport("core", core_module);
    renderer.addImport("math", math_module);

    return renderer;
}

fn build_engine_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_module: *std.Build.Module, math_module: *std.Build.Module, ecs_module: *std.Build.Module, renderer_module: *std.Build.Module) *std.Build.Module {
    const engine = b.addModule("engine", .{
        .root_source_file = .{ .cwd_relative = sdk_path("/engine/engine.zig") },
        .target = target,
        .optimize = optimize,
    });

    // Freetype
    const b_freetype = b.dependency("freetype", .{});
    engine.linkLibrary(b_freetype.artifact("freetype"));
    engine.addIncludePath(.{ .cwd_relative = "thirdparty/zig-freetype/include" });

    engine.addImport("core", core_module);
    engine.addImport("math", math_module);
    engine.addImport("ecs", ecs_module);
    engine.addImport("renderer", renderer_module);

    return engine;
}

pub const EngineSdk = struct {
    core_module: *std.Build.Module,
    math_module: *std.Build.Module,
    ecs_module: *std.Build.Module,
    renderer_module: *std.Build.Module,
    engine_module: *std.Build.Module,

    pub fn add_to_target(this: *const EngineSdk, compile: *std.Build.Step.Compile) void {
        compile.root_module.addImport("core", this.core_module);
        compile.root_module.addImport("math", this.math_module);
        compile.root_module.addImport("ecs", this.ecs_module);
        compile.root_module.addImport("renderer", this.renderer_module);
        compile.root_module.addImport("engine", this.engine_module);
    }
};

pub fn setup(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) EngineSdk {
    const core_module = build_core_module(b, target, optimize);
    const math_module = build_math_module(b, target, optimize);
    const ecs_module = build_ecs_module(b, target, optimize, core_module);
    const renderer_module = build_renderer_module(b, target, optimize, core_module, math_module);
    const engine_module = build_engine_module(b, target, optimize, core_module, math_module, ecs_module, renderer_module);

    return .{
        .core_module = core_module,
        .math_module = math_module,
        .ecs_module = ecs_module,
        .renderer_module = renderer_module,
        .engine_module = engine_module,
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
    add_test(b, &sdk, test_step, "renderer/main.zig", target, optimize);
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
