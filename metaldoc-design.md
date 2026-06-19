# metaldoc Design Notes

## Purpose

`metaldoc` is a proposed command-line documentation and symbol lookup tool for
Apple Metal. Its job is to answer practical questions like:

- What does this Metal symbol do?
- Where is it declared?
- What is the canonical Objective-C selector or C/C++ declaration?
- What is the Swift-imported spelling?
- How does this relate to `metal-cpp`, Rust, Zig, or TypeScript native bridges?
- Is this a host API symbol, a Metal Shading Language symbol, or both?

The goal is not to replace Apple Developer Documentation. The goal is to make
local, terminal-native Metal lookup fast, exact, and useful while coding — and
to emit structured, provenance-tagged output that an AI agent can trust.

It is modeled on [`zigdoc`](https://github.com/rockorager/zigdoc): a local,
on-demand, symbol-scoped resolver that reflects the *installed toolchain* and
the *project's actual dependencies* by construction, rather than a hosted or
bundled documentation mirror.

## Core Idea

Metal is not a single API surface. A useful tool needs to understand at least
three related surfaces:

1. Host API (Objective-C / C in `Metal.framework`)
2. Metal Shading Language (the GPU-side language)
3. C++ host bindings through `metal-cpp`

These surfaces overlap conceptually but differ in syntax, source files, naming,
runtime behavior, and integration path.

### Which surface is canonical?

The earlier framing assumed the Objective-C host API is canonical and everything
else is an alias. That is correct for a Swift/ObjC developer, but **not** for the
primary audience of this tool (C++/Zig hosts and MSL shaders).

For a C++/Zig developer, the *canonical* surface they actually call is
`metal-cpp` (host) and MSL (shaders). The Objective-C selector is the **stable
join key** that links surfaces together, and the ObjC SDK headers are the best
source of human-readable doc prose, availability, and nullability. So the model
is:

```diagram
metal-cpp  ──selector──▶  ObjC SDK headers  ──apinotes──▶  Swift name
 (C++ name,                (doc prose,                      (later)
  signature,               availability,
  overloads,               nullability)
  selector)
```

- **metal-cpp** is canonical for the C++ host surface and supplies the ObjC
  selector for free (see Data Sources).
- **MSL stdlib headers** are canonical for the shader surface.
- **ObjC SDK headers** are the *enrichment* layer joined on the selector key for
  doc text, availability, and (eventually) the Swift importer name.

### Local data sources (verified on this machine)

All three surfaces have rich, structured, local sources:

```text
SDK:            $(xcrun --sdk macosx --show-sdk-path)
                  .../Metal.framework/Headers      (ObjC/C host API + docs)
                  .../Metal.apinotes               (Swift importer names)

metal-cpp:      vendored per-project, e.g. <pkg>/include/metal_cpp/Metal/*.hpp
                  NOT in the SDK — index the project's copy via --metal-cpp-root

MSL stdlib:     <MetalToolchain>/usr/metal/<v>/lib/clang/<v>/include/metal/
                  metal_stdlib umbrella -> ~40 sub-headers
                  (metal_math, metal_geometric, metal_atomic, metal_simdgroup, …)
```

`metal-cpp` is not shipped in the SDK; it is vendored per project (on this
machine it appears inside the `mlx` Python package). Like `zigdoc`, metaldoc must
index the *project's* copy and never bundle or download one.

## Metal Surfaces

### Host API

The host API is how an application controls GPU work. It includes devices,
buffers, textures, command queues, command buffers, encoders, heaps, pipeline
states, libraries, and synchronization primitives.

Canonical Apple SDK declarations are mostly Objective-C protocols/classes plus
C enums, structs, constants, and functions:

```objc
- (nullable id<MTLBuffer>)newBufferWithLength:(NSUInteger)length
                                      options:(MTLResourceOptions)options;
```

Swift imports many of these APIs under different names:

```swift
device.makeBuffer(length: length, options: options)
```

Non-Swift languages usually need the Objective-C selector, the C ABI shape, or a
small shim rather than the Swift spelling.

### Metal Shading Language

Metal Shading Language, or MSL, is the GPU-side language. It is C++-like and is
compiled by the Metal compiler into shader libraries.

Example:

```metal
kernel void add_arrays(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* out [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    out[id] = a[id] + b[id];
}
```

MSL documentation needs to cover concepts that do not exist in the host API,
such as:

- address spaces: `device`, `thread`, `threadgroup`, `constant`
- shader entry attributes: `kernel`, `vertex`, `fragment`
- resource attributes: `[[buffer(n)]]`, `[[texture(n)]]`, `[[sampler(n)]]`
- built-in attributes: `[[thread_position_in_grid]]`
- texture and sampler types
- barriers, atomics, SIMD groups, threadgroups, and memory ordering
- MSL standard library functions and types

### metal-cpp

`metal-cpp` is Apple's C++ wrapper around the Objective-C Metal API. It lets C++
applications use Metal without writing Objective-C message sends directly.

Example shape:

```cpp
MTL::Buffer* buffer =
    device->newBuffer(length, MTL::ResourceStorageModeShared);
```

For C++ developers, `metaldoc` should map between:

- `MTL::Device::newBuffer`
- Objective-C selector `newBufferWithLength:options:`
- Swift spelling `makeBuffer(length:options:)`
- SDK header declaration and availability

## Proposed CLI

Basic lookup:

```bash
metaldoc MTLDevice
metaldoc MTLDevice.makeBuffer
metaldoc MTLTextureDescriptor.pixelFormat
metaldoc newBufferWithLength:options:
```

Surface-specific lookup:

```bash
metaldoc api MTLDevice.makeBuffer
metaldoc cpp MTL::Device::newBuffer
metaldoc msl texture2d.sample
metaldoc msl '[[thread_position_in_grid]]'
metaldoc shader ./Shaders/add.metal add_arrays
```

Search:

```bash
metaldoc search buffer
metaldoc search texture --surface msl
metaldoc search command --lang cpp
```

Language-aware output:

```bash
metaldoc MTLDevice.makeBuffer --lang objc
metaldoc MTLDevice.makeBuffer --lang swift
metaldoc MTLDevice.makeBuffer --lang cpp
metaldoc MTLDevice.makeBuffer --lang rust
metaldoc MTLDevice.makeBuffer --lang zig
metaldoc MTLDevice.makeBuffer --lang typescript
```

Machine-readable output:

```bash
metaldoc MTLDevice.makeBuffer --json
```

Index management:

```bash
metaldoc index
metaldoc index --sdk macosx
metaldoc doctor
metaldoc headers
```

Editor/browser helpers:

```bash
metaldoc open MTLDevice.makeBuffer
metaldoc url MTLDevice.makeBuffer
metaldoc source MTLDevice.makeBuffer
```

## Example Output

For:

```bash
metaldoc MTLDevice.makeBuffer
```

The output could be:

```text
MTLDevice.makeBuffer

Kind:
  Instance method on id<MTLDevice>

Swift:
  func makeBuffer(length: Int, options: MTLResourceOptions = []) -> MTLBuffer?

Objective-C:
  - (nullable id<MTLBuffer>)newBufferWithLength:(NSUInteger)length
                                        options:(MTLResourceOptions)options;

Selector:
  newBufferWithLength:options:

Declared in:
  Metal.framework/Headers/MTLDevice.h:682

Summary:
  Create a buffer by allocating new memory.

Interop:
  Swift uses the imported makeBuffer name.
  Objective-C, Rust, Zig, and native bridges need the selector name.
  C++ metal-cpp exposes this as MTL::Device::newBuffer.
```

For:

```bash
metaldoc msl '[[thread_position_in_grid]]'
```

The output could be:

```text
[[thread_position_in_grid]]

Surface:
  Metal Shading Language

Kind:
  Built-in function attribute

Used in:
  kernel functions

Purpose:
  Provides the current thread position in the dispatch grid.

Common type:
  uint, uint2, or uint3 depending on dispatch dimensionality.

Related:
  [[thread_position_in_threadgroup]]
  [[threads_per_threadgroup]]
  [[threadgroup_position_in_grid]]
```

## Data Sources

Ordered by build sequence (metal-cpp → MSL → ObjC enrichment), not by historical
importance.

### metal-cpp Headers (canonical host surface for v0)

`metal-cpp` is vendored per project, never shipped in the SDK. Index the
project's copy via `--metal-cpp-root` or project include paths. Never bundle or
download one — this mirrors how `zigdoc` reads the project's resolved modules
rather than fetching packages.

The headers are pure C++, mechanical, and highly regular, which makes them the
easiest and most reliable source to parse first. Critically, the inline
definitions embed the **exact Objective-C selector for free**, both as a comment
and via the `_MTL_PRIVATE_SEL(...)` macro:

```cpp
// method: newBufferWithLength:options:
_MTL_INLINE MTL::Buffer* MTL::Device::newBuffer(NS::UInteger length,
                                                MTL::ResourceOptions options)
{
    return Object::sendMessage<MTL::Buffer*>(
        this, _MTL_PRIVATE_SEL(newBufferWithLength_options_), length, options);
}
```

So parsing metal-cpp alone yields:

- the C++ name and full signature
- every overload (e.g. three `newBuffer` overloads on `MTL::Device`)
- the owning C++ class
- the Objective-C selector — the join key to all other surfaces

This gives the C++ ↔ ObjC mapping with **no `apinotes` and no ObjC parsing
required**. The one thing metal-cpp does *not* carry is doc prose; summaries live
in the ObjC SDK headers (see enrichment below).

### MSL Standard Library Headers (canonical shader surface)

The Metal toolchain ships real, parseable MSL headers locally:

```text
$(dirname $(xcrun -f metal))/../metal/<v>/lib/clang/<v>/include/metal/
```

The `metal_stdlib` umbrella includes ~40 sub-headers (`metal_math`,
`metal_geometric`, `metal_atomic`, `metal_simdgroup`, `metal_texture`, …). These
are a genuine symbol source, not a curated guess.

Caveats:

- They are template-heavy C++; AST dumps are large, and overload sets plus
  address-space qualifiers need careful rendering.
- They require the Metal dialect, so parsing means invoking the toolchain's own
  clang (e.g. `xcrun metal -x metal ... -Xclang -ast-dump=json`) rather than the
  stock libclang.
- Built-in attributes (`[[thread_position_in_grid]]`, `[[buffer(n)]]`), address
  spaces, and entry qualifiers are language syntax, not header symbols, so they
  still need a small curated, provenance-tagged table.

Tag every MSL symbol with provenance and toolchain version
(e.g. `metal-stdlib-32023`, `curated-msl`) because the Metal toolchain is a
separate download from Xcode.

### ObjC SDK Headers + Metal.apinotes (enrichment layer, joined on selector)

The active Xcode SDK is the source of the facts metal-cpp lacks: human-readable
doc comments, availability macros, nullability, and the Swift importer name. It
is joined onto the metal-cpp symbol via the Objective-C selector.

#### Local SDK Headers

The active Xcode SDK:

```bash
$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/Metal.framework/Headers
```

This provides:

- Objective-C protocols/classes
- C enums and structs
- method/property declarations
- comments
- availability macros
- header file and line numbers

#### Metal.apinotes (alias/enrichment only, not ground truth)

`Metal.apinotes` maps Objective-C declarations to Swift importer names. For
example it maps the selector `newBufferWithLength:options:` to
`makeBuffer(length:options:)`.

It is an **alias/enrichment layer**, not a complete Swift API model. It gives the
imported *name* (and some metadata such as nullability overrides), but it does
not reconstruct the full Swift surface: overload presentation, default arguments,
error conventions, and option-set rendering are importer heuristics. Swift mode
should report apinotes names and known metadata only, and should not claim to
reconstruct the Swift module interface unless validated through the Swift
compiler. Swift is deferred past v0.

#### Clang for ObjC enrichment

ObjC enrichment parsing uses Clang to extract doc comments, availability,
nullability, and source locations, keyed by selector:

```bash
xcrun clang \
  -x objective-c \
  -fsyntax-only \
  -fparse-all-comments \
  -Xclang -ast-dump=json \
  ...
```

Prefer **libclang** (stable C API) over the `-ast-dump=json` output where
possible: the JSON AST format is explicitly unstable across clang versions, which
is a real risk for a tool that must work across Xcode releases. Because enrichment
parsing can be slow, it is an explicit, cached indexing step.

## Language Modes

### Objective-C

Objective-C mode should show the canonical SDK declaration, selector, owning
class/protocol, nullability, availability, and comments.

This is the foundation for all non-Swift interop.

### Swift

Swift mode should show the Swift importer spelling and explain when it differs
from Objective-C.

This is useful for app code written directly in Swift, but Swift should not be
treated as the canonical API for all languages.

### C++

C++ mode should prioritize `metal-cpp` names:

```cpp
MTL::Device::newBuffer(...)
```

It should also show the Objective-C selector underneath, because `metal-cpp` is
a wrapper over Objective-C Metal.

### Rust

Rust mode should explain that direct use normally happens through one of these
paths:

- a Metal wrapper crate
- Objective-C runtime bindings
- an Objective-C/C/C++ shim exposed through FFI
- a higher-level graphics abstraction if raw Metal is not required

The output should emphasize:

- Objective-C selector
- receiver type
- argument types
- return nullability
- ownership conventions
- whether a wrapper or shim is recommended

### Zig

Zig mode should separate plain C declarations from Objective-C dispatch.

Zig can import many C enums, structs, and constants well, but Objective-C object
messaging still requires runtime calls or a shim.

The output should emphasize:

- selector names
- Objective-C class/protocol ownership
- resource lifetime expectations
- C-compatible structs/enums that can be imported directly
- where a small Objective-C shim would simplify the boundary

### TypeScript

TypeScript cannot call Metal directly in a normal browser or Node runtime.

TypeScript mode should describe bridge strategies instead of pretending raw
Metal objects can be used directly:

- Node native addon through N-API
- Electron native module
- Tauri native side
- Objective-C++/Rust/Zig helper library
- local helper process over IPC
- WebGPU if direct Metal control is not required

The recommended TypeScript interface should be narrow and task-oriented:

```ts
createBuffer(length, options)
compileShader(source)
runComputePipeline(...)
```

rather than exposing raw `MTLDevice`, `MTLBuffer`, and Objective-C selectors
directly.

## Architecture

### Canonical data model

Every indexed declaration has a stable symbol ID independent of how the user
spells the query. Names/aliases are a separate table that points at symbol IDs.
This gives `zigdoc`-style alias following without turning each alias into its own
symbol.

```text
Symbol:
  id            cpp:class/MTL::Device/method/newBuffer(NS::UInteger,MTL::ResourceOptions)
  surface       host-api | msl
  kind          cpp.method | cpp.class | msl.function | msl.attribute | ...
  owner         { kind: class, name: "MTL::Device" }
  signature     "MTL::Buffer* newBuffer(NS::UInteger length, MTL::ResourceOptions options)"
  selector      "newBufferWithLength:options:"   # join key (host surface)
  source        { path, line }
  availability  [ ... ]      # from ObjC enrichment
  doc           { summary }  # from ObjC enrichment
  provenance    [ "metal-cpp", "clang/objc", "metal-stdlib-32023" ]

NameEntry:
  normalized    "mtl::device::newbuffer"
  language      cpp
  kind          method
  symbolId      cpp:class/MTL::Device/method/newBuffer(...)
  provenance    metal-cpp

NameEntry:
  normalized    "newbufferwithlength:options:"
  language      objc
  kind          selector
  symbolId      cpp:class/MTL::Device/method/newBuffer(...)
  provenance    metal-cpp   # selector embedded in metal-cpp header
```

Example symbol IDs:

```text
cpp:class/MTL::Device/method/newBuffer(NS::UInteger,MTL::ResourceOptions)
cpp:enum/MTL::PixelFormat
msl:function/metal::dot
msl:attribute/thread_position_in_grid
host:objc:protocol/MTLDevice/instance-method/newBufferWithLength:options:
```

v0 implements `cpp:*` and `msl:*`. `host:objc:*` IDs exist mainly so the
enrichment join and future Swift/ObjC modes have a stable target.

### Machine-readable contract (first-class)

JSON is a first-class contract, not a `--json` afterthought — this is the main
reason the tool is useful to an agent. Use `--format json|text` (one code path,
two renderers). Every command (`lookup`, `search`, `index --status`, `doctor`)
emits stable JSON with deterministic ordering and per-field provenance.

```json
{
  "query": "MTL::Device::newBuffer",
  "status": "resolved",
  "context": {
    "developerDir": "/Applications/Xcode.app/Contents/Developer",
    "sdkName": "macosx",
    "sdkVersion": "27.0",
    "metalCppRoot": "/path/to/metal_cpp",
    "metalToolchain": "32023",
    "schemaVersion": 1
  },
  "symbol": {
    "id": "cpp:class/MTL::Device/method/newBuffer(NS::UInteger,MTL::ResourceOptions)",
    "surface": "host-api",
    "kind": "cpp.method",
    "owner": { "kind": "class", "name": "MTL::Device" },
    "signature": "MTL::Buffer* newBuffer(NS::UInteger length, MTL::ResourceOptions options)",
    "selector": "newBufferWithLength:options:",
    "source": { "path": ".../Metal/MTLDevice.hpp", "line": 923 },
    "doc": { "summary": "Create a buffer by allocating new memory.", "provenance": "clang/objc" },
    "availability": [],
    "aliases": [
      { "language": "cpp",  "name": "MTL::Device::newBuffer",          "provenance": "metal-cpp" },
      { "language": "objc", "name": "newBufferWithLength:options:",    "provenance": "metal-cpp" }
    ],
    "provenance": ["metal-cpp", "clang/objc"]
  }
}
```

Contract rules:

- exit codes distinguish resolved / ambiguous / not-found / stale-env.
- ambiguous results return candidate symbol IDs (see resolver).
- no prose-only facts: every field carries provenance.
- schema is versioned (`schemaVersion`).

### Indexer

The indexer should:

- detect active Xcode with `xcode-select -p` and SDK with `xcrun --sdk ... --show-sdk-path`
- locate `metal-cpp` via `--metal-cpp-root` / project include paths (never bundle)
- locate the MSL stdlib via the Metal toolchain (`xcrun -f metal`)
- **build order:** (1) metal-cpp C++ symbols + selectors, (2) MSL stdlib symbols
  + curated attribute table, (3) ObjC enrichment joined on selector
- cache by the strengthened key below

### Resolver

The resolver accepts loose queries and maps them to exact symbols via the
NameEntry table, then follows the alias to the canonical symbol.

```text
parse query
  -> detect explicit surface/language syntax (MTL::, [[...]], selector form)
  -> resolve owner if present
  -> resolve member within owner
  -> follow alias to canonical symbol
  -> render canonical symbol + aliases
```

Ranking is **deterministic** (no "popularity"):

1. exact canonical ID
2. exact owner-qualified match
3. exact selector match
4. exact alias match (cpp/objc/apinotes)
5. arity-compatible method/basename match
6. fuzzy/text search

Tie-break by: selected surface/language, then platform availability, then owner
kind, then lexical symbol ID. If still ambiguous, **return candidates — never
guess**:

```text
Ambiguous query: newBuffer

Candidates:
  1. MTL::Device::newBuffer(NS::UInteger, MTL::ResourceOptions)
     selector: newBufferWithLength:options:
     id: cpp:class/MTL::Device/method/newBuffer(NS::UInteger,MTL::ResourceOptions)
  2. MTL::Heap::newBuffer(NS::UInteger, MTL::ResourceOptions)
     selector: newBufferWithLength:options:
     id: cpp:class/MTL::Heap/method/newBuffer(NS::UInteger,MTL::ResourceOptions)
```

### Renderer

The renderer should support:

- compact terminal output
- verbose output
- source snippets
- JSON (see machine-readable contract)
- Markdown
- editor-friendly file references

### Cache

A local cache matters because full parsing can be slow.

Possible cache location:

```text
~/Library/Caches/metaldoc/
```

Timestamps alone are not sufficient for correctness. Cache keys should include:

- `DEVELOPER_DIR` / selected Xcode path
- `xcodebuild -version` build
- SDK name, version, build
- target platform/triple (if used)
- `metal-cpp` root path + content/manifest hash
- Metal toolchain version + MSL header manifest hash
- Clang/libclang version
- relevant header + `Metal.apinotes` content hashes (not just mtimes)
- parse options / preprocessor defines
- metaldoc schema version

Expose the resolved environment via `metaldoc doctor --json` and
`metaldoc index --status --json`, since the "active Xcode" can differ between
shells, CI, and agents. Support `--sdk <name>` and `--sdk-root <path>` overrides.

## Agent Integration (`metaldoc init`)

Like `zigdoc @init`, metaldoc should scaffold agent guidance into a project so AI
agents (and humans) know to consult the tool before writing Metal code. This is
part of v0, not a later feature — it is most of what makes the tool useful to an
agent.

```bash
metaldoc init           # write AGENTS.md (+ optional CLAUDE.md) into CWD
metaldoc init --force   # overwrite existing
metaldoc init --print   # print to stdout instead of writing
```

### Design principle: delegate volatile facts, hardcode stable conventions

zigdoc's generated `AGENTS.md` works because it separates two kinds of guidance:

1. **"Use the tool"** for anything that changes by version — signatures,
   selectors, availability, MSL builtins. Never hardcoded; always looked up.
2. **Stable idioms** that rarely change — hardcoded as patterns.

For Metal, the volatile facts are exact metal-cpp signatures/overloads, ObjC
selectors, availability, and MSL builtins → delegate to `metaldoc lookup` /
`metaldoc msl`. The stable convention that agents reliably get wrong is
**metal-cpp memory ownership** → hardcode it.

### Generated AGENTS.md (sketch)

```markdown
# AGENTS.md

## Metal Development

Use `metaldoc` to discover exact current Metal APIs before coding. Do not guess
signatures, selectors, or MSL builtins — they vary by SDK and Metal toolchain.

    metaldoc lookup MTL::Device::newBuffer
    metaldoc lookup newBufferWithLength:options:
    metaldoc msl thread_position_in_grid
    metaldoc search texture --format json

Prefer `--format json` for structured fields (signature, selector, overloads,
ownership, source location).

## metal-cpp Memory Ownership (READ FIRST)

metal-cpp follows Cocoa Create/Get naming rules:

- Methods named `new*`, `alloc*`, `copy*`, or `*Create*` return an OWNED (+1)
  object — you must release it (`obj->release()`) or wrap it.
- All other methods return a BORROWED (autoreleased) object — do NOT release it;
  call `obj->retain()` only to keep it beyond the current scope.
- Wrap owned objects in `NS::SharedPtr` via `NS::TransferPtr` (+1) or
  `NS::RetainPtr` (+0). Scope frames in `NS::AutoreleasePool`.

## Errors

Metal uses `NS::Error**` out-parameters; a null return means failure — inspect
`err->localizedDescription()`.

## MSL (shaders)

Look up address spaces, attributes, and entry qualifiers:

    metaldoc msl '[[buffer(n)]]'
    metaldoc msl device
    metaldoc msl '[[thread_position_in_grid]]'
```

### Bonus: emit ownership in lookups

Ownership is fully derivable from the metal-cpp method-name prefix
(`new`/`alloc`/`copy`/`*Create*` ⇒ +1 owned, else borrowed). metaldoc should
compute it per symbol and include an `ownership: "owned" | "borrowed"` field in
JSON plus a one-line note in text. This is the single highest-value agent hint
and is deterministic from the parse — no guessing.

## Implementation Language Assessment

### Swift

Swift is a strong choice for a macOS-native CLI.

Pros:

- good fit for Apple platforms
- easy access to Foundation and Process APIs
- good CLI libraries such as Swift ArgumentParser
- natural distribution for macOS developers

Cons:

- parsing Objective-C/C++ directly is not simple
- likely needs to shell out to Clang
- less convenient for low-level indexing than Rust

### Rust

Rust is a strong choice for a polished standalone tool.

Pros:

- excellent CLI ecosystem
- fast indexing and search
- good serialization and cache handling
- strong single-binary distribution story

Cons:

- Apple-specific integration is less natural than Swift
- likely still shells out to `xcrun clang`
- Objective-C and C++ parsing remain external concerns

### Zig

Zig is attractive if the tool wants a small single binary and close alignment
with systems-language workflows.

Pros:

- simple native binary distribution
- good C interop
- thematically close to `zigdoc`

Cons:

- weaker ecosystem for CLI polish and parsing
- still likely depends on Clang output for robust Objective-C parsing

### Python

Python is a good prototype language.

Pros:

- fastest to build the first version
- easy text processing and JSON parsing
- easy experimentation with Clang output

Cons:

- worse distribution story
- slower for large indexes
- easier to let the project become script-like instead of tool-like

### Recommendation: Zig (+ libclang)

Use **Zig**, matching the `zigdoc` lineage and the author's preference. Note that
"Metal is C++" is **not** a reason to write the tool in C++: metaldoc *parses
headers*; it never calls Metal, so the subject language is irrelevant to the
implementation language.

The real decision axis is the clang parsing strategy:

```diagram
shell out to `clang -ast-dump=json` / `xcrun metal -ast-dump=json`
        → language-agnostic → Zig is ideal (matches zigdoc, clean single binary)
        → BUT clang's JSON AST format is explicitly unstable across versions

link libclang (stable C API)
        → callable from Zig via @cImport — the sweet spot for metal-cpp/ObjC

Clang LibTooling (richest AST API)
        → C++ ONLY, heavyweight (link LLVM/Clang) — the only real reason for C++
```

Plan:

- **metal-cpp + ObjC enrichment:** Zig calling **libclang** (stable C API),
  avoiding the fragile JSON-dump format.
- **MSL:** likely shell out to `xcrun metal -x metal ... -Xclang -ast-dump=json`,
  because the Metal dialect needs the toolchain's custom clang. Verify whether
  that toolchain ships a usable libclang before committing.
- Choose **C++** only if you later decide you need LibTooling-grade in-process
  parsing.
- Python remains fine for a one-day spike to inspect AST/header shape, but not
  for the shipped MVP.

## MVP Scope

Resist becoming "Apple Metal docs, all languages, all surfaces" on day one.
Build in this order:

```text
v0 — metal-cpp host surface:
  metaldoc index --metal-cpp-root <path>
  metaldoc lookup <query> [--format json|text]
  metaldoc search <term> [--format json|text]
  metaldoc doctor
  metaldoc init [--force] [--print]   # scaffold AGENTS.md (templates/AGENTS.md.tmpl)
  Data: C++ name, signature, overloads, owning class, embedded ObjC selector,
        derived ownership (+1/borrowed), source file:line.
        JSON contract + symbol IDs.

v1 — MSL shader surface:
  metaldoc msl <query>
  Data: metal_stdlib symbols + curated attribute/address-space table,
        provenance-tagged by toolchain version.

v2 — ObjC enrichment (joined on selector):
  doc prose / summaries, availability, nullability for host-API symbols.
```

Explicit non-goals for v0:

- no fetching or bundling of metal-cpp, the SDK, or Apple docs
- no Swift mode (apinotes) yet
- no Rust / Zig / TypeScript interop modes (these are explanatory guidance, not
  symbol lookup — most hallucination-prone, build last)
- no MetalKit / QuartzCore / Metal Performance Shaders
- no project `.metal` parsing
- no claim of MSL stdlib completeness

## Roadmap / Phasing

Phase by **risk and pipeline depth**, not just by surface. The surface order
(metal-cpp → MSL → ObjC) from MVP Scope is correct, but two disciplines matter
more: spike the unknowns first, and prove one symbol end-to-end before widening.

### Phase 0 — Spikes (throwaway; retire make-or-break risks)

The architecture rests on two unverified assumptions. Prove them before
committing.

- **Zig + libclang:** drive libclang via `@cImport`, parse the real
  `MTLDevice.hpp`, and recover `MTL::Device::newBuffer` **plus its selector**.
  The selector is not on the class-decl one-liners; it lives in the inline-impl
  section as the `// method: newBufferWithLength:options:` comment /
  `_MTL_PRIVATE_SEL(...)`. Confirm extraction via libclang comments or a token
  scan.
- **MSL mechanism:** confirm `xcrun metal -x metal -Xclang -ast-dump=json`
  yields usable output, and whether the Metal toolchain ships a usable libclang.

*Done when:* a throwaway prints
`MTL::Device::newBuffer(...) → newBufferWithLength:options:` from the real
header, and the MSL parsing mechanism is chosen.

### Phase 1 — Contract + vertical slice (one symbol, full depth)

Lock `Symbol` / `NameEntry`, the symbol-ID scheme, and JSON schema v1. Build the
thinnest possible pipeline: index one class → `lookup` → both renderers, with
determinism, provenance, and derived ownership.

*Done when:* `metaldoc lookup MTL::Device::newBuffer --format json|text` works
against the vendored header, with a golden test.

### Phase 2 — metal-cpp breadth + persistence

All headers under `--metal-cpp-root` (classes, methods, overloads, enums,
structs); on-disk cache with the strengthened key; deterministic resolver with
ambiguity candidates + alias table; `search`, `index`, `doctor`.

*Done when:* full metal-cpp coverage; ambiguous `newBuffer` returns candidates;
cache hit skips reparse.

### Phase 3 — `metaldoc init` (cheap, high leverage)

Embed `templates/AGENTS.md.tmpl`; support `--print` / `--force`. Ship here so the
agent angle lands early.

*Done when:* `metaldoc init` writes `AGENTS.md`; CI snapshot test passes.

### Phase 4 — MSL (`v1`)

`metal_stdlib` symbol extraction via the chosen mechanism + curated
attribute/address-space table, provenance- and version-tagged. `metaldoc msl`.

*Done when:* MSL lookups resolve builtins (e.g. `[[thread_position_in_grid]]`)
and a stdlib function (e.g. `metal::dot`).

### Phase 5 — ObjC enrichment (`v2`)

Parse `Metal.framework` headers + `Metal.apinotes`; **join on the selector** to
add doc summaries, availability, nullability (and later the Swift importer name)
to existing symbols.

*Done when:* host-API lookups show summary + availability sourced from
`clang/objc`.

## Later Features

Useful future additions:

- MSL built-in symbol index
- project-local `.metal` file indexing
- shader entry-point inspection
- `metal-cpp` mapping
- Rust/Zig binding hints
- TypeScript bridge recommendations
- Apple Developer Documentation URLs
- Xcode Quick Help integration if accessible
- examples from local sample projects
- diagnostics explainer for `xcrun metal` compiler errors
- `metaldoc doctor` to inspect Xcode, SDK, Metal Toolchain, and cache health

## Risks and Hard Parts

The hardest parts are:

- handling overloaded or similarly named symbols (return candidates, don't guess)
- parsing template-heavy MSL stdlib signatures cleanly
- insulating from the unstable clang JSON AST format (prefer libclang)
- joining metal-cpp ↔ ObjC reliably on the selector across SDK versions
- extracting ObjC comments and availability macros reliably (enrichment phase)
- keeping the MSL curated attribute table accurate per toolchain version
- deciding when to generate code hints versus only explaining interop shape

The tool should start conservative. It should prefer exact declarations,
signatures, selectors, and source locations over speculative generated bindings.

## Assessment

`metaldoc` is feasible and potentially useful. The best version is not a terminal
mirror of Apple docs. It is a deterministic, local Metal symbol resolver — built
metal-cpp-first for C++/Zig developers, with MSL second and ObjC as an enrichment
layer joined on the selector — emitting JSON an agent can trust.

The most valuable first release would be:

```text
Given a symbol, tell me exactly what it is (C++ signature + overloads), its
Objective-C selector, where it is declared (file:line), and emit it as
provenance-tagged JSON — reflecting the project's actual metal-cpp and the
installed toolchain.
```

