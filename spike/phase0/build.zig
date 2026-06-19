const std = @import("std");

// Phase 0 spike: prove Zig + libclang can parse metal-cpp and recover
// C++ method signatures + their Objective-C selectors.
//
// Uses Homebrew LLVM 21 (has both libclang.dylib and clang-c/ headers).
const llvm_prefix = "/opt/homebrew/opt/llvm@21";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = llvm_prefix ++ "/include" });
    mod.addLibraryPath(.{ .cwd_relative = llvm_prefix ++ "/lib" });
    mod.linkSystemLibrary("clang", .{});

    const exe = b.addExecutable(.{
        .name = "phase0",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the phase 0 spike");
    run_step.dependOn(&run.step);
}
