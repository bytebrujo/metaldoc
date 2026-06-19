//! ObjC enrichment (Phase 5): parse the `Metal.framework` Objective-C headers
//! with libclang and build a `selector -> Enrichment` table (doc summary,
//! platform availability, return nullability, source location). The metal-cpp
//! symbols carry the selector as their cross-surface join key, so the indexer
//! joins this onto them. Provenance is `clang/objc`.
//!
//! libclang (stable C API) is used deliberately over `-ast-dump=json`, whose
//! format is unstable across clang releases.

const std = @import("std");
const model = @import("model.zig");

const c = @cImport({
    @cInclude("clang-c/Index.h");
});

const log = std.log.scoped(.objc_enrich);

pub const Enrichment = struct {
    summary: []const u8 = "",
    availability: []const model.Availability = &.{},
    nullability: ?[]const u8 = null,
    header: []const u8 = "",
    line: u32 = 0,
};

pub const Map = std.StringHashMapUnmanaged(Enrichment);

const Builder = struct {
    arena: std.mem.Allocator,
    map: *Map,
};

/// Parse `<Metal/Metal.h>` and return the selector→enrichment table.
pub fn build(arena: std.mem.Allocator, sysroot: []const u8, resource_dir: []const u8) !Map {
    const index = c.clang_createIndex(0, 0);
    defer c.clang_disposeIndex(index);

    const sysroot_z = try arena.dupeZ(u8, sysroot);
    const resdir_z = try arena.dupeZ(u8, resource_dir);
    const args = [_][*c]const u8{
        "-x",            "objective-c",
        "-fsyntax-only",
        // The Metal framework headers are system headers; clang drops their
        // comments unless we ask to retain them. Both flags are needed.
        "-fparse-all-comments",
        "-fretain-comments-from-system-headers",
        "-isysroot",     sysroot_z.ptr,
        "-resource-dir", resdir_z.ptr,
    };

    const tu_name = "metaldoc_objc.m";
    const tu_src = "#import <Metal/Metal.h>\n";
    var unsaved = [_]c.struct_CXUnsavedFile{.{
        .Filename = tu_name,
        .Contents = tu_src,
        .Length = tu_src.len,
    }};

    const tu = c.clang_parseTranslationUnit(
        index,
        tu_name,
        &args,
        args.len,
        &unsaved,
        unsaved.len,
        c.CXTranslationUnit_None,
    );
    if (tu == null) return error.ParseFailed;
    defer c.clang_disposeTranslationUnit(tu);

    var map: Map = .empty;
    var b = Builder{ .arena = arena, .map = &map };
    _ = c.clang_visitChildren(c.clang_getTranslationUnitCursor(tu), visit, &b);
    return map;
}

fn visit(cursor: c.CXCursor, parent: c.CXCursor, data: c.CXClientData) callconv(.c) c.CXChildVisitResult {
    _ = parent;
    const b: *Builder = @ptrCast(@alignCast(data));

    const kind = c.clang_getCursorKind(cursor);
    if (kind != c.CXCursor_ObjCInstanceMethodDecl and kind != c.CXCursor_ObjCClassMethodDecl) {
        return c.CXChildVisit_Recurse;
    }

    addMethod(b, cursor) catch |err| log.warn("skip objc method: {s}", .{@errorName(err)});
    return c.CXChildVisit_Recurse;
}

fn addMethod(b: *Builder, cursor: c.CXCursor) !void {
    // Restrict to the Metal framework's own headers.
    var file: c.CXFile = undefined;
    var line: c_uint = 0;
    c.clang_getSpellingLocation(c.clang_getCursorLocation(cursor), &file, &line, null, null);
    const path = try cxStr(b.arena, c.clang_getFileName(file));
    if (std.mem.indexOf(u8, path, "/Metal.framework/") == null) return;

    const selector = try cxStr(b.arena, c.clang_getCursorSpelling(cursor));
    if (selector.len == 0) return;

    // Prefer libclang's brief; fall back to parsing the raw comment, which is
    // more reliable under -fparse-all-comments (brief is often empty there).
    var summary = try cxStr(b.arena, c.clang_Cursor_getBriefCommentText(cursor));
    if (summary.len == 0) {
        const raw = try cxStr(b.arena, c.clang_Cursor_getRawCommentText(cursor));
        summary = try summarize(b.arena, raw);
    }
    const e: Enrichment = .{
        .summary = summary,
        .availability = try availability(b.arena, cursor),
        .nullability = nullability(cursor),
        .header = baseName(path),
        .line = @intCast(line),
    };

    // First entry for a selector wins, but prefer one that carries a summary so
    // the join surfaces docs deterministically.
    if (b.map.get(selector)) |existing| {
        if (existing.summary.len > 0 or e.summary.len == 0) return;
    }
    try b.map.put(b.arena, selector, e);
}

