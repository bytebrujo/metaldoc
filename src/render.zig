//! Renderers for a resolved query. `--format json` and `--format text` are two
//! views over one `resolver.Result`; JSON is the versioned, provenance-tagged
//! contract (schema v1). Output is deterministic: candidate lists are pre-sorted
//! by the resolver and field order is fixed by the wire structs below.

const std = @import("std");
const model = @import("model.zig");
const resolver = @import("resolver.zig");
const msl = @import("msl.zig");
const msl_builtins = @import("msl_builtins.zig");

pub const schema_version: u32 = 2;

/// Resolved environment, surfaced in every JSON envelope's `context`.
pub const Context = struct {
    developer_dir: []const u8,
    sdk_name: []const u8,
    sdk_version: []const u8,
    metal_cpp_root: []const u8,
    metal_toolchain: []const u8,
};

// --- Wire structs: field names are the JSON keys (camelCase), values are
// already strings so the serializer never sees an internal enum. ---

const ContextW = struct {
    developerDir: []const u8,
    sdkName: []const u8,
    sdkVersion: []const u8,
    metalCppRoot: []const u8,
    metalToolchain: []const u8,
    schemaVersion: u32,
};

const OwnerW = struct { kind: []const u8, name: []const u8 };
const SourceW = struct { path: []const u8, line: u32 };
const AliasW = struct { language: []const u8, name: []const u8, provenance: []const u8 };
const DocW = struct { summary: []const u8, provenance: []const u8 };
const AvailabilityW = struct { platform: []const u8, introduced: []const u8 };

const SymbolW = struct {
    id: []const u8,
    surface: []const u8,
    kind: []const u8,
    owner: OwnerW,
    signature: []const u8,
    selector: ?[]const u8,
    source: SourceW,
    ownership: ?[]const u8,
    doc: ?DocW,
    availability: []const AvailabilityW,
    nullability: ?[]const u8,
    aliases: []const AliasW,
    provenance: []const []const u8,
};

const Envelope = struct {
    query: []const u8,
    status: []const u8,
    context: ContextW,
    symbol: ?SymbolW = null,
    candidates: ?[]const SymbolW = null,
};

fn statusWire(s: resolver.Status) []const u8 {
    return switch (s) {
        .resolved => "resolved",
        .ambiguous => "ambiguous",
        .not_found => "not-found",
    };
}

fn contextW(ctx: Context) ContextW {
    return .{
        .developerDir = ctx.developer_dir,
        .sdkName = ctx.sdk_name,
        .sdkVersion = ctx.sdk_version,
        .metalCppRoot = ctx.metal_cpp_root,
        .metalToolchain = ctx.metal_toolchain,
        .schemaVersion = schema_version,
    };
}

fn symbolW(arena: std.mem.Allocator, sym: model.Symbol) !SymbolW {
    var aliases = try arena.alloc(AliasW, sym.aliases.len);
    for (sym.aliases, 0..) |a, i| aliases[i] = .{ .language = a.language, .name = a.name, .provenance = a.provenance };
    var avail = try arena.alloc(AvailabilityW, sym.availability.len);
    for (sym.availability, 0..) |a, i| avail[i] = .{ .platform = a.platform, .introduced = a.introduced };
    return .{
        .id = sym.id,
        .surface = sym.surface.wire(),
        .kind = sym.kind.wire(),
        .owner = .{ .kind = sym.owner.kind, .name = sym.owner.name },
        .signature = sym.signature,
        .selector = sym.selector,
        .source = .{ .path = sym.source.path, .line = sym.source.line },
        .ownership = if (sym.ownership) |o| o.wire() else null,
        .doc = if (sym.doc) |d| .{ .summary = d.summary, .provenance = d.provenance } else null,
        .availability = avail,
        .nullability = sym.nullability,
        .aliases = aliases,
        .provenance = sym.provenance,
    };
}

/// Render `result` as JSON (schema v1) to `w`.
pub fn renderJson(arena: std.mem.Allocator, result: resolver.Result, ctx: Context, w: *std.Io.Writer) !void {
    var env: Envelope = .{
        .query = result.query,
        .status = statusWire(result.status),
        .context = contextW(ctx),
    };
    switch (result.status) {
        .resolved => env.symbol = try symbolW(arena, result.symbol.?),
        .ambiguous => {
            var cands = try arena.alloc(SymbolW, result.candidates.len);
            for (result.candidates, 0..) |s, i| cands[i] = try symbolW(arena, s);
            env.candidates = cands;
        },
        .not_found => {},
    }

    var jw: std.json.Stringify = .{
        .writer = w,
        .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
    };
    try jw.write(env);
    try w.writeByte('\n');
}

