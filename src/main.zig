//! metaldoc CLI entry point.
//!
//! Commands:
//!   metaldoc lookup <query> [--format json|text] [--metal-cpp-root <path>]
//!   metaldoc search <term>  [--format json|text] [--metal-cpp-root <path>]
//!   metaldoc index [--status] [--format json|text] [--metal-cpp-root <path>]
//!   metaldoc doctor [--format json|text] [--metal-cpp-root <path>]
//!
//! The index covers every method/enum/struct/class under --metal-cpp-root and is
//! cached on disk; exit codes distinguish resolved / ambiguous / not-found /
//! usage / environment failure.

const std = @import("std");
const model = @import("model.zig");
const resolver = @import("resolver.zig");
const render = @import("render.zig");
const cache = @import("cache.zig");
const app = @import("app.zig");
const init_cmd = @import("init.zig");
const msl = @import("msl.zig");
const env = @import("env.zig");

// On this machine metal-cpp is vendored inside the mlx Python package. Never
// bundle or download one — index the project's actual copy.
const default_metal_cpp_root = "/Library/Frameworks/Python.framework/Versions/3.11/lib/python3.11/site-packages/mlx/include/metal_cpp";

const Format = enum { text, json };

const ExitCode = enum(u8) {
    resolved = 0,
    usage = 1,
    ambiguous = 2,
    not_found = 3,
    env_error = 4,
};

const Args = struct {
    positional: ?[]const u8 = null,
    format: Format = .text,
    metal_cpp_root: []const u8 = default_metal_cpp_root,
    status: bool = false,
    force: bool = false,
    print: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var err_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    const err = &stderr.interface;

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;

    if (argv.len < 2) return usage(err);
    const command = argv[1];

    var args: Args = .{};
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= argv.len) return usageErr(err, "--format needs an argument");
            args.format = if (std.mem.eql(u8, argv[i], "json")) .json else if (std.mem.eql(u8, argv[i], "text")) .text else return usageErr(err, "--format must be json or text");
        } else if (std.mem.eql(u8, a, "--metal-cpp-root")) {
            i += 1;
            if (i >= argv.len) return usageErr(err, "--metal-cpp-root needs an argument");
            args.metal_cpp_root = argv[i];
        } else if (std.mem.eql(u8, a, "--status")) {
            args.status = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            args.force = true;
        } else if (std.mem.eql(u8, a, "--print")) {
            args.print = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return usageErr(err, "unknown flag");
        } else if (args.positional == null) {
            args.positional = a;
        } else {
            return usageErr(err, "unexpected argument");
        }
    }

    if (std.mem.eql(u8, command, "lookup")) return runLookup(arena, args, out, err);
    if (std.mem.eql(u8, command, "search")) return runSearch(arena, args, out, err);
    if (std.mem.eql(u8, command, "index")) return runIndex(arena, args, out, err);
    if (std.mem.eql(u8, command, "doctor")) return runDoctor(arena, args, out, err);
    if (std.mem.eql(u8, command, "init")) return runInit(arena, args, out, err);
    if (std.mem.eql(u8, command, "msl")) return runMsl(arena, args, out, err);
    return usage(err);
}

fn runLookup(arena: std.mem.Allocator, args: Args, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const query = args.positional orelse return usageErr(err, "lookup needs a query");
    const r = app.resolveEnv(arena, args.metal_cpp_root) catch return envErr(err);
    const loaded = app.loadIndex(arena, r, false) catch return indexErr(err);

    const result = try resolver.resolve(arena, loaded.index, query);
    switch (args.format) {
        .json => try render.renderJson(arena, result, r.ctx, out),
        .text => try render.renderText(result, out),
    }
    try out.flush();
    return @intFromEnum(switch (result.status) {
        .resolved => ExitCode.resolved,
        .ambiguous => ExitCode.ambiguous,
        .not_found => ExitCode.not_found,
    });
}

fn runSearch(arena: std.mem.Allocator, args: Args, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const term = args.positional orelse return usageErr(err, "search needs a term");
    const r = app.resolveEnv(arena, args.metal_cpp_root) catch return envErr(err);
    const loaded = app.loadIndex(arena, r, false) catch return indexErr(err);

    const hits = try resolver.search(arena, loaded.index, term);
    try render.renderSearch(arena, term, hits, switch (args.format) {
        .json => .json,
        .text => .text,
    }, out);
    try out.flush();
    return @intFromEnum(if (hits.len == 0) ExitCode.not_found else ExitCode.resolved);
}

