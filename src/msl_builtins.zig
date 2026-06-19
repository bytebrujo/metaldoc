//! Curated MSL language-syntax table. Address spaces, entry qualifiers, resource
//! bindings, and built-in attributes are language syntax — they are NOT header
//! symbols, so they cannot come from the stdlib AST. They change rarely; this
//! table is hand-maintained and provenance-tagged `curated-msl`. Everything that
//! *does* live in the headers (functions, types) comes from the AST instead.

const std = @import("std");

pub const Category = enum {
    builtin_attribute,
    address_space,
    entry_qualifier,
    resource_binding,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .builtin_attribute => "Built-in attribute",
            .address_space => "Address space",
            .entry_qualifier => "Entry qualifier",
            .resource_binding => "Resource binding attribute",
        };
    }
};

pub const Builtin = struct {
    /// Canonical name without `[[ ]]` brackets, lowercase, e.g. "thread_position_in_grid".
    name: []const u8,
    category: Category,
    summary: []const u8,
    used_in: []const u8 = "",
    common_type: []const u8 = "",
    related: []const []const u8 = &.{},
};

// zig fmt: off
pub const table = [_]Builtin{
    // --- address spaces ---
    .{ .name = "device", .category = .address_space,
       .summary = "Read-write memory in device address space, shared across the GPU and visible to the host." },
    .{ .name = "constant", .category = .address_space,
       .summary = "Read-only memory optimized for values reused across all threads (e.g. uniforms)." },
    .{ .name = "thread", .category = .address_space,
       .summary = "Per-thread private memory; the default for local variables." },
    .{ .name = "threadgroup", .category = .address_space,
       .summary = "Memory shared by all threads in a threadgroup; lifetime is the threadgroup's execution." },
    .{ .name = "ray_data", .category = .address_space,
       .summary = "Payload memory passed between stages of a ray-tracing pipeline." },
    .{ .name = "object_data", .category = .address_space,
       .summary = "Memory written by an object shader and read by the mesh stage in a mesh pipeline." },

    // --- entry qualifiers ---
    .{ .name = "kernel", .category = .entry_qualifier,
       .summary = "Marks a compute (data-parallel) entry point dispatched over a grid of threads.",
       .used_in = "compute pipelines" },
    .{ .name = "vertex", .category = .entry_qualifier,
       .summary = "Marks a vertex entry point invoked once per vertex.",
       .used_in = "render pipelines" },
    .{ .name = "fragment", .category = .entry_qualifier,
       .summary = "Marks a fragment entry point invoked once per rasterized fragment.",
       .used_in = "render pipelines" },

    // --- resource bindings ---
    .{ .name = "buffer", .category = .resource_binding,
       .summary = "Binds a parameter to a buffer argument-table slot: [[buffer(n)]].",
       .common_type = "device/constant pointer or reference" },
    .{ .name = "texture", .category = .resource_binding,
       .summary = "Binds a parameter to a texture argument-table slot: [[texture(n)]].",
       .common_type = "texture1d/2d/3d/cube<T, access>" },
    .{ .name = "sampler", .category = .resource_binding,
       .summary = "Binds a parameter to a sampler argument-table slot: [[sampler(n)]]." },

    // --- built-in attributes ---
    .{ .name = "thread_position_in_grid", .category = .builtin_attribute,
       .summary = "The current thread's position in the dispatch grid.",
       .used_in = "kernel functions", .common_type = "uint, uint2, or uint3 by dispatch dimensionality",
       .related = &.{ "thread_position_in_threadgroup", "threadgroup_position_in_grid", "threads_per_threadgroup" } },
    .{ .name = "thread_position_in_threadgroup", .category = .builtin_attribute,
       .summary = "The current thread's position within its threadgroup.",
       .used_in = "kernel functions", .common_type = "uint, uint2, or uint3",
       .related = &.{ "thread_position_in_grid", "thread_index_in_threadgroup" } },
    .{ .name = "threadgroup_position_in_grid", .category = .builtin_attribute,
       .summary = "The threadgroup's position in the dispatch grid.",
       .used_in = "kernel functions", .common_type = "uint, uint2, or uint3" },
    .{ .name = "threads_per_threadgroup", .category = .builtin_attribute,
       .summary = "The number of threads per threadgroup for this dispatch.",
       .used_in = "kernel functions", .common_type = "uint, uint2, or uint3" },
    .{ .name = "thread_index_in_threadgroup", .category = .builtin_attribute,
       .summary = "The flattened linear index of the thread within its threadgroup.",
       .used_in = "kernel functions", .common_type = "uint" },
    .{ .name = "position", .category = .builtin_attribute,
       .summary = "Clip-space vertex position (vertex output) or fragment window position (fragment input).",
       .used_in = "vertex output / fragment input", .common_type = "float4" },
    .{ .name = "vertex_id", .category = .builtin_attribute,
       .summary = "Index of the current vertex.", .used_in = "vertex functions", .common_type = "uint" },
    .{ .name = "instance_id", .category = .builtin_attribute,
       .summary = "Index of the current instance in instanced draws.", .used_in = "vertex functions", .common_type = "uint" },
    .{ .name = "stage_in", .category = .builtin_attribute,
       .summary = "Per-fragment interpolated inputs assembled from the prior stage's output.",
       .used_in = "fragment functions" },
};
// zig fmt: on

/// Look up a builtin by query, tolerating `[[ ]]` brackets and a trailing
/// `(n)` index (e.g. "[[buffer(0)]]" -> "buffer").
pub fn lookup(query: []const u8) ?Builtin {
    var name = std.mem.trim(u8, query, " \t\r\n");
    if (std.mem.startsWith(u8, name, "[[") and std.mem.endsWith(u8, name, "]]")) {
        name = std.mem.trim(u8, name[2 .. name.len - 2], " \t");
    }
    if (std.mem.indexOfScalar(u8, name, '(')) |p| name = std.mem.trim(u8, name[0..p], " \t");

    for (table) |b| {
        if (eqlIgnoreCase(b.name, name)) return b;
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

test "lookup tolerates brackets and index" {
    try std.testing.expectEqualStrings("thread_position_in_grid", lookup("[[thread_position_in_grid]]").?.name);
    try std.testing.expectEqualStrings("thread_position_in_grid", lookup("thread_position_in_grid").?.name);
    try std.testing.expectEqualStrings("buffer", lookup("[[buffer(0)]]").?.name);
    try std.testing.expectEqualStrings("kernel", lookup("kernel").?.name);
    try std.testing.expect(lookup("definitely_not_a_builtin") == null);
}
