const std = @import("std");

// fn sdk_path(comptime path: []const u8) []const u8 {
//     const src = @src();
//     const source = comptime std.fs.path.dirname(src.file) orelse ".";
//     return source ++ path;
// }

fn build_core_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.addModule("core", .{
        .root_source_file = b.path("core/main.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn build_math_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.addModule("math", .{
        .root_source_file = b.path("math/main.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn build_ecs_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_module: *std.Build.Module) *std.Build.Module {
    const ecs = b.addModule("ecs", .{
        .root_source_file = b.path("ecs/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    ecs.addImport("core", core_module);

    return ecs;
}

fn build_renderer_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_module: *std.Build.Module, math_module: *std.Build.Module) *std.Build.Module {
    const renderer = b.addModule("renderer", .{
        .root_source_file = b.path("renderer/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const env_map = std.process.getEnvMap(b.allocator) catch @panic("OOM");

    // STB
    renderer.addIncludePath(b.path("thirdparty/stb"));
    renderer.addCSourceFile(.{ .file = b.path("cpp/stb_image.cpp") });

    // SDL
    renderer.addIncludePath(b.path("thirdparty/sdl/include"));
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
    renderer.addIncludePath(b.path("thirdparty/vma/include"));
    renderer.addCSourceFile(.{ .file = b.path("cpp/vma.cpp") });

    renderer.addImport("core", core_module);
    renderer.addImport("math", math_module);

    return renderer;
}

fn build_engine_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_module: *std.Build.Module, math_module: *std.Build.Module, ecs_module: *std.Build.Module, renderer_module: *std.Build.Module) *std.Build.Module {
    const engine = b.addModule("engine", .{
        .root_source_file = b.path("engine/engine.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Freetype
    const b_freetype = b.dependency("freetype", .{});
    engine.linkLibrary(b_freetype.artifact("freetype"));
    engine.addIncludePath(.{ .cwd_relative = "thirdparty/zig-freetype/include" });

    engine.addImport("core", core_module);
    engine.addImport("math", math_module);
    engine.addImport("ecs", ecs_module);
    engine.addImport("renderer", renderer_module);

    // OpenAL
    engine.addIncludePath(b.path("thirdparty/openal/include/"));
    if (target.result.os.tag == .windows) {
        // For now only x64 is supported
        engine.addLibraryPath(b.path("thirdparty/openal/libs/Win64/"));
        b.installBinFile("thirdparty/openal/bin/Win64/soft_oal.dll", "OpenAL32.dll");

        engine.linkSystemLibrary("openal32", .{});
    } else if (target.result.os.tag == .linux) {
        engine.linkSystemLibrary("openal", .{});
    }

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

    compile_shaders(b, sdk.renderer_module);

    const test_step = b.step("test", "Run unit tests");

    add_tests(
        b,
        &sdk,
        test_step,
        target,
        optimize,
        &[_][]const u8{
            "core/main.zig",
            "math/main.zig",
            "ecs/main.zig",
            "renderer/main.zig",
            "engine/engine.zig",
        },
    );
}

fn add_tests(b: *std.Build, sdk: *const EngineSdk, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, comptime sources: []const []const u8) void {
    for (sources) |source| {
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
}

fn compile_shaders(
    b: *std.Build,
    module: *std.Build.Module,
) void {
    const base_rel_path = "renderer/shaders";
    const out_dir = "renderer/spirv";
    const iterator = b.build_root.handle.openDir(base_rel_path, .{ .iterate = true }) catch @panic("OOM");
    var it = iterator.iterate();

    while (it.next() catch @panic("WalkDir")) |entry| {
        if (entry.kind == .file) {
            const ext = std.fs.path.extension(entry.name);
            const full_path = std.fs.path.join(b.allocator, &.{ base_rel_path, entry.name }) catch @panic("OOM");
            if (is_shader_ext_valid(ext)) {
                add_shader(b, module, out_dir, full_path);
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

fn add_shader(b: *std.Build, module: *std.Build.Module, out_dir: []const u8, full_path: []const u8) void {
    const name = std.fs.path.basename(full_path);
    const outpath = std.fmt.allocPrint(b.allocator, "{s}/{s}.spv", .{ out_dir, name }) catch @panic("OOM");

    std.debug.print("Compiling shader '{s}' to '{s}'\n", .{ full_path, outpath });
    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(full_path));
    module.addAnonymousImport(outpath, .{ .root_source_file = output });
}
