const std = @import("std");

// metaldoc links libclang (stable C API) for metal-cpp/ObjC parsing. Homebrew
// LLVM ships both libclang.dylib and the clang-c/ headers.
// TODO(phase2): make this configurable / auto-detected rather than pinned.
const llvm_prefix = "/opt/homebrew/opt/llvm@21";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "metaldoc",
        .root_module = libclangModule(b, target, optimize),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run metaldoc").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = libclangModule(b, target, optimize) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit + golden tests").dependOn(&run_tests.step);
}

fn libclangModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = llvm_prefix ++ "/include" });
    mod.addLibraryPath(.{ .cwd_relative = llvm_prefix ++ "/lib" });
    mod.linkSystemLibrary("clang", .{});
    // Expose the AGENTS.md template (outside src/) for @embedFile in init.zig.
    mod.addAnonymousImport("agents_template", .{ .root_source_file = b.path("templates/AGENTS.md.tmpl") });
    return mod;
}
