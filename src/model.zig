//! Core data model for metaldoc: `Symbol`, `NameEntry`, and the stable
//! symbol-ID scheme. libclang `CX*` types never appear here — the indexer
//! converts to these structs immediately so the rest of the tool is
//! clang-version agnostic. Names/aliases live in `NameEntry` and point at symbol
//! IDs, so an alias never becomes its own symbol.

const std = @import("std");

/// Which API surface a symbol belongs to. v0 emits `host_api`; `msl` is Phase 4.
pub const Surface = enum {
    host_api,
    msl,

    pub fn wire(self: Surface) []const u8 {
        return switch (self) {
            .host_api => "host-api",
            .msl => "msl",
        };
    }
};

/// The category of a symbol. v0 covers the `cpp.*` host surface.
pub const Kind = enum {
    cpp_method,
    cpp_class,
    cpp_enum,
    cpp_struct,

    pub fn wire(self: Kind) []const u8 {
        return switch (self) {
            .cpp_method => "cpp.method",
            .cpp_class => "cpp.class",
            .cpp_enum => "cpp.enum",
            .cpp_struct => "cpp.struct",
        };
    }
};

/// metal-cpp memory ownership, derived from the method-name prefix. This is the
/// single highest-value agent hint and is deterministic from the parse.
pub const Ownership = enum {
    owned,
    borrowed,

    pub fn wire(self: Ownership) []const u8 {
        return switch (self) {
            .owned => "owned",
            .borrowed => "borrowed",
        };
    }
};

/// Source location, with `path` relative to the metal-cpp root so output is
/// byte-identical across machines (the absolute root lives in the context).
pub const Source = struct {
    path: []const u8,
    line: u32,
};

pub const Owner = struct {
    kind: []const u8, // e.g. "class"
    name: []const u8, // e.g. "MTL::Device"
};

pub const Alias = struct {
    language: []const u8, // "cpp" | "objc"
    name: []const u8,
    provenance: []const u8,
};

/// Human-readable doc, sourced from ObjC SDK headers (enrichment, Phase 5).
pub const Doc = struct {
    summary: []const u8,
    provenance: []const u8 = "clang/objc",
};

/// Platform availability, e.g. { platform: "macos", introduced: "10.11" }.
pub const Availability = struct {
    platform: []const u8,
    introduced: []const u8,
};

pub const Symbol = struct {
    id: []const u8,
    surface: Surface,
    kind: Kind,
    owner: Owner,
    signature: []const u8,
    /// Normalized parameter-type list (comma-joined, no spaces), matching the
    /// `(...)` segment of the symbol ID. Used to disambiguate overloads.
    params_key: []const u8,
    selector: ?[]const u8,
    source: Source,
    ownership: ?Ownership,
    aliases: []const Alias,
    provenance: []const []const u8,
    // ObjC enrichment (Phase 5), joined on the selector. Defaulted so the
    // metal-cpp parser can construct symbols without it.
    doc: ?Doc = null,
    availability: []const Availability = &.{},
    nullability: ?[]const u8 = null, // "nonnull" | "nullable"
};

pub const NameEntry = struct {
    normalized: []const u8,
    language: []const u8, // "cpp" | "objc"
    kind: []const u8, // "method" | "selector"
    symbol_id: []const u8,
    provenance: []const u8,
};

/// A resolved index: the symbols plus the name/alias table that points at them.
pub const Index = struct {
    symbols: []const Symbol,
    names: []const NameEntry,
};

/// Build the stable symbol ID for a C++ method, e.g.
/// `cpp:class/MTL::Device/method/newBuffer(NS::UInteger,MTL::ResourceOptions)`.
pub fn methodId(
    arena: std.mem.Allocator,
    owner_name: []const u8,
    method_name: []const u8,
    params_key: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(arena, "cpp:class/{s}/method/{s}({s})", .{
        owner_name, method_name, params_key,
    });
}

/// Lowercase a copy of `s` for case-insensitive name matching.
pub fn normalize(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

test "methodId format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const id = try methodId(arena_state.allocator(), "MTL::Device", "newBuffer", "NS::UInteger,MTL::ResourceOptions");
    try std.testing.expectEqualStrings(
        "cpp:class/MTL::Device/method/newBuffer(NS::UInteger,MTL::ResourceOptions)",
        id,
    );
}

test "normalize lowercases" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "mtl::device::newbuffer",
        try normalize(arena_state.allocator(), "MTL::Device::newBuffer"),
    );
}