fn availability(arena: std.mem.Allocator, cursor: c.CXCursor) ![]const model.Availability {
    var avail: [16]c.CXPlatformAvailability = undefined;
    var always_deprecated: c_int = 0;
    var deprecated_msg: c.CXString = undefined;
    var always_unavailable: c_int = 0;
    var unavailable_msg: c.CXString = undefined;
    const n = c.clang_getCursorPlatformAvailability(
        cursor,
        &always_deprecated,
        &deprecated_msg,
        &always_unavailable,
        &unavailable_msg,
        &avail,
        avail.len,
    );
    c.clang_disposeString(deprecated_msg);
    c.clang_disposeString(unavailable_msg);

    var out: std.ArrayList(model.Availability) = .empty;
    var i: c_int = 0;
    const count = @min(n, @as(c_int, avail.len));
    while (i < count) : (i += 1) {
        const a = avail[@intCast(i)];
        // Do NOT dispose a.Platform here — clang_disposeCXPlatformAvailability
        // below frees it. Copy the bytes out instead (disposing it via cxStr
        // would double-free and abort).
        const pstr = c.clang_getCString(a.Platform);
        const platform = if (pstr) |p| try arena.dupe(u8, std.mem.span(p)) else "";
        if (a.Introduced.Major >= 0 and platform.len > 0) {
            try out.append(arena, .{
                .platform = platform,
                .introduced = try version(arena, a.Introduced),
            });
        }
        c.clang_disposeCXPlatformAvailability(&avail[@intCast(i)]);
    }
    std.mem.sortUnstable(model.Availability, out.items, {}, lessAvail);
    return out.items;
}

fn version(arena: std.mem.Allocator, v: c.CXVersion) ![]const u8 {
    if (v.Minor < 0) return std.fmt.allocPrint(arena, "{d}", .{v.Major});
    if (v.Subminor < 0) return std.fmt.allocPrint(arena, "{d}.{d}", .{ v.Major, v.Minor });
    return std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.Major, v.Minor, v.Subminor });
}

/// Extract a one-line summary from a raw doc comment. Prefers the `@brief` /
/// `\brief` paragraph; otherwise the first prose line. Strips comment markers
/// and collapses whitespace.
fn summarize(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return "";

    // Locate the brief paragraph if present.
    var body = raw;
    if (std.mem.indexOf(u8, raw, "brief")) |i| {
        // Ensure it's a @brief/\brief command, not the word in prose.
        if (i > 0 and (raw[i - 1] == '@' or raw[i - 1] == '\\')) {
            body = raw[i + "brief".len ..];
        }
    }

    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = cleanCommentLine(raw_line);
        if (line.len == 0) {
            if (out.items.len > 0) break; // blank line ends the first paragraph
            continue;
        }
        if (line[0] == '@' or line[0] == '\\') break; // next doc command
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, line);
    }
    return out.items;
}

/// Strip a comment line's markers (`/`, `*`, `!`, `<`) and surrounding space.
fn cleanCommentLine(line: []const u8) []const u8 {
    var s = std.mem.trim(u8, line, " \t\r");
    while (s.len > 0 and (s[0] == '/' or s[0] == '*' or s[0] == '!' or s[0] == '<')) s = s[1..];
    return std.mem.trim(u8, s, " \t\r");
}

fn nullability(cursor: c.CXCursor) ?[]const u8 {
    return switch (c.clang_Type_getNullability(c.clang_getCursorResultType(cursor))) {
        c.CXTypeNullability_NonNull => "nonnull",
        c.CXTypeNullability_Nullable => "nullable",
        else => null,
    };
}

fn lessAvail(_: void, a: model.Availability, b: model.Availability) bool {
    return std.mem.lessThan(u8, a.platform, b.platform);
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn cxStr(arena: std.mem.Allocator, s: c.CXString) ![]const u8 {
    defer c.clang_disposeString(s);
    const ptr = c.clang_getCString(s);
    if (ptr == null) return "";
    return arena.dupe(u8, std.mem.span(ptr));
}