fn runIndex(arena: std.mem.Allocator, args: Args, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const r = app.resolveEnv(arena, args.metal_cpp_root) catch return envErr(err);

    var health = baseHealth(arena, r);
    if (!args.status) {
        // Force a rebuild and repopulate the cache.
        const loaded = app.loadIndex(arena, r, true) catch return indexErr(err);
        health.symbol_count = loaded.index.symbols.len;
        health.name_count = loaded.index.names.len;
        health.from_cache = loaded.from_cache;
        health.cache_key = loaded.key;
        health.cache_present = true;
    }
    try render.renderHealth(health, switch (args.format) {
        .json => .json,
        .text => .text,
    }, out);
    try out.flush();
    return @intFromEnum(ExitCode.resolved);
}

fn runDoctor(arena: std.mem.Allocator, args: Args, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const r = app.resolveEnv(arena, args.metal_cpp_root) catch return envErr(err);
    try render.renderHealth(baseHealth(arena, r), switch (args.format) {
        .json => .json,
        .text => .text,
    }, out);
    try out.flush();
    return @intFromEnum(ExitCode.resolved);
}

fn runMsl(arena: std.mem.Allocator, args: Args, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const query = args.positional orelse return usageErr(err, "msl needs a query");
    const metal_bin = env.metalBin(arena) orelse {
        try err.writeAll("error: no working Metal toolchain (metaldoc doctor). Install: xcodebuild -downloadComponent MetalToolchain\n");
        try err.flush();
        return @intFromEnum(ExitCode.env_error);
    };
    const toolchain = env.metalToolchainVersion(arena) orelse "unknown";

    const result = msl.resolve(arena, query, metal_bin);
    try render.renderMsl(arena, query, result, toolchain, switch (args.format) {
        .json => .json,
        .text => .text,
    }, out);
    try out.flush();
    return @intFromEnum(switch (result) {
        .not_found => ExitCode.not_found,
        else => ExitCode.resolved,
    });
}

fn runInit(arena: std.mem.Allocator, args: Args, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const target = "AGENTS.md";
    const res = init_cmd.run(arena, target, args.force, args.print, out) catch {
        try err.print("error: could not write {s}\n", .{target});
        try err.flush();
        return @intFromEnum(ExitCode.env_error);
    };
    switch (res) {
        .printed => {},
        .wrote => try out.print("wrote {s} ({d} bytes)\n", .{ target, init_cmd.template.len }),
        .exists => {
            try err.print("error: {s} already exists; use --force to overwrite or --print to view\n", .{target});
            try err.flush();
            return @intFromEnum(ExitCode.usage);
        },
    }
    try out.flush();
    return @intFromEnum(ExitCode.resolved);
}

fn baseHealth(arena: std.mem.Allocator, r: app.Resolved) render.Health {
    const key = cache.computeKey(arena, .{
        .metal_cpp_root = r.ctx.metal_cpp_root,
        .sdk_version = r.ctx.sdk_version,
        .resource_dir = r.resource_dir,
        .metal_toolchain = r.ctx.metal_toolchain,
    });
    const st = cache.status(arena, key);
    return .{
        .ctx = r.ctx,
        .resource_dir = r.resource_dir,
        .sysroot = r.sysroot,
        .cache_dir = cache.dir(arena),
        .cache_key = key,
        .cache_present = st.present,
    };
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.writeAll(
        \\usage:
        \\  metaldoc lookup <query> [--format json|text] [--metal-cpp-root <path>]
        \\  metaldoc search <term>  [--format json|text] [--metal-cpp-root <path>]
        \\  metaldoc index [--status] [--format json|text] [--metal-cpp-root <path>]
        \\  metaldoc msl <query> [--format json|text]
        \\  metaldoc doctor [--format json|text] [--metal-cpp-root <path>]
        \\  metaldoc init [--print] [--force]
        \\
    );
    try err.flush();
    return @intFromEnum(ExitCode.usage);
}

fn usageErr(err: *std.Io.Writer, msg: []const u8) !u8 {
    try err.print("error: {s}\n", .{msg});
    try err.flush();
    return @intFromEnum(ExitCode.usage);
}

fn envErr(err: *std.Io.Writer) !u8 {
    try err.writeAll("error: could not resolve the toolchain (SDK / libclang). Run: metaldoc doctor\n");
    try err.flush();
    return @intFromEnum(ExitCode.env_error);
}

fn indexErr(err: *std.Io.Writer) !u8 {
    try err.writeAll("error: indexing failed; check --metal-cpp-root and SDK (metaldoc doctor)\n");
    try err.flush();
    return @intFromEnum(ExitCode.env_error);
}

test {
    std.testing.refAllDecls(@This());
    _ = model;
    _ = resolver;
    _ = msl;
    _ = @import("msl_builtins.zig");
    _ = @import("golden_test.zig");
    _ = @import("init_test.zig");
    _ = @import("msl_test.zig");
    _ = @import("objc_enrich_test.zig");
}
