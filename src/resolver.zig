//! Deterministic query resolver. Maps a loose query to exact symbols via the
//! `NameEntry` table, follows aliases to canonical symbols, and returns either a
//! single resolved symbol, a sorted candidate list (ambiguous), or not-found.
//! Ranking is deterministic — no popularity, never a guess.

const std = @import("std");
const model = @import("model.zig");

pub const Status = enum { resolved, ambiguous, not_found };

pub const Result = struct {
    query: []const u8,
    status: Status,
    /// Set when `status == .resolved`.
    symbol: ?model.Symbol = null,
    /// Set (sorted by symbol ID) when `status == .ambiguous`.
    candidates: []const model.Symbol = &.{},
};

const Parsed = struct {
    /// Lowercased name with any `(...)` params stripped.
    name_norm: []const u8,
    /// Normalized param-type list when the query carried `(...)`, else null.
    params_key: ?[]const u8,
    is_selector: bool,
    /// Whether the query carried a `::` scope (exact match) vs a bare basename.
    is_qualified: bool,
};

pub fn resolve(arena: std.mem.Allocator, index: model.Index, query: []const u8) !Result {
    const q = std.mem.trim(u8, query, " \t\r\n");
    const parsed = try parseQuery(arena, q);

    // Map symbol IDs to symbols for alias-following.
    var by_id: std.StringHashMapUnmanaged(model.Symbol) = .empty;
    for (index.symbols) |sym| try by_id.put(arena, sym.id, sym);

    // Collect distinct matching symbol IDs via the name table.
    var hits: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (index.names) |entry| {
        const is_sel = std.mem.eql(u8, entry.language, "objc");
        if (parsed.is_selector != is_sel) continue;
        if (!nameMatches(parsed, entry.normalized)) continue;

        // If the query specified overload params, keep only the matching symbol.
        if (parsed.params_key) |want| {
            const sym = by_id.get(entry.symbol_id) orelse continue;
            if (!std.mem.eql(u8, sym.params_key, want)) continue;
        }
        try hits.put(arena, entry.symbol_id, {});
    }

    var matched: std.ArrayList(model.Symbol) = .empty;
    for (hits.keys()) |id| {
        if (by_id.get(id)) |sym| try matched.append(arena, sym);
    }
    std.mem.sortUnstable(model.Symbol, matched.items, {}, lessById);

    return switch (matched.items.len) {
        0 => .{ .query = q, .status = .not_found },
        1 => .{ .query = q, .status = .resolved, .symbol = matched.items[0] },
        else => .{ .query = q, .status = .ambiguous, .candidates = matched.items },
    };
}

/// Substring search over the name table. Returns distinct symbols whose any
/// alias name contains `term` (case-insensitive), sorted by symbol ID.
pub fn search(arena: std.mem.Allocator, index: model.Index, term: []const u8) ![]const model.Symbol {
    const t = try model.normalize(arena, std.mem.trim(u8, term, " \t\r\n"));

    var by_id: std.StringHashMapUnmanaged(model.Symbol) = .empty;
    for (index.symbols) |sym| try by_id.put(arena, sym.id, sym);

    var hits: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (index.names) |entry| {
        if (std.mem.indexOf(u8, entry.normalized, t) != null) try hits.put(arena, entry.symbol_id, {});
    }

    var out: std.ArrayList(model.Symbol) = .empty;
    for (hits.keys()) |id| {
        if (by_id.get(id)) |sym| try out.append(arena, sym);
    }
    std.mem.sortUnstable(model.Symbol, out.items, {}, lessById);
    return out.items;
}

fn parseQuery(arena: std.mem.Allocator, q: []const u8) !Parsed {
    var name = q;
    var params: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, q, '(')) |open| {
        if (std.mem.lastIndexOfScalar(u8, q, ')')) |close| {
            if (close > open) {
                name = std.mem.trim(u8, q[0..open], " \t");
                params = try normalizeParams(arena, q[open + 1 .. close]);
            }
        }
    }

    const is_qualified = std.mem.indexOf(u8, name, "::") != null;
    // Selector form contains ':' but not the C++ scope operator "::".
    const is_selector = std.mem.indexOfScalar(u8, name, ':') != null and !is_qualified;

    return .{
        .name_norm = try model.normalize(arena, name),
        .params_key = params,
        .is_selector = is_selector,
        .is_qualified = is_qualified,
    };
}

/// A qualified or selector query must match the full normalized name; a bare
/// basename (e.g. `newBuffer`) matches the last `::`-segment of any C++ name.
fn nameMatches(parsed: Parsed, normalized: []const u8) bool {
    if (parsed.is_qualified or parsed.is_selector) {
        return std.mem.eql(u8, normalized, parsed.name_norm);
    }
    return std.mem.eql(u8, lastComponent(normalized), parsed.name_norm);
}

fn lastComponent(name: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, name, "::")) |i| return name[i + 2 ..];
    return name;
}

/// Normalize a comma-separated param-type list to the index's key form:
/// trim each type, drop inner spaces, comma-join with no spaces.
fn normalizeParams(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    var first = true;
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        if (!first) try out.append(arena, ',');
        first = false;
        for (t) |ch| if (ch != ' ') try out.append(arena, ch);
    }
    return out.items;
}

fn lessById(_: void, a: model.Symbol, b: model.Symbol) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

test "normalizeParams strips spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "NS::UInteger,MTL::ResourceOptions",
        try normalizeParams(arena_state.allocator(), " NS::UInteger , MTL::ResourceOptions "),
    );
}

test "parseQuery detects selector vs cpp" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sel = try parseQuery(a, "newBufferWithLength:options:");
    try std.testing.expect(sel.is_selector);
    try std.testing.expect(sel.params_key == null);

    const cpp = try parseQuery(a, "MTL::Device::newBuffer(NS::UInteger, MTL::ResourceOptions)");
    try std.testing.expect(!cpp.is_selector);
    try std.testing.expectEqualStrings("mtl::device::newbuffer", cpp.name_norm);
    try std.testing.expectEqualStrings("NS::UInteger,MTL::ResourceOptions", cpp.params_key.?);
}
