//! MSL resolution tests. The curated-builtin path is hermetic; the stdlib path
//! shells out to the Metal driver and skips when no toolchain is available.

const std = @import("std");
const msl = @import("msl.zig");
const env = @import("env.zig");

test "msl: curated builtin resolves without a toolchain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = msl.resolve(arena, "[[thread_position_in_grid]]", "/nonexistent/metal");
    switch (r) {
        .builtin => |b| try std.testing.expectEqualStrings("thread_position_in_grid", b.name),
        else => return error.ExpectedBuiltin,
    }
}

test "msl: stdlib function resolves via the Metal AST dump" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const metal_bin = env.metalBin(arena) orelse return error.SkipZigTest;

    const r = msl.resolve(arena, "metal::dot", metal_bin);
    switch (r) {
        .function => |f| {
            try std.testing.expectEqualStrings("metal::dot", f.name);
            try std.testing.expect(f.overloads.len >= 3);
            var found = false;
            for (f.overloads) |sig| {
                if (std.mem.eql(u8, sig, "float (metal::float3, metal::float3)")) found = true;
            }
            try std.testing.expect(found);
        },
        else => return error.ExpectedFunction,
    }
}
