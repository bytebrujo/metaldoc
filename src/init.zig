//! `metaldoc init` — scaffold agent guidance into a project so AI agents (and
//! humans) consult metaldoc before writing Metal code. The template is embedded
//! at build time from `templates/AGENTS.md.tmpl`; it separates volatile facts
//! (signatures, selectors, MSL builtins → looked up) from stable conventions
//! (metal-cpp ownership → hardcoded).

const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
});

/// The generated AGENTS.md, baked in at build time. Registered as a named embed
/// import in build.zig because the template lives outside the module's package.
pub const template = @embedFile("agents_template");

pub const Result = enum { wrote, printed, exists };

/// Print the template, or write it to `target` (refusing to clobber unless
/// `force`). Returns what happened so the caller can choose the message + exit.
pub fn run(arena: std.mem.Allocator, target: []const u8, force: bool, print: bool, out: *std.Io.Writer) !Result {
    if (print) {
        try out.writeAll(template);
        return .printed;
    }
    if (!force and fileExists(arena, target)) return .exists;
    try writeFile(arena, target, template);
    return .wrote;
}

pub fn fileExists(arena: std.mem.Allocator, path: []const u8) bool {
    const z = arena.dupeZ(u8, path) catch return false;
    const f = c.fopen(z.ptr, "r");
    if (f == null) return false;
    _ = c.fclose(f);
    return true;
}

fn writeFile(arena: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try arena.dupeZ(u8, path);
    const f = c.fopen(z.ptr, "w");
    if (f == null) return error.WriteFailed;
    defer _ = c.fclose(f);
    if (data.len > 0 and c.fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
}
