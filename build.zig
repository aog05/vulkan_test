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

    const debug_option = b.option(bool, "debug", "Build the application in debug mode") orelse true;
    const options = b.addOptions();
    options.addOption(bool, "debug", debug_option);
    exe.root_module.addOptions("build_options", options);

    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("CoreVideo", .{});
    exe.root_module.linkSystemLibrary("GLFW", .{});
    linkVulkanLib(b, exe);

    compileShaders(b, exe) catch @panic("There was an error while compiling shaders");

    b.installArtifact(exe);

    const run_step = b.step("run", "Runs the application");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}

fn linkVulkanLib(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const vulkan_sdk_env = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch @panic("VULKAN_SDK is not set");
    defer b.allocator.free(vulkan_sdk_env);
    const vulkan_path = std.fmt.allocPrint(b.allocator, "{s}{s}", .{
        vulkan_sdk_env,
        "/lib/libvulkan.1.dylib",
    }) catch unreachable;
    defer b.allocator.free(vulkan_path);

    exe.root_module.addObjectFile(.{ .src_path = .{
        .owner = b,
        .sub_path = vulkan_path,
    } });
}

fn compileShaders(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    const shader_dir = try b.build_root.handle.openDir("shaders", .{});

    var file_iterator = shader_dir.iterate();
    while (try file_iterator.next()) |entry| {
        if (entry.kind == .file) {
            const extension = std.fs.path.extension(entry.name);
            const basename = std.fs.path.basename(entry.name);
            const name = basename[0 .. basename.len - extension.len];

            const source = try std.fmt.allocPrint(b.allocator, "shaders/{s}", .{basename});
            const output = try std.fmt.allocPrint(b.allocator, "shaders/{s}.spv", .{basename});
            const compiler_command = b.addSystemCommand(&.{"glslangValidator"});
            compiler_command.addArgs(&.{ "-V", "-o" });
            const compiler_output = compiler_command.addOutputFileArg(output);
            compiler_command.addFileArg(b.path(source));

            exe.root_module.addAnonymousImport(name, .{ .root_source_file = compiler_output });
        }
    }
}
