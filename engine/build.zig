const std = @import("std");

fn sdk_path(comptime path: []const u8) []const u8 {
    const src = @src();
    const source = comptime std.fs.path.dirname(src.file) orelse ".";
    return source ++ path;
}

fn build_math_module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.addModule("math", .{
        .root_source_file = .{ .cwd_relative = sdk_path("/math/main.zig") },
        .target = target,
        .optimize = optimize,
    });
}

pub const EngineSdk = struct {
    math_module: *std.Build.Module,
};

pub fn setup(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) EngineSdk {
    const math_module = build_math_module(b, target, optimize);

    return .{
        .math_module = math_module,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();

    const test_step = b.step("test", "Run unit tests");
    const run_unit_tests = b.addRunArtifact(unit_tests);

    test_step.dependOn(&run_unit_tests.step);
}

fn setup_compile(exe: *std.Build.Step.Compile, b: *std.Build, target: std.Build.ResolvedTarget) !void {

    // Some libs are c++ libs
    exe.linkLibCpp();

    const env_map = try std.process.getEnvMap(b.allocator);

    // STB
    exe.addIncludePath(.{ .cwd_relative = "thirdparty/stb" });
    exe.addCSourceFile(.{ .file = b.path("src/stb_image.cpp") });

    // SDL
    exe.addIncludePath(.{ .cwd_relative = "thirdparty/sdl/include" });
    exe.linkSystemLibrary("SDL2");

    if (target.result.os.tag == .windows) {
        exe.addLibraryPath(b.path("thirdparty/sdl/x86_64-w64/bin/"));
        exe.addLibraryPath(b.path("thirdparty/sdl/x86_64-w64/lib/"));
        b.installBinFile("thirdparty/sdl/x86_64-w64/bin/SDL2.dll", "SDL2.dll");
    }

    // Vulkan
    const vk_lib_name = if (target.result.os.tag == .windows) "vulkan-1" else "vulkan";
    exe.linkSystemLibrary(
        vk_lib_name,
    );
    if (env_map.get("VULKAN_SDK")) |path| {
        exe.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{path}) catch @panic("OOM") });
        exe.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/include", .{path}) catch @panic("OOM") });
    }

    // VMA
    exe.addIncludePath(b.path("thirdparty/vma/include"));
    exe.addCSourceFile(.{ .file = b.path("src/vma.cpp") });

    // Freetype
    const b_freetype = b.dependency("freetype", .{});
    exe.linkLibrary(b_freetype.artifact("freetype"));

    // OpenAL
    exe.addIncludePath(b.path("thirdparty/openal/include/"));
    if (target.result.os.tag == .windows) {
        // For now only x64 is supported
        exe.addLibraryPath(b.path("thirdparty/openal/libs/Win64/"));
        b.installBinFile("thirdparty/openal/bin/Win64/soft_oal.dll", "OpenAL32.dll");

        exe.linkSystemLibrary("openal32");
    } else if (target.result.os.tag == .linux) {
        exe.linkSystemLibrary("openal");
    }
}

fn build_shaders(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    const base_rel_path = "src/renderer/shaders";
    const out_dir = "src/spirv";
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
