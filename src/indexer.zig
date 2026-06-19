//! Index orchestration: build the metal-cpp symbol index, then enrich it with
//! ObjC SDK facts joined on the selector. This is the build that gets cached.
//! Kept separate from `clang_index` so the metal-cpp parse stays a pure,
//! deterministic, SDK-independent step (the golden tests use it directly).

const std = @import("std");
const model = @import("model.zig");
const clang_index = @import("clang_index.zig");
const objc_enrich = @import("objc_enrich.zig");

const log = std.log.scoped(.indexer);

pub const Options = struct {
    metal_cpp_root: []const u8,
    sysroot: []const u8,
    resource_dir: []const u8,
};

/// Parse metal-cpp, then join ObjC enrichment (doc/availability/nullability) on
/// the selector. If enrichment fails (e.g. SDK headers unavailable), the
/// metal-cpp index is returned unenriched rather than failing the whole build.
pub fn build(arena: std.mem.Allocator, opts: Options) !model.Index {
    const base = try clang_index.indexAll(arena, .{
        .metal_cpp_root = opts.metal_cpp_root,
        .sysroot = opts.sysroot,
        .resource_dir = opts.resource_dir,
    });

    const map = objc_enrich.build(arena, opts.sysroot, opts.resource_dir) catch |err| {
        log.warn("ObjC enrichment skipped: {s}", .{@errorName(err)});
        return base;
    };

    const syms = try arena.dupe(model.Symbol, base.symbols);
    var enriched: usize = 0;
    for (syms) |*s| {
        const sel = s.selector orelse continue;
        const e = map.get(sel) orelse continue;
        try applyEnrichment(arena, s, e);
        enriched += 1;
    }
    log.info("enriched {d}/{d} symbols on selector", .{ enriched, syms.len });
    return .{ .symbols = syms, .names = base.names };
}

fn applyEnrichment(arena: std.mem.Allocator, s: *model.Symbol, e: objc_enrich.Enrichment) !void {
    if (e.summary.len > 0) s.doc = .{ .summary = e.summary, .provenance = "clang/objc" };
    s.availability = e.availability;
    s.nullability = e.nullability;

    // Record that ObjC enrichment touched this symbol, even when the header
    // carried no brief — availability/nullability are still sourced facts.
    var prov = try arena.alloc([]const u8, s.provenance.len + 1);
    @memcpy(prov[0..s.provenance.len], s.provenance);
    prov[s.provenance.len] = "clang/objc";
    s.provenance = prov;
}
