//! Golden test for the Phase 1 vertical slice: index MTL::Device from the
//! vendored metal-cpp header, resolve, and render both formats against committed
//! snapshots. A *fixed* context is used so output is byte-identical regardless of
//! the machine's live SDK/toolchain — only the header-derived facts vary, and
//! those are stable for a given metal-cpp version.
//!
//! Regenerate snapshots after an intentional change:
//!   METALDOC_UPDATE_GOLDEN=1 zig build test
//!
//! The test skips (rather than fails) when the vendored header or libclang
//! toolchain is absent, so it is safe on machines without the setup.

const std = @import("std");
const clang_index = @import("clang_index.zig");
const resolver = @import("resolver.zig");
const render = @import("render.zig");
const env = @import("env.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const metal_cpp_root = "/Library/Frameworks/Python.framework/Versions/3.11/lib/python3.11/site-packages/mlx/include/metal_cpp";

// Fixed context → deterministic snapshots across machines.
const fixed_ctx: render.Context = .{
    .developer_dir = "/FIXED/Xcode.app/Contents/Developer",
    .sdk_name = "macosx",
    .sdk_version = "27.0",
    .metal_cpp_root = "/FIXED/metal_cpp",
    .metal_toolchain = "32023",
};

const Case = struct {
    query: []const u8,
    format: enum { text, json },
    golden: []const u8,
};

const cases = [_]Case{
    .{ .query = "MTL::Device::newBuffer", .format = .json, .golden = "tests/golden/newBuffer_ambiguous.json" },
    .{ .query = "MTL::Device::newBuffer(NS::UInteger, MTL::ResourceOptions)", .format = .text, .golden = "tests/golden/newBuffer_resolved.txt" },
    // Shared by MTL::Device and MTL::Heap — the selector is a cross-class join
    // key, not unique, so this is correctly ambiguous.
    .{ .query = "newBufferWithLength:options:", .format = .json, .golden = "tests/golden/selector_ambiguous.json" },
    .{ .query = "MTL::CommandQueue", .format = .text, .golden = "tests/golden/class_resolved.txt" },
};

test "golden: lookup MTL::Device::newBuffer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sysroot = env.sdkPath(arena) orelse return error.SkipZigTest;
    const resource_dir = env.resourceDir(arena) orelse return error.SkipZigTest;
    if (!fileExists(arena, metal_cpp_root ++ "/Metal/MTLDevice.hpp")) return error.SkipZigTest;

    const index = clang_index.indexAll(arena, .{
        .metal_cpp_root = metal_cpp_root,
        .sysroot = sysroot,
        .resource_dir = resource_dir,
    }) catch return error.SkipZigTest;

    const update = c.getenv("METALDOC_UPDATE_GOLDEN") != null;

    for (cases) |case| {
        const result = try resolver.resolve(arena, index, case.query);

        var aw: std.Io.Writer.Allocating = .init(arena);
        switch (case.format) {
            .json => try render.renderJson(arena, result, fixed_ctx, &aw.writer),
            .text => try render.renderText(result, &aw.writer),
        }
        const got = aw.written();

        if (update) {
            try writeFile(arena, case.golden, got);
            continue;
        }
        const want = readFile(arena, case.golden) orelse {
            std.debug.print("missing golden {s}; run METALDOC_UPDATE_GOLDEN=1 zig build test\n", .{case.golden});
            return error.MissingGolden;
        };
        std.testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("golden mismatch for {s} (query {s})\n", .{ case.golden, case.query });
            return e;
        };
    }
}

fn fileExists(arena: std.mem.Allocator, path: []const u8) bool {
    const z = arena.dupeZ(u8, path) catch return false;
    const f = c.fopen(z.ptr, "r");
    if (f == null) return false;
    _ = c.fclose(f);
    return true;
}

fn readFile(arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = arena.dupeZ(u8, path) catch return null;
    const f = c.fopen(z.ptr, "r");
    if (f == null) return null;
    defer _ = c.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        list.appendSlice(arena, buf[0..n]) catch return null;
    }
    return list.items;
}

fn writeFile(arena: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try arena.dupeZ(u8, path);
    const f = c.fopen(z.ptr, "w");
    if (f == null) return error.WriteFailed;
    defer _ = c.fclose(f);
    if (data.len > 0) {
        const n = c.fwrite(data.ptr, 1, data.len, f);
        if (n != data.len) return error.WriteFailed;
    }
}
