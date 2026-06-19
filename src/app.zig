//! Wiring shared by the CLI subcommands: resolve the environment, then get a
//! `model.Index` from the cache when warm, or parse + populate the cache.

const std = @import("std");
const model = @import("model.zig");
const render = @import("render.zig");
const indexer = @import("indexer.zig");
const cache = @import("cache.zig");
const env = @import("env.zig");

pub const Error = error{ EnvUnavailable, IndexFailed, OutOfMemory };

pub const Resolved = struct {
    ctx: render.Context,
    sysroot: []const u8,
    resource_dir: []const u8,
};

/// Resolve the toolchain environment, or fail if the essentials are missing.
pub fn resolveEnv(arena: std.mem.Allocator, metal_cpp_root: []const u8) Error!Resolved {
    const sysroot = env.sdkPath(arena) orelse return error.EnvUnavailable;
    const resource_dir = env.resourceDir(arena) orelse return error.EnvUnavailable;
    return .{ .ctx = env.gather(arena, metal_cpp_root), .sysroot = sysroot, .resource_dir = resource_dir };
}

pub const Loaded = struct {
    index: model.Index,
    key: []const u8,
    from_cache: bool,
};

/// Return the index for `r`, using the on-disk cache unless `force` is set.
pub fn loadIndex(arena: std.mem.Allocator, r: Resolved, force: bool) Error!Loaded {
    const key = cache.computeKey(arena, .{
        .metal_cpp_root = r.ctx.metal_cpp_root,
        .sdk_version = r.ctx.sdk_version,
        .resource_dir = r.resource_dir,
        .metal_toolchain = r.ctx.metal_toolchain,
    });

    if (!force) {
        if (cache.load(arena, key)) |idx| return .{ .index = idx, .key = key, .from_cache = true };
    }

    const idx = indexer.build(arena, .{
        .metal_cpp_root = r.ctx.metal_cpp_root,
        .sysroot = r.sysroot,
        .resource_dir = r.resource_dir,
    }) catch return error.IndexFailed;

    cache.store(arena, key, idx);
    return .{ .index = idx, .key = key, .from_cache = false };
}