/// Render `result` as compact, human-readable text to `w`.
pub fn renderText(result: resolver.Result, w: *std.Io.Writer) !void {
    switch (result.status) {
        .resolved => try renderSymbolText(result.symbol.?, w),
        .not_found => try w.print("Not found: {s}\n", .{result.query}),
        .ambiguous => {
            try w.print("Ambiguous query: {s}\n\nCandidates:\n", .{result.query});
            for (result.candidates, 0..) |sym, i| {
                try w.print("  {d}. {s}\n", .{ i + 1, sym.signature });
                if (sym.selector) |sel| try w.print("     selector: {s}\n", .{sel});
                try w.print("     id: {s}\n", .{sym.id});
            }
        },
    }
}

// --- search ---

const SearchHitW = struct {
    id: []const u8,
    kind: []const u8,
    signature: []const u8,
    selector: ?[]const u8,
};

pub fn renderSearch(arena: std.mem.Allocator, term: []const u8, hits: []const model.Symbol, format: enum { text, json }, w: *std.Io.Writer) !void {
    switch (format) {
        .text => {
            if (hits.len == 0) {
                try w.print("No matches for: {s}\n", .{term});
                return;
            }
            try w.print("{d} match(es) for: {s}\n\n", .{ hits.len, term });
            for (hits) |sym| {
                try w.print("  {s}  [{s}]\n", .{ sym.id, sym.kind.wire() });
            }
        },
        .json => {
            var rows = try arena.alloc(SearchHitW, hits.len);
            for (hits, 0..) |sym, i| rows[i] = .{ .id = sym.id, .kind = sym.kind.wire(), .signature = sym.signature, .selector = sym.selector };
            var jw: std.json.Stringify = .{
                .writer = w,
                .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
            };
            try jw.write(.{ .query = term, .count = hits.len, .results = rows });
            try w.writeByte('\n');
        },
    }
}

// --- MSL ---

pub fn renderMsl(arena: std.mem.Allocator, query: []const u8, result: msl.Result, toolchain: []const u8, format: enum { text, json }, w: *std.Io.Writer) !void {
    switch (format) {
        .text => try renderMslText(query, result, toolchain, w),
        .json => try renderMslJson(arena, query, result, toolchain, w),
    }
}

fn renderMslText(query: []const u8, result: msl.Result, toolchain: []const u8, w: *std.Io.Writer) !void {
    switch (result) {
        .not_found => try w.print("Not found in MSL: {s}\n", .{query}),
        .builtin => |b| {
            try w.print("{s}\n\n", .{b.name});
            try w.writeAll("Surface:     Metal Shading Language\n");
            try w.print("Kind:        {s}\n", .{b.category.label()});
            if (b.used_in.len > 0) try w.print("Used in:     {s}\n", .{b.used_in});
            try w.print("Purpose:     {s}\n", .{b.summary});
            if (b.common_type.len > 0) try w.print("Common type: {s}\n", .{b.common_type});
            if (b.related.len > 0) {
                try w.writeAll("Related:     ");
                for (b.related, 0..) |r, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.writeAll(r);
                }
                try w.writeByte('\n');
            }
            try w.print("Provenance:  curated-msl (metal-stdlib-{s})\n", .{toolchain});
        },
        .function => |f| {
            try w.print("{s}\n\n", .{f.name});
            try w.writeAll("Surface:     Metal Shading Language\n");
            try w.writeAll("Kind:        Standard library function\n");
            try w.writeAll("Overloads:\n");
            for (f.overloads) |sig| try w.print("  {s}\n", .{sig});
            try w.print("Provenance:  metal-stdlib-{s}\n", .{toolchain});
        },
    }
}

fn renderMslJson(arena: std.mem.Allocator, query: []const u8, result: msl.Result, toolchain: []const u8, w: *std.Io.Writer) !void {
    var jw: std.json.Stringify = .{
        .writer = w,
        .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
    };
    const ctx = .{ .metalToolchain = toolchain, .schemaVersion = schema_version };
    switch (result) {
        .not_found => try jw.write(.{ .query = query, .surface = "msl", .status = "not-found", .context = ctx }),
        .builtin => |b| try jw.write(.{
            .query = query,
            .surface = "msl",
            .status = "resolved",
            .context = ctx,
            .symbol = .{
                .id = try std.fmt.allocPrint(arena, "msl:attribute/{s}", .{b.name}),
                .name = b.name,
                .kind = b.category.label(),
                .summary = b.summary,
                .usedIn = nullIfEmpty(b.used_in),
                .commonType = nullIfEmpty(b.common_type),
                .related = b.related,
                .provenance = "curated-msl",
            },
        }),
        .function => |f| try jw.write(.{
            .query = query,
            .surface = "msl",
            .status = "resolved",
            .context = ctx,
            .symbol = .{
                .id = try std.fmt.allocPrint(arena, "msl:function/{s}", .{f.name}),
                .name = f.name,
                .kind = "msl.function",
                .overloads = f.overloads,
                .provenance = try std.fmt.allocPrint(arena, "metal-stdlib-{s}", .{toolchain}),
            },
        }),
    }
    try w.writeByte('\n');
}

