//! Phase 0 spike: drive libclang from Zig to parse a metal-cpp header and
//! recover, for each `MTL::Device::newBuffer` overload:
//!   - the C++ signature, return type, and source file:line
//!   - the Objective-C selector (the cross-surface join key)
//!   - the derived ownership (+1 owned vs borrowed)
//!
//! Selector recovery is authoritative: the method body references
//! `_MTL_PRIVATE_SEL(accessor)`, and `MTLHeaderBridge.hpp` maps each accessor to
//! the exact selector string via `_MTL_PRIVATE_DEF_SEL(accessor, "selector")`.
//!
//! This is throwaway code to retire the make-or-break technical risk.

const std = @import("std");
const c = @cImport({
    @cInclude("clang-c/Index.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const default_root = "/Library/Frameworks/Python.framework/Versions/3.11/lib/python3.11/site-packages/mlx/include/metal_cpp";
const default_header = default_root ++ "/Metal/MTLDevice.hpp";
const default_sysroot = "/Users/louis/Downloads/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk";

// libclang must be told where its own builtin headers live (stdarg.h, etc.).
// Homebrew LLVM does not embed this path, so objc/runtime.h fails to find
// stdarg.h without it. The shipped tool will derive this from libclang.
const llvm_resource_dir = "/opt/homebrew/opt/llvm@21/lib/clang/21";

const target_class = "MTL::Device";
const target_method = "newBuffer";

const Ctx = struct {
    arena: std.mem.Allocator,
    tu: c.CXTranslationUnit,
    sel_map: *std.StringHashMapUnmanaged([]const u8),
    src_cache: *std.StringHashMapUnmanaged([]const u8),
    found: usize = 0,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const header = default_header;
    const root = default_root;
    const sysroot = default_sysroot;

    std.debug.print("== Phase 0 spike ==\n", .{});
    std.debug.print("header:  {s}\n", .{header});
    std.debug.print("root:    {s}\n", .{root});
    std.debug.print("sysroot: {s}\n\n", .{sysroot});

    // 1. Build the authoritative accessor -> selector map from MTLHeaderBridge.hpp.
    var sel_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const bridge = try std.fmt.allocPrint(arena, "{s}/Metal/MTLHeaderBridge.hpp", .{root});
    try buildSelectorMap(arena, bridge, &sel_map);
    std.debug.print("selector table: {d} accessors mapped\n\n", .{sel_map.count()});

    // 2. Parse the header with libclang as C++17.
    const index = c.clang_createIndex(0, 0);
    defer c.clang_disposeIndex(index);

    const inc = try std.fmt.allocPrintSentinel(arena, "-I{s}", .{root}, 0);
    const clang_args = [_][*c]const u8{
        "-x",            "c++",
        "-std=c++17",    inc.ptr,
        "-isysroot",     sysroot.ptr,
        "-resource-dir", llvm_resource_dir,
    };

    // metal-cpp headers `#include` themselves (e.g. MTLDevice.hpp line 30).
    // `#pragma once` does NOT suppress that when the header is clang's primary
    // input — the main file isn't tracked in the pragma-once set — so the file
    // would be parsed twice (redefinition errors + duplicate overloads).
    // Parse a synthetic TU that includes the header instead, so the header is
    // entered through the normal include path and pragma-once applies.
    const rel = header[root.len + 1 ..]; // "Metal/MTLDevice.hpp"
    const tu_name = "metaldoc_tu.cpp";
    const tu_src = try std.fmt.allocPrintSentinel(arena, "#include \"{s}\"\n", .{rel}, 0);
    var unsaved = [_]c.struct_CXUnsavedFile{.{
        .Filename = tu_name,
        .Contents = tu_src.ptr,
        .Length = @intCast(tu_src.len),
    }};

    const tu = c.clang_parseTranslationUnit(
        index,
        tu_name,
        &clang_args,
        clang_args.len,
        &unsaved,
        unsaved.len,
        c.CXTranslationUnit_None,
    );
    if (tu == null) {
        std.debug.print("FATAL: clang_parseTranslationUnit returned null\n", .{});
        return error.ParseFailed;
    }
    defer c.clang_disposeTranslationUnit(tu);

    reportDiagnostics(tu);

    // 3. Walk the AST, find target method definitions, recover selectors.
    var src_cache: std.StringHashMapUnmanaged([]const u8) = .empty;
    var ctx = Ctx{ .arena = arena, .tu = tu, .sel_map = &sel_map, .src_cache = &src_cache };
    _ = c.clang_visitChildren(c.clang_getTranslationUnitCursor(tu), visit, &ctx);

    std.debug.print("\n== {d} overload(s) resolved ==\n", .{ctx.found});
    if (ctx.found == 0) return error.NothingFound;
}

fn visit(cursor: c.CXCursor, parent: c.CXCursor, data: c.CXClientData) callconv(.c) c.CXChildVisitResult {
    _ = parent;
    const ctx: *Ctx = @ptrCast(@alignCast(data));

    if (c.clang_getCursorKind(cursor) != c.CXCursor_CXXMethod) return c.CXChildVisit_Recurse;

    const name = cxStr(ctx.arena, c.clang_getCursorSpelling(cursor)) catch return c.CXChildVisit_Recurse;
    if (!std.mem.eql(u8, name, target_method)) return c.CXChildVisit_Recurse;

    const owner = cxStr(ctx.arena, c.clang_getCursorDisplayName(c.clang_getCursorSemanticParent(cursor))) catch return c.CXChildVisit_Recurse;

    if (c.clang_isCursorDefinition(cursor) == 0) return c.CXChildVisit_Recurse;
    if (!std.mem.endsWith(u8, owner, "Device")) return c.CXChildVisit_Recurse;

    const display = cxStr(ctx.arena, c.clang_getCursorDisplayName(cursor)) catch return c.CXChildVisit_Recurse;
    const ret = cxStr(ctx.arena, c.clang_getTypeSpelling(c.clang_getCursorResultType(cursor))) catch return c.CXChildVisit_Recurse;

    var file: c.CXFile = undefined;
    var line: c_uint = 0;
    var col: c_uint = 0;
    var off: c_uint = 0;
    c.clang_getSpellingLocation(c.clang_getCursorLocation(cursor), &file, &line, &col, &off);
    const fname = cxStr(ctx.arena, c.clang_getFileName(file)) catch "?";

    const selector = recoverSelector(ctx, fname, off) orelse "<unresolved>";
    const ownership = if (isOwned(name)) "owned (+1)" else "borrowed";

    ctx.found += 1;
    std.debug.print("[{d}] {s}::{s}\n", .{ ctx.found, owner, display });
    std.debug.print("     return:    {s}\n", .{ret});
    std.debug.print("     selector:  {s}\n", .{selector});
    std.debug.print("     ownership: {s}\n", .{ownership});
    std.debug.print("     source:    {s}:{d}\n\n", .{ baseName(fname), line });

    return c.CXChildVisit_Recurse;
}

/// Recover the selector for a method definition by reading the header source.
/// `clang_tokenize` over the cursor extent is unreliable here: the extent starts
/// at the `_MTL_INLINE` macro-expansion location, so both tokenizing and the
/// extent's spelling offsets are unusable. The method *name* location, however,
/// is a real file offset — scan forward from it to the first
/// `_MTL_PRIVATE_SEL(accessor)` (which sits in this method's one-line body) and
/// map the accessor to its selector via the bridge table.
fn recoverSelector(ctx: *Ctx, path: []const u8, name_off: c_uint) ?[]const u8 {
    const src = loadCached(ctx, path) catch return null;
    if (name_off >= src.len) return null;

    const marker = "_MTL_PRIVATE_SEL(";
    const rel = std.mem.indexOf(u8, src[name_off..], marker) orelse return null;
    const after = src[name_off + rel + marker.len ..];
    const close = std.mem.indexOfScalar(u8, after, ')') orelse return null;
    const accessor = std.mem.trim(u8, after[0..close], " \t\r\n");
    return ctx.sel_map.get(accessor);
}

/// Read a file once, caching by path for the lifetime of the run.
fn loadCached(ctx: *Ctx, path: []const u8) ![]const u8 {
    if (ctx.src_cache.get(path)) |s| return s;
    const src = try readFile(ctx.arena, path);
    try ctx.src_cache.put(ctx.arena, try ctx.arena.dupe(u8, path), src);
    return src;
}

/// Cocoa ownership rule: new*/alloc*/copy*/mutableCopy*/*Create* return +1.
fn isOwned(name: []const u8) bool {
    const prefixes = [_][]const u8{ "new", "alloc", "copy", "mutableCopy" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return std.mem.indexOf(u8, name, "Create") != null;
}

/// Parse `_MTL_PRIVATE_DEF_SEL(accessor, "selector");` entries into a map.
fn buildSelectorMap(arena: std.mem.Allocator, path: []const u8, map: *std.StringHashMapUnmanaged([]const u8)) !void {
    const src = try readFile(arena, path);
    const marker = "_MTL_PRIVATE_DEF_SEL(";
    var rest = src;
    while (std.mem.indexOf(u8, rest, marker)) |idx| {
        rest = rest[idx + marker.len ..];
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse continue;
        const accessor = std.mem.trim(u8, rest[0..comma], " \t\r\n");
        rest = rest[comma + 1 ..];
        const q1 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        rest = rest[q1 + 1 ..];
        const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const selector = rest[0..q2];
        try map.put(arena, try arena.dupe(u8, accessor), try arena.dupe(u8, selector));
    }
}

fn reportDiagnostics(tu: c.CXTranslationUnit) void {
    const n = c.clang_getNumDiagnostics(tu);
    var errors: u32 = 0;
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        const d = c.clang_getDiagnostic(tu, i);
        defer c.clang_disposeDiagnostic(d);
        const sev = c.clang_getDiagnosticSeverity(d);
        if (sev >= c.CXDiagnostic_Error) {
            errors += 1;
            const s = c.clang_formatDiagnostic(d, c.clang_defaultDiagnosticDisplayOptions());
            defer c.clang_disposeString(s);
            std.debug.print("  ERR: {s}\n", .{std.mem.span(c.clang_getCString(s))});
        }
    }
    std.debug.print("diagnostics: {d} total, {d} errors\n", .{ n, errors });
}

fn readFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try arena.dupeZ(u8, path);
    const fd = c.open(path_z.ptr, c.O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(arena, buf[0..@intCast(n)]);
    }
    return list.items;
}

fn cxStr(arena: std.mem.Allocator, s: c.CXString) ![]const u8 {
    defer c.clang_disposeString(s);
    const ptr = c.clang_getCString(s);
    if (ptr == null) return "";
    return arena.dupe(u8, std.mem.span(ptr));
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}
