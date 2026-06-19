//! libclang boundary: parse the metal-cpp umbrellas and produce a `model.Index`
//! covering every method, enum, struct, and class declared under the metal-cpp
//! root. Everything clang-specific is contained here; callers receive only
//! `model.Symbol`/`model.NameEntry` allocated in the supplied arena.
//!
//! Three non-obvious facts drive the implementation (see spike/FINDINGS.md):
//!  1. libclang needs an explicit `-resource-dir` or its builtin headers
//!     (`stdarg.h`) are not found.
//!  2. metal-cpp headers `#include` themselves, and `#pragma once` does not
//!     suppress that for clang's primary input — so we parse a synthetic TU that
//!     `#include`s the umbrellas instead.
//!  3. The Objective-C selector cannot be recovered via `clang_tokenize` (the
//!     `_MTL_INLINE` macro makes the extent a macro location → 0 tokens). We
//!     scan the header source forward from the method-name offset to the first
//!     `_MTL_PRIVATE_SEL(accessor)` and map the accessor via the bridge table.

const std = @import("std");
const model = @import("model.zig");

const c = @cImport({
    @cInclude("clang-c/Index.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const log = std.log.scoped(.clang_index);

/// Candidate umbrella headers, by convention `<Dir>/<Dir>.hpp`. Only those
/// present under the root are parsed.
const umbrella_dirs = [_][]const u8{ "Metal", "Foundation", "QuartzCore", "MetalFX" };

pub const Options = struct {
    /// Absolute metal-cpp root (the directory containing `Metal/`).
    metal_cpp_root: []const u8,
    /// Active SDK sysroot (for `-isysroot`).
    sysroot: []const u8,
    /// libclang resource dir (the `lib/clang/<v>` that holds `stdarg.h`).
    resource_dir: []const u8,
};

pub const Error = error{
    ParseFailed,
    ParseHadErrors,
    OutOfMemory,
};

const Builder = struct {
    arena: std.mem.Allocator,
    opts: Options,
    sel_map: *std.StringHashMapUnmanaged([]const u8),
    src_cache: *std.StringHashMapUnmanaged([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
    symbols: *std.ArrayList(model.Symbol),
    names: *std.ArrayList(model.NameEntry),
};

/// Parse all present umbrellas and return every metal-cpp declaration as a
/// `model.Index` allocated in `arena`. Symbols are returned sorted by ID so the
/// index (and anything derived from it) is deterministic.
pub fn indexAll(arena: std.mem.Allocator, opts: Options) Error!model.Index {
    var sel_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const bridge = std.fmt.allocPrint(arena, "{s}/Metal/MTLHeaderBridge.hpp", .{opts.metal_cpp_root}) catch return error.OutOfMemory;
    buildSelectorMap(arena, bridge, &sel_map) catch |err| {
        log.warn("could not read selector bridge {s}: {s}", .{ bridge, @errorName(err) });
    };

    const index = c.clang_createIndex(0, 0);
    defer c.clang_disposeIndex(index);

    const inc = std.fmt.allocPrintSentinel(arena, "-I{s}", .{opts.metal_cpp_root}, 0) catch return error.OutOfMemory;
    const sysroot_z = arena.dupeZ(u8, opts.sysroot) catch return error.OutOfMemory;
    const resdir_z = arena.dupeZ(u8, opts.resource_dir) catch return error.OutOfMemory;
    const clang_args = [_][*c]const u8{
        "-x",            "c++",
        "-std=c++17",    inc.ptr,
        "-isysroot",     sysroot_z.ptr,
        "-resource-dir", resdir_z.ptr,
    };

    // Synthetic TU that includes every present umbrella, so each self-including
    // header is entered via the include path and pragma-once applies.
    const tu_src = try buildTuSource(arena, opts.metal_cpp_root);
    const tu_name = "metaldoc_tu.cpp";
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
    if (tu == null) return error.ParseFailed;
    defer c.clang_disposeTranslationUnit(tu);

    if (countErrors(tu) > 0) return error.ParseHadErrors;

    var src_cache: std.StringHashMapUnmanaged([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var symbols: std.ArrayList(model.Symbol) = .empty;
    var names: std.ArrayList(model.NameEntry) = .empty;
    var b = Builder{
        .arena = arena,
        .opts = opts,
        .sel_map = &sel_map,
        .src_cache = &src_cache,
        .seen = &seen,
        .symbols = &symbols,
        .names = &names,
    };
    _ = c.clang_visitChildren(c.clang_getTranslationUnitCursor(tu), visit, &b);

    std.mem.sortUnstable(model.Symbol, symbols.items, {}, lessSymbolById);
    std.mem.sortUnstable(model.NameEntry, names.items, {}, lessNameEntry);
    return .{ .symbols = symbols.items, .names = names.items };
}

/// Build the synthetic-TU source: one `#include` per umbrella present on disk.
fn buildTuSource(arena: std.mem.Allocator, root: []const u8) Error![:0]const u8 {
    var src: std.ArrayList(u8) = .empty;
    for (umbrella_dirs) |dir| {
        const rel = std.fmt.allocPrint(arena, "{s}/{s}.hpp", .{ dir, dir }) catch return error.OutOfMemory;
        const abs = std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel }) catch return error.OutOfMemory;
        if (!exists(arena, abs)) continue;
        const line = std.fmt.allocPrint(arena, "#include \"{s}\"\n", .{rel}) catch return error.OutOfMemory;
        src.appendSlice(arena, line) catch return error.OutOfMemory;
    }
    return arena.dupeZ(u8, src.items) catch return error.OutOfMemory;
}

fn visit(cursor: c.CXCursor, parent: c.CXCursor, data: c.CXClientData) callconv(.c) c.CXChildVisitResult {
    _ = parent;
    const b: *Builder = @ptrCast(@alignCast(data));

    const kind = c.clang_getCursorKind(cursor);
    switch (kind) {
        c.CXCursor_CXXMethod => {
            if (c.clang_isCursorDefinition(cursor) != 0 and underRoot(b, cursor)) {
                addMethod(b, cursor) catch |err| log.warn("skip method: {s}", .{@errorName(err)});
            }
        },
        c.CXCursor_EnumDecl => addTypeIf(b, cursor, .cpp_enum, "enum"),
        c.CXCursor_StructDecl => addTypeIf(b, cursor, .cpp_struct, "struct"),
        c.CXCursor_ClassDecl => addTypeIf(b, cursor, .cpp_class, "class"),
        else => {},
    }
    return c.CXChildVisit_Recurse;
}

fn addTypeIf(b: *Builder, cursor: c.CXCursor, kind: model.Kind, kind_seg: []const u8) void {
    if (c.clang_isCursorDefinition(cursor) == 0) return;
    if (!underRoot(b, cursor)) return;
    const name = cxStr(b.arena, c.clang_getCursorSpelling(cursor)) catch return;
    if (name.len == 0) return; // skip anonymous
    addType(b, cursor, kind, kind_seg) catch |err| log.warn("skip type: {s}", .{@errorName(err)});
}

fn addType(b: *Builder, cursor: c.CXCursor, kind: model.Kind, kind_seg: []const u8) !void {
    const qual = try qualifiedName(b.arena, cursor);
    if (qual.len == 0) return;
    const id = try std.fmt.allocPrint(b.arena, "cpp:{s}/{s}", .{ kind_seg, qual });
    if (try seenBefore(b, id)) return;

    const loc = locationOf(b, cursor);
    var aliases: std.ArrayList(model.Alias) = .empty;
    try aliases.append(b.arena, .{ .language = "cpp", .name = qual, .provenance = "metal-cpp" });

    try b.symbols.append(b.arena, .{
        .id = id,
        .surface = .host_api,
        .kind = kind,
        .owner = .{ .kind = "namespace", .name = ownerOf(qual) },
        .signature = qual,
        .params_key = "",
        .selector = null,
        .source = .{ .path = loc.rel, .line = loc.line },
        .ownership = null,
        .aliases = aliases.items,
        .provenance = try singleton(b.arena, "metal-cpp"),
    });
    try b.names.append(b.arena, .{
        .normalized = try model.normalize(b.arena, qual),
        .language = "cpp",
        .kind = kind_seg,
        .symbol_id = id,
        .provenance = "metal-cpp",
    });
}

fn addMethod(b: *Builder, cursor: c.CXCursor) !void {
    const owner_name = try qualifiedName(b.arena, c.clang_getCursorSemanticParent(cursor));
    if (owner_name.len == 0) return;
    const name = try cxStr(b.arena, c.clang_getCursorSpelling(cursor));
    const ret = try cxStr(b.arena, c.clang_getTypeSpelling(c.clang_getCursorResultType(cursor)));

    // Parameters: build both the human signature and the normalized params key.
    var sig: std.ArrayList(u8) = .empty;
    var key: std.ArrayList(u8) = .empty;
    try sig.appendSlice(b.arena, ret);
    try sig.append(b.arena, ' ');
    try sig.appendSlice(b.arena, name);
    try sig.append(b.arena, '(');
    const nargs = c.clang_Cursor_getNumArguments(cursor);
    var ai: c_int = 0;
    while (ai < nargs) : (ai += 1) {
        const arg = c.clang_Cursor_getArgument(cursor, @intCast(ai));
        const atype = try cxStr(b.arena, c.clang_getTypeSpelling(c.clang_getArgType(c.clang_getCursorType(cursor), @intCast(ai))));
        const aname = try cxStr(b.arena, c.clang_getCursorSpelling(arg));
        if (ai != 0) {
            try sig.appendSlice(b.arena, ", ");
            try key.append(b.arena, ',');
        }
        try sig.appendSlice(b.arena, atype);
        if (aname.len > 0) {
            try sig.append(b.arena, ' ');
            try sig.appendSlice(b.arena, aname);
        }
        try key.appendSlice(b.arena, atype);
    }
    try sig.append(b.arena, ')');

    const params_key = key.items;
    const id = try model.methodId(b.arena, owner_name, name, params_key);
    if (try seenBefore(b, id)) return;

    const loc = locationOf(b, cursor);
    const selector = recoverSelector(b, loc.abs, loc.off);
    const ownership: ?model.Ownership = if (isOwned(name)) .owned else .borrowed;

    var aliases: std.ArrayList(model.Alias) = .empty;
    const cpp_full = try std.fmt.allocPrint(b.arena, "{s}::{s}", .{ owner_name, name });
    try aliases.append(b.arena, .{ .language = "cpp", .name = cpp_full, .provenance = "metal-cpp" });
    if (selector) |sel| {
        try aliases.append(b.arena, .{ .language = "objc", .name = sel, .provenance = "metal-cpp" });
    }

    try b.symbols.append(b.arena, .{
        .id = id,
        .surface = .host_api,
        .kind = .cpp_method,
        .owner = .{ .kind = "class", .name = owner_name },
        .signature = sig.items,
        .params_key = params_key,
        .selector = selector,
        .source = .{ .path = loc.rel, .line = loc.line },
        .ownership = ownership,
        .aliases = aliases.items,
        .provenance = try singleton(b.arena, "metal-cpp"),
    });
    try b.names.append(b.arena, .{
        .normalized = try model.normalize(b.arena, cpp_full),
        .language = "cpp",
        .kind = "method",
        .symbol_id = id,
        .provenance = "metal-cpp",
    });
    if (selector) |sel| {
        try b.names.append(b.arena, .{
            .normalized = try model.normalize(b.arena, sel),
            .language = "objc",
            .kind = "selector",
            .symbol_id = id,
            .provenance = "metal-cpp",
        });
    }
}

const Location = struct { abs: []const u8, rel: []const u8, line: u32, off: c_uint };

fn locationOf(b: *Builder, cursor: c.CXCursor) Location {
    var file: c.CXFile = undefined;
    var line: c_uint = 0;
    var off: c_uint = 0;
    c.clang_getSpellingLocation(c.clang_getCursorLocation(cursor), &file, &line, null, &off);
    const abs = cxStr(b.arena, c.clang_getFileName(file)) catch "";
    return .{ .abs = abs, .rel = relativize(abs, b.opts.metal_cpp_root), .line = @intCast(line), .off = off };
}

/// Whether a cursor's definition lives in a file under the metal-cpp root.
fn underRoot(b: *Builder, cursor: c.CXCursor) bool {
    var file: c.CXFile = undefined;
    c.clang_getSpellingLocation(c.clang_getCursorLocation(cursor), &file, null, null, null);
    const path = cxStr(b.arena, c.clang_getFileName(file)) catch return false;
    return std.mem.startsWith(u8, path, b.opts.metal_cpp_root);
}

fn seenBefore(b: *Builder, id: []const u8) !bool {
    if (b.seen.contains(id)) return true;
    try b.seen.put(b.arena, id, {});
    return false;
}

/// Walk semantic parents, collecting namespace/class names, to build a
/// fully-qualified C++ name like "MTL::Device". Includes the cursor itself when
/// it is a namespace/type.
fn qualifiedName(arena: std.mem.Allocator, cursor: c.CXCursor) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var cur = cursor;
    while (c.clang_Cursor_isNull(cur) == 0) {
        const kind = c.clang_getCursorKind(cur);
        if (kind == c.CXCursor_TranslationUnit) break;
        switch (kind) {
            c.CXCursor_Namespace,
            c.CXCursor_ClassDecl,
            c.CXCursor_StructDecl,
            c.CXCursor_EnumDecl,
            c.CXCursor_ClassTemplate,
            => {
                const sp = try cxStr(arena, c.clang_getCursorSpelling(cur));
                if (sp.len > 0) try parts.insert(arena, 0, sp);
            },
            else => {},
        }
        cur = c.clang_getCursorSemanticParent(cur);
    }
    return std.mem.join(arena, "::", parts.items);
}

/// The enclosing scope of a qualified name, e.g. "MTL::Device" -> "MTL".
fn ownerOf(qual: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, qual, "::")) |i| return qual[0..i];
    return "";
}

fn recoverSelector(b: *Builder, path: []const u8, name_off: c_uint) ?[]const u8 {
    const src = loadCached(b, path) catch return null;
    if (name_off >= src.len) return null;
    const marker = "_MTL_PRIVATE_SEL(";
    const rel = std.mem.indexOf(u8, src[name_off..], marker) orelse return null;
    const after = src[name_off + rel + marker.len ..];
    const close = std.mem.indexOfScalar(u8, after, ')') orelse return null;
    const accessor = std.mem.trim(u8, after[0..close], " \t\r\n");
    return b.sel_map.get(accessor);
}

/// Cocoa ownership rule: new*/alloc*/copy*/mutableCopy*/*Create* return +1.
fn isOwned(name: []const u8) bool {
    const prefixes = [_][]const u8{ "new", "alloc", "copy", "mutableCopy" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return std.mem.indexOf(u8, name, "Create") != null;
}

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

fn loadCached(b: *Builder, path: []const u8) ![]const u8 {
    if (b.src_cache.get(path)) |s| return s;
    const src = try readFile(b.arena, path);
    try b.src_cache.put(b.arena, try b.arena.dupe(u8, path), src);
    return src;
}

fn singleton(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, 1);
    out[0] = s;
    return out;
}

fn countErrors(tu: c.CXTranslationUnit) u32 {
    const n = c.clang_getNumDiagnostics(tu);
    var errors: u32 = 0;
    var i: c_uint = 0;
    while (i < n) : (i += 1) {
        const d = c.clang_getDiagnostic(tu, i);
        defer c.clang_disposeDiagnostic(d);
        if (c.clang_getDiagnosticSeverity(d) >= c.CXDiagnostic_Error) {
            errors += 1;
            const s = c.clang_formatDiagnostic(d, c.clang_defaultDiagnosticDisplayOptions());
            defer c.clang_disposeString(s);
            log.err("{s}", .{std.mem.span(c.clang_getCString(s))});
        }
    }
    return errors;
}

fn relativize(abs: []const u8, root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, abs, root)) {
        var rest = abs[root.len..];
        while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        return rest;
    }
    return abs;
}

fn exists(arena: std.mem.Allocator, path: []const u8) bool {
    const z = arena.dupeZ(u8, path) catch return false;
    const fd = c.open(z.ptr, c.O_RDONLY);
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
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

fn lessSymbolById(_: void, a: model.Symbol, b: model.Symbol) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessNameEntry(_: void, a: model.NameEntry, b: model.NameEntry) bool {
    if (std.mem.eql(u8, a.normalized, b.normalized)) return std.mem.lessThan(u8, a.symbol_id, b.symbol_id);
    return std.mem.lessThan(u8, a.normalized, b.normalized);
}
