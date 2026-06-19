//! On-disk index cache. Full libclang parsing of the metal-cpp umbrellas takes
//! seconds; this caches the resolved `model.Index` keyed by everything that can
//! change its contents, so a warm run skips the reparse.
//!
//! The key hashes content (not mtimes), per the design: SDK version, libclang
//! resource dir, Metal toolchain, schema version, the metal-cpp root path, and a
//! manifest of every `*.hpp` (relative path + bytes). Any change flips the key
//! and forces a reparse; an identical environment is a guaranteed hit.

const std = @import("std");
const model = @import("model.zig");
const render = @import("render.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

const log = std.log.scoped(.cache);

pub const KeyInputs = struct {
    metal_cpp_root: []const u8,
    sdk_version: []const u8,
    resource_dir: []const u8,
    metal_toolchain: []const u8,
};

const CacheFile = struct {
    schema: u32,
    symbols: []model.Symbol,
    names: []model.NameEntry,
};

pub const Status = struct {
    key: []const u8,
    path: []const u8,
    present: bool,
};

/// Compute the cache key: a hex digest over the environment plus a content
/// manifest of every header under the root.
pub fn computeKey(arena: std.mem.Allocator, in: KeyInputs) []const u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&render.schema_version));
    inline for (.{ in.metal_cpp_root, in.sdk_version, in.resource_dir, in.metal_toolchain }) |field| {
        h.update(field);
        h.update("\x00");
    }

    // Manifest: each header's relative path + bytes, in sorted order.
    const list_cmd = std.fmt.allocPrint(arena, "find {s} -name '*.hpp' -type f | sort", .{in.metal_cpp_root}) catch "";
    if (capture(arena, list_cmd)) |listing| {
        var it = std.mem.splitScalar(u8, listing, '\n');
        while (it.next()) |path| {
            if (path.len == 0) continue;
            h.update(path);
            if (readFile(arena, path)) |bytes| h.update(bytes);
        }
    }

    return std.fmt.allocPrint(arena, "{x}", .{h.final()}) catch "0";
}

pub fn status(arena: std.mem.Allocator, key: []const u8) Status {
    const p = filePath(arena, key);
    return .{ .key = key, .path = p, .present = fileExists(arena, p) };
}

/// Load a cached index for `key`, or null on miss / schema mismatch / parse error.
pub fn load(arena: std.mem.Allocator, key: []const u8) ?model.Index {
    const bytes = readFile(arena, filePath(arena, key)) orelse return null;
    const parsed = std.json.parseFromSliceLeaky(CacheFile, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("ignoring unreadable cache: {s}", .{@errorName(err)});
        return null;
    };
    if (parsed.schema != render.schema_version) return null;
    return .{ .symbols = parsed.symbols, .names = parsed.names };
}

/// Serialize `index` to the cache file for `key`.
pub fn store(arena: std.mem.Allocator, key: []const u8, index: model.Index) void {
    ensureDir(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const file: CacheFile = .{ .schema = render.schema_version, .symbols = @constCast(index.symbols), .names = @constCast(index.names) };
    jw.write(file) catch |err| {
        log.warn("could not serialize cache: {s}", .{@errorName(err)});
        return;
    };
    writeFile(arena, filePath(arena, key), aw.written()) catch |err| {
        log.warn("could not write cache: {s}", .{@errorName(err)});
    };
}

pub fn dir(arena: std.mem.Allocator) []const u8 {
    const home: []const u8 = if (c.getenv("HOME")) |p| std.mem.span(p) else "/tmp";
    return std.fmt.allocPrint(arena, "{s}/Library/Caches/metaldoc", .{home}) catch "/tmp/metaldoc";
}

fn filePath(arena: std.mem.Allocator, key: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}.json", .{ dir(arena), key }) catch "/tmp/metaldoc.json";
}

fn ensureDir(arena: std.mem.Allocator) void {
    const cmd = std.fmt.allocPrint(arena, "mkdir -p {s}", .{dir(arena)}) catch return;
    _ = capture(arena, cmd);
}

fn capture(arena: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
    const cmd_z = arena.dupeZ(u8, cmd) catch return null;
    const f = c.popen(cmd_z.ptr, "r");
    if (f == null) return null;
    defer _ = c.pclose(f);
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        list.appendSlice(arena, buf[0..n]) catch return null;
    }
    return list.items;
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
    var buf: [64 * 1024]u8 = undefined;
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
    if (data.len > 0 and c.fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
}
