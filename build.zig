const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("vulkan_test", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "vulkan_test",
        .root_module = module,
    });

    const vulkan_sdk_env = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch @panic("VULKAN_SDK is not set");
    defer b.allocator.free(vulkan_sdk_env);

    const debug_option = b.option(bool, "debug", "Build the application in debug mode") orelse true;
    const translate_headers_option = b.option(
        bool,
        "translate-headers",
        "Translate all of the vulkan and glfw headers",
    ) orelse false;
    const options = b.addOptions();
    options.addOption(bool, "debug", debug_option);
    options.addOption(bool, "translate-headers", translate_headers_option);
    exe.root_module.addOptions("build_options", options);

    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("CoreVideo", .{});
    exe.root_module.linkSystemLibrary("GLFW", .{});
    linkVulkanLib(b, exe, vulkan_sdk_env);

    compileShaders(b) catch @panic("There was an error while compiling shaders");

    if (translate_headers_option)
        translateHeaders(b, vulkan_sdk_env) catch @panic("Could not translate headers");

    b.installArtifact(exe);

    const run_step = b.step("run", "Runs the application");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}

fn translateHeaders(b: *std.Build, vulkan_sdk_env: []u8) !void {
    const vulkan_include_dir = try std.fmt.allocPrint(b.allocator, "{s}/include", .{vulkan_sdk_env});
    const vulkan_include_h = try std.fmt.allocPrint(b.allocator, "{s}/include/vulkan/vulkan.h", .{vulkan_sdk_env});
    defer b.allocator.free(vulkan_include_dir);
    defer b.allocator.free(vulkan_include_h);

    const translate_glfw = b.addSystemCommand(&.{
        "zig",
        "translate-c",
        "/opt/homebrew/include/GLFW/glfw3.h",
        "-D",
        "GLFW_INCLUDE_VULKAN=1",
        "-I",
        vulkan_include_dir,
        "> src/headers/glfw.zig",
    });

    b.getInstallStep().dependOn(&translate_glfw.step);

    const translate_vulkan = b.addSystemCommand(&.{
        "zig",
        "translate-c",
        vulkan_include_h,
        "-D",
        "VK_USE_PLATFORM_METAL_EXT=1",
        "-I",
        vulkan_include_dir,
        "> src/headers/vulkan.zig",
    });

    b.getInstallStep().dependOn(&translate_vulkan.step);
}

fn linkVulkanLib(b: *std.Build, exe: *std.Build.Step.Compile, vulkan_sdk_env: []u8) void {
    const vulkan_path = std.fmt.allocPrint(b.allocator, "{s}/lib/libvulkan.1.dylib", .{
        vulkan_sdk_env,
    }) catch unreachable;
    defer b.allocator.free(vulkan_path);

    exe.root_module.addObjectFile(.{ .src_path = .{
        .owner = b,
        .sub_path = vulkan_path,
    } });
}

fn compileShaders(b: *std.Build) !void {
    const shader_dir = try b.build_root.handle.openDir("src/shaders", .{});

    const spirv_directory_command = b.addSystemCommand(&.{ "mkdir", "-p", "src/shaders/spir-v" });
    b.getInstallStep().dependOn(&spirv_directory_command.step);

    var file_iterator = shader_dir.iterate();
    while (try file_iterator.next()) |entry| {
        if (entry.kind == .file) {
            const basename = std.fs.path.basename(entry.name);

            const source = try std.fmt.allocPrint(b.allocator, "src/shaders/{s}", .{basename});
            const output = try std.fmt.allocPrint(b.allocator, "src/shaders/spir-v/{s}.spv", .{basename});
            defer b.allocator.free(source);
            defer b.allocator.free(output);

            const compiler_command = b.addSystemCommand(&.{
                "glslangValidator",
                source,
            });
            compiler_command.addArgs(&.{ "-V", "-o", output });
            b.getInstallStep().dependOn(&compiler_command.step);
        }
    }
}
