# AGENTS.md

Guidance for building **metaldoc** (the tool). This is distinct from the
`AGENTS.md` that `metaldoc init` *generates* for downstream Metal projects — see
`metaldoc-design.md` → "Agent Integration".

metaldoc is a local, deterministic Metal symbol resolver modeled on `zigdoc`. It
parses headers (it never calls Metal) and emits provenance-tagged JSON an agent
can trust. Read `metaldoc-design.md` before making design decisions.

## Project shape (planned)

- Implemented in **Zig**.
- Host/metal-cpp + ObjC parsing via **libclang** (stable C API) through
  `@cImport`. Avoid the `clang -ast-dump=json` format — it is unstable across
  versions.
- MSL parsing likely shells out to `xcrun metal -x metal ... -Xclang -ast-dump=json`
  (Metal dialect needs the toolchain's clang). Verify whether the Metal toolchain
  ships a usable libclang before committing.
- Build order: (1) metal-cpp, (2) MSL stdlib, (3) ObjC enrichment joined on
  selector.

## Zig Development

Use `zigdoc` to discover current APIs for the Zig standard library and any
third-party dependencies before coding.

```bash
zigdoc std.fs
zigdoc std.json.Stringify
zigdoc std.process.Child
```

## Current Zig Patterns

**ArrayList:**
```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap (default to unmanaged):**
```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**main signature (gives you an arena + Io for free):**
```zig
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena); // []const [:0]const u8
    ...
}
```
(`std.process.argsAlloc` / `std.os.argv` are gone in 0.16.)

**stdout/stderr writer (0.16: `std.Io.File`, and `.writer` needs the `Io`):**
```zig
var buf: [4096]u8 = undefined;
var stdout = std.Io.File.stdout().writer(io, &buf);
const w = &stdout.interface; // *std.Io.Writer
try w.print("hello {s}\n", .{"world"});
try w.flush();
```
Note: `std.ArrayList` has no `.print` (use `appendSlice`/`append` or an
`std.Io.Writer.Allocating`); `std.mem.trimRight` is now `std.mem.trimEnd`.

**build.zig executable:**
```zig
b.addExecutable(.{
    .name = "metaldoc",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing (the machine-readable contract):**
```zig
var jw: std.json.Stringify = .{
    .writer = w, // *std.Io.Writer (from a File writer or Allocating writer)
    // emit_null_optional_fields=false lets one envelope struct serve
    // resolved/ambiguous/not-found without emitting null keys.
    .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
};
try jw.write(my_struct);
```

**Allocating writer:**
```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = try writer.toOwnedSlice();
```

## metaldoc Conventions

- **Determinism above all.** Identical inputs (same SDK, metal-cpp root, Metal
  toolchain) must produce byte-identical output. Sort everything; never rely on
  hash-map iteration order in output.
- **Provenance on every fact.** No emitted field should lack a source
  (`metal-cpp`, `clang/objc`, `metal-stdlib-<v>`, `curated-msl`).
- **Never guess.** Ambiguous queries return candidate symbol IDs and a non-zero
  exit code, not a best guess.
- **Symbol IDs are stable;** names/aliases live in a separate table that points
  at IDs. The ObjC selector is the cross-surface join key.
- **JSON is the contract.** `--format json` and `--format text` are two renderers
  over one resolved result; the JSON schema is versioned.
- **Never fetch or bundle** metal-cpp, the SDK, or Apple docs. Index the
  project's actual metal-cpp via `--metal-cpp-root` and the installed toolchain.
- Cache keys use content hashes + toolchain/SDK/libclang versions, not mtimes.

## Zig Style

- `camelCase` for functions and methods
- lower-case `snake_case` for variables, parameters, and constants
- `PascalCase` for types, structs, and enums
- prefer `const foo: Type = .{ .field = value };` over `const foo = Type{ .field = value };`
- preferred file order: `//!` module doc comment, `const Self = @This();`, imports, `const log = std.log.scoped(...)`
- pass allocators explicitly; use `errdefer` for cleanup on error
- keep tests inline with the code they cover; register them in `src/main.zig`

## Safety

- Add assertions at API boundaries and state transitions; avoid trivial assertions.
- Keep functions small and push pure computation into helpers.
- Comments should explain why, not what.

## C interop (libclang)

- Wrap libclang in a thin Zig module; do not leak `c.CX*` types into the resolver.
- Free every libclang resource (`clang_disposeString`, `clang_disposeIndex`,
  `clang_disposeTranslationUnit`) with `defer` at the acquisition site.
- Treat libclang as a boundary: convert to metaldoc's own `Symbol`/`NameEntry`
  structs immediately so the rest of the code is clang-version agnostic.
