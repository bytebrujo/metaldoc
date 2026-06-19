//! Environment discovery: the "active Xcode" can differ between shells, CI, and
//! agents, so we resolve it at runtime rather than baking it in. Uses libc
//! `popen` (we link libc for libclang anyway), which is stable across the
//! std.fs/Io churn. Best-effort: a failed probe yields "unknown" rather than
//! aborting, and the values are surfaced verbatim in the JSON `context`.

const std = @import("std");
const render = @import("render.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

const log = std.log.scoped(.env);

// TODO(phase2): derive the resource dir from the libclang we link, instead of
// assuming Homebrew LLVM. The spike pinned these; doctor will validate them.
pub const llvm_prefix = "/opt/homebrew/opt/llvm@21";

// On this machine the stable `/Applications/Xcode.app` (SDK 26.2) does NOT carry
// the Metal toolchain, but Xcode-beta (SDK 27.0) does and matches the installed
// toolchain's darwin27 target. Prefer it unless DEVELOPER_DIR overrides.
const preferred_developer_dir = "/Applications/Xcode-beta.app/Contents/Developer";

pub fn gather(arena: std.mem.Allocator, metal_cpp_root: []const u8) render.Context {
    return .{
        .developer_dir = developerDir(arena),
        .sdk_name = "macosx",
        .sdk_version = xcrun(arena, "--sdk macosx --show-sdk-version") orelse "unknown",
        .metal_cpp_root = metal_cpp_root,
        .metal_toolchain = metalToolchainVersion(arena) orelse "unknown",
    };
}

/// The Developer dir all `xcrun` probes run under:
///   1. an explicit `DEVELOPER_DIR` (respect the operator),
///   2. else Xcode-beta if present (SDK 27 + matching Metal toolchain here),
///   3. else whatever `xcode-select -p` reports.
pub fn developerDir(arena: std.mem.Allocator) []const u8 {
    if (c.getenv("DEVELOPER_DIR")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return arena.dupe(u8, s) catch s;
    }
    if (pathExists(arena, preferred_developer_dir)) return preferred_developer_dir;
    return capture(arena, "xcode-select -p") orelse "/Applications/Xcode.app/Contents/Developer";
}

pub fn sdkPath(arena: std.mem.Allocator) ?[]const u8 {
    return xcrun(arena, "--sdk macosx --show-sdk-path");
}

/// The `lib/clang/<v>` directory that holds libclang's builtin headers
/// (`stdarg.h`). Required as `-resource-dir`, or the parse fails to find it.
pub fn resourceDir(arena: std.mem.Allocator) ?[]const u8 {
    const dir = capture(arena, "ls -d " ++ llvm_prefix ++ "/lib/clang/*/ 2>/dev/null | head -1") orelse return null;
    return std.mem.trimEnd(u8, dir, "/");
}

/// Path to a *working* `metal` driver. `xcrun metal` can resolve to a path that
/// fails at runtime ("missing Metal Toolchain") when the active Xcode isn't the
/// one the toolchain was downloaded for — the component is a separate download
/// and is cryptex-mounted. So we verify `xcrun -f metal` actually runs, and
/// otherwise fall back to the mounted Metal.xctoolchain.
pub fn metalBin(arena: std.mem.Allocator) ?[]const u8 {
    if (xcrun(arena, "-f metal 2>/dev/null")) |p| {
        const probe = std.fmt.allocPrint(arena, "{s} --version >/dev/null 2>&1 && echo ok", .{p}) catch return null;
        if (capture(arena, probe)) |ok| {
            if (std.mem.eql(u8, ok, "ok")) return p;
        }
    }
    return capture(arena, "ls /var/run/com.apple.security.cryptexd/mnt/*MetalToolchain*/Metal.xctoolchain/usr/bin/metal 2>/dev/null | head -1");
}

/// The Metal stdlib/toolchain version (e.g. "32023"), via the working driver.
pub fn metalToolchainVersion(arena: std.mem.Allocator) ?[]const u8 {
    const m = metalBin(arena) orelse return null;
    const cmd = std.fmt.allocPrint(arena, "{s} --version 2>/dev/null | sed -n 's/.*version \\([0-9]*\\).*/\\1/p' | head -1", .{m}) catch return null;
    return capture(arena, cmd);
}

/// Run `xcrun <sub>` under the selected Developer dir, so SDK/metal resolution
/// follows the chosen Xcode rather than the system default.
fn xcrun(arena: std.mem.Allocator, sub: []const u8) ?[]const u8 {
    const cmd = std.fmt.allocPrint(arena, "DEVELOPER_DIR={s} xcrun {s}", .{ developerDir(arena), sub }) catch return null;
    return capture(arena, cmd);
}

fn pathExists(arena: std.mem.Allocator, path: []const u8) bool {
    const z = arena.dupeZ(u8, path) catch return false;
    return c.access(z.ptr, c.F_OK) == 0;
}

/// Run `cmd` via the shell, capture stdout, and return it trimmed (null on
/// failure or empty output).
pub fn capture(arena: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
    const cmd_z = arena.dupeZ(u8, cmd) catch return null;
    const f = c.popen(cmd_z.ptr, "r");
    if (f == null) return null;
    defer _ = c.pclose(f);

    var list: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        list.appendSlice(arena, buf[0..n]) catch return null;
    }
    const trimmed = std.mem.trim(u8, list.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}