fn nullIfEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

// --- index status / doctor ---

pub const Health = struct {
    ctx: Context,
    resource_dir: []const u8,
    sysroot: []const u8,
    cache_dir: []const u8,
    cache_key: []const u8,
    cache_present: bool,
    symbol_count: ?usize = null,
    name_count: ?usize = null,
    from_cache: ?bool = null,
};

pub fn renderHealth(h: Health, format: enum { text, json }, w: *std.Io.Writer) !void {
    switch (format) {
        .text => {
            try w.print("developerDir:   {s}\n", .{h.ctx.developer_dir});
            try w.print("sdk:            {s} {s}\n", .{ h.ctx.sdk_name, h.ctx.sdk_version });
            try w.print("sdkPath:        {s}\n", .{h.sysroot});
            try w.print("metalToolchain: {s}\n", .{h.ctx.metal_toolchain});
            try w.print("metalCppRoot:   {s}\n", .{h.ctx.metal_cpp_root});
            try w.print("resourceDir:    {s}\n", .{h.resource_dir});
            try w.print("cacheDir:       {s}\n", .{h.cache_dir});
            try w.print("cacheKey:       {s}\n", .{h.cache_key});
            try w.print("cachePresent:   {}\n", .{h.cache_present});
            if (h.symbol_count) |n| try w.print("symbols:        {d}\n", .{n});
            if (h.name_count) |n| try w.print("names:          {d}\n", .{n});
            if (h.from_cache) |fc| try w.print("fromCache:      {}\n", .{fc});
        },
        .json => {
            var jw: std.json.Stringify = .{
                .writer = w,
                .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
            };
            try jw.write(.{
                .developerDir = h.ctx.developer_dir,
                .sdkName = h.ctx.sdk_name,
                .sdkVersion = h.ctx.sdk_version,
                .sdkPath = h.sysroot,
                .metalToolchain = h.ctx.metal_toolchain,
                .metalCppRoot = h.ctx.metal_cpp_root,
                .resourceDir = h.resource_dir,
                .cacheDir = h.cache_dir,
                .cacheKey = h.cache_key,
                .cachePresent = h.cache_present,
                .symbolCount = h.symbol_count,
                .nameCount = h.name_count,
                .fromCache = h.from_cache,
                .schemaVersion = schema_version,
            });
            try w.writeByte('\n');
        },
    }
}

fn aliasName(sym: model.Symbol, language: []const u8) ?[]const u8 {
    for (sym.aliases) |a| if (std.mem.eql(u8, a.language, language)) return a.name;
    return null;
}

fn renderSymbolText(sym: model.Symbol, w: *std.Io.Writer) !void {
    const cpp_name = aliasName(sym, "cpp") orelse sym.owner.name;
    if (sym.kind == .cpp_method) {
        // Title: the qualified name with its parameter list, e.g.
        // "MTL::Device::newBuffer(NS::UInteger length, MTL::ResourceOptions options)".
        if (std.mem.indexOfScalar(u8, sym.signature, '(')) |paren| {
            try w.print("{s}{s}\n\n", .{ cpp_name, sym.signature[paren..] });
        } else {
            try w.print("{s}\n\n", .{sym.signature});
        }
        try w.print("Kind:       Instance method on {s}\n", .{sym.owner.name});
        try w.print("Signature:  {s}\n", .{sym.signature});
    } else {
        try w.print("{s}\n\n", .{cpp_name});
        try w.print("Kind:       {s}\n", .{switch (sym.kind) {
            .cpp_class => "C++ class",
            .cpp_struct => "C++ struct",
            .cpp_enum => "C++ enum",
            .cpp_method => unreachable,
        }});
    }
    if (sym.selector) |sel| try w.print("Selector:   {s}\n", .{sel});
    if (sym.nullability) |n| try w.print("Nullability:{s}{s}\n", .{ " ", n });
    if (sym.ownership) |o| switch (o) {
        .owned => try w.writeAll("Ownership:  owned (+1) — release it or wrap in NS::SharedPtr (NS::TransferPtr)\n"),
        .borrowed => try w.writeAll("Ownership:  borrowed — do not release; retain only to keep beyond scope\n"),
    };
    if (sym.doc) |d| try w.print("Summary:    {s}\n", .{d.summary});
    if (sym.availability.len > 0) {
        try w.writeAll("Availability:");
        for (sym.availability) |a| try w.print(" {s} {s}", .{ a.platform, a.introduced });
        try w.writeByte('\n');
    }
    try w.print("Declared:   {s}:{d}\n", .{ sym.source.path, sym.source.line });
    try w.print("Symbol ID:  {s}\n", .{sym.id});
    try w.writeAll("Provenance: ");
    for (sym.provenance, 0..) |p, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(p);
    }
    try w.writeByte('\n');
}
