//! MSL (shader surface) resolution. Two sources, both provenance-tagged:
//!  - curated language syntax (attributes/address-spaces/qualifiers) → msl_builtins
//!  - metal_stdlib functions, extracted on demand by shelling out to the Metal
//!    driver's JSON AST dump (the toolchain ships no libclang, so this is the
//!    only mechanism — confirmed in spike/FINDINGS.md). Tagged metal-stdlib-<v>.

const std = @import("std");
const builtins = @import("msl_builtins.zig");
const env = @import("env.zig");

const log = std.log.scoped(.msl);

pub const Function = struct {
    /// Fully-qualified name, e.g. "metal::dot".
    name: []const u8,
    /// Distinct overload signatures (clang `qualType`), sorted.
    overloads: []const []const u8,
};

pub const Result = union(enum) {
    builtin: builtins.Builtin,
    function: Function,
    not_found: void,
};

/// Resolve an MSL query: curated builtins first (they are exact language
/// syntax), then the stdlib via the AST dump.
pub fn resolve(arena: std.mem.Allocator, query: []const u8, metal_bin: []const u8) Result {
    if (builtins.lookup(query)) |b| return .{ .builtin = b };

    const fname = functionName(query);
    if (!isIdentifier(fname)) return .not_found;

    const overloads = stdlibOverloads(arena, metal_bin, fname) catch |err| {
        log.warn("stdlib lookup failed: {s}", .{@errorName(err)});
        return .not_found;
    };
    if (overloads.len == 0) return .not_found;
    return .{ .function = .{
        .name = std.fmt.allocPrint(arena, "metal::{s}", .{fname}) catch fname,
        .overloads = overloads,
    } };
}

/// Strip a leading `metal::` and reduce any `a::b` / `a.b` to the last segment.
fn functionName(query: []const u8) []const u8 {
    var q = std.mem.trim(u8, query, " \t\r\n");
    if (std.mem.lastIndexOf(u8, q, "::")) |i| q = q[i + 2 ..];
    if (std.mem.lastIndexOfScalar(u8, q, '.')) |i| q = q[i + 1 ..];
    return q;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

/// Invoke the Metal driver, filter the AST to `name`, and collect the distinct
/// signatures of every `FunctionDecl` named `name`.
fn stdlibOverloads(arena: std.mem.Allocator, metal_bin: []const u8, name: []const u8) ![]const []const u8 {
    const tu = "/tmp/metaldoc_msl_tu.metal";
    try writeFile(arena, tu, "#include <metal_stdlib>\nusing namespace metal;\n");

    const cmd = try std.fmt.allocPrint(
        arena,
        "{s} -x metal -std=metal3.2 -fsyntax-only -Xclang -ast-dump=json -Xclang -ast-dump-filter={s} {s} 2>/dev/null",
        .{ metal_bin, name, tu },
    );
    const json = env.capture(arena, cmd) orelse return &.{};

    var sigs: std.StringArrayHashMapUnmanaged(void) = .empty;
    var it = topLevelObjects(json);
    while (it.next()) |obj| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, obj, .{}) catch continue;
        try collect(arena, parsed, name, &sigs);
    }

    var out = try arena.alloc([]const u8, sigs.count());
    for (sigs.keys(), 0..) |k, i| out[i] = k;
    std.mem.sortUnstable([]const u8, out, {}, lessStr);
    return out;
}

/// Recursively gather `qualType`s of FunctionDecls named `name`.
fn collect(arena: std.mem.Allocator, node: std.json.Value, name: []const u8, out: *std.StringArrayHashMapUnmanaged(void)) !void {
    switch (node) {
        .object => |o| {
            const is_fn = if (o.get("kind")) |k| k == .string and std.mem.eql(u8, k.string, "FunctionDecl") else false;
            const named = if (o.get("name")) |n| n == .string and std.mem.eql(u8, n.string, name) else false;
            if (is_fn and named) {
                if (o.get("type")) |t| switch (t) {
                    .object => |to| if (to.get("qualType")) |q| switch (q) {
                        .string => |s| try out.put(arena, s, {}),
                        else => {},
                    },
                    else => {},
                };
            }
            if (o.get("inner")) |inner| try collect(arena, inner, name, out);
        },
        .array => |a| {
            for (a.items) |item| try collect(arena, item, name, out);
        },
        else => {},
    }
}

/// Iterator over the concatenated top-level `{...}` objects in clang's
/// `-ast-dump-filter` output (it emits one root per matching decl, not an
/// array). String-aware so braces inside JSON strings don't break nesting.
const TopLevelObjects = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *TopLevelObjects) ?[]const u8 {
        var depth: usize = 0;
        var start: ?usize = null;
        var in_str = false;
        var esc = false;
        while (self.i < self.s.len) : (self.i += 1) {
            const ch = self.s[self.i];
            if (in_str) {
                if (esc) {
                    esc = false;
                } else if (ch == '\\') {
                    esc = true;
                } else if (ch == '"') {
                    in_str = false;
                }
                continue;
            }
            switch (ch) {
                '"' => in_str = true,
                '{' => {
                    if (depth == 0) start = self.i;
                    depth += 1;
                },
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        const obj = self.s[start.? .. self.i + 1];
                        self.i += 1;
                        return obj;
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

fn topLevelObjects(s: []const u8) TopLevelObjects {
    return .{ .s = s };
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const c = @cImport({
    @cInclude("stdio.h");
});

fn writeFile(arena: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try arena.dupeZ(u8, path);
    const f = c.fopen(z.ptr, "w");
    if (f == null) return error.WriteFailed;
    defer _ = c.fclose(f);
    if (data.len > 0 and c.fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
}

test "functionName strips metal:: and segments" {
    try std.testing.expectEqualStrings("dot", functionName("metal::dot"));
    try std.testing.expectEqualStrings("dot", functionName("dot"));
    try std.testing.expectEqualStrings("sample", functionName("texture2d.sample"));
}

test "topLevelObjects splits concatenated roots, ignoring braces in strings" {
    var it = topLevelObjects("{\"a\":\"}{\"}{\"b\":1}");
    try std.testing.expectEqualStrings("{\"a\":\"}{\"}", it.next().?);
    try std.testing.expectEqualStrings("{\"b\":1}", it.next().?);
    try std.testing.expect(it.next() == null);
}
