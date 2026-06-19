//! ObjC enrichment test. Asserts structure rather than exact strings (doc/
//! availability are SDK-version dependent), and skips when no SDK is available.

const std = @import("std");
const objc_enrich = @import("objc_enrich.zig");
const env = @import("env.zig");

test "objc enrichment: newBufferWithLength:options: gets summary + availability" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sysroot = env.sdkPath(arena) orelse return error.SkipZigTest;
    const resource_dir = env.resourceDir(arena) orelse return error.SkipZigTest;

    var map = objc_enrich.build(arena, sysroot, resource_dir) catch return error.SkipZigTest;
    const e = map.get("newBufferWithLength:options:") orelse return error.MissingSelector;

    // Summary should be present and mention the buffer (don't pin exact prose).
    try std.testing.expect(e.summary.len > 0);
    try std.testing.expect(containsIgnoreCase(e.summary, "buffer"));

    // Availability should include macOS with an introduced version.
    var has_macos = false;
    for (e.availability) |a| {
        if (std.mem.eql(u8, a.platform, "macos")) {
            has_macos = true;
            try std.testing.expect(a.introduced.len > 0);
        }
    }
    try std.testing.expect(has_macos);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
