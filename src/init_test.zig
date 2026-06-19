//! Snapshot + behavior tests for `metaldoc init`. These are hermetic (no SDK or
//! libclang needed): they exercise the embedded template and the write/clobber
//! logic against a temp path.

const std = @import("std");
const init_cmd = @import("init.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

test "init: embedded template matches templates/AGENTS.md.tmpl on disk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(init_cmd.template.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, init_cmd.template, "# AGENTS.md"));

    // The embed must equal the source of truth, so editing the .tmpl is enough
    // to update what `init` emits.
    const on_disk = readFile(arena, "templates/AGENTS.md.tmpl") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings(on_disk, init_cmd.template);
}

test "init: --print emits the template verbatim and writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    const res = try init_cmd.run(arena, "/tmp/metaldoc_should_not_be_written.md", false, true, &aw.writer);
    try std.testing.expectEqual(init_cmd.Result.printed, res);
    try std.testing.expectEqualStrings(init_cmd.template, aw.written());
    try std.testing.expect(!init_cmd.fileExists(arena, "/tmp/metaldoc_should_not_be_written.md"));
}

test "init: writes, refuses to clobber, overwrites with force" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = "/tmp/metaldoc_init_test_AGENTS.md";
    remove(arena, target);
    defer remove(arena, target);

    var sink: std.Io.Writer.Allocating = .init(arena);

    // First write succeeds and lands the full template.
    try std.testing.expectEqual(init_cmd.Result.wrote, try init_cmd.run(arena, target, false, false, &sink.writer));
    try std.testing.expectEqualStrings(init_cmd.template, readFile(arena, target).?);

    // Second write without force refuses (no clobber).
    try std.testing.expectEqual(init_cmd.Result.exists, try init_cmd.run(arena, target, false, false, &sink.writer));

    // With force it overwrites.
    try std.testing.expectEqual(init_cmd.Result.wrote, try init_cmd.run(arena, target, true, false, &sink.writer));
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

fn remove(arena: std.mem.Allocator, path: []const u8) void {
    const z = arena.dupeZ(u8, path) catch return;
    _ = c.remove(z.ptr);
}
