# metaldoc

<https://github.com/bytebrujo/metaldoc>

A local, deterministic command-line symbol resolver for Apple Metal — built
metal-cpp-first for C++/Zig developers, with MSL shader lookup and Objective-C
enrichment. It reflects the *installed* toolchain and the *project's actual*
metal-cpp by parsing headers; it never bundles, fetches, or mirrors Apple docs.

Modeled on [`zigdoc`](https://github.com/rockorager/zigdoc): on-demand,
symbol-scoped, and JSON-first so an AI agent can trust the output.

## What it answers

- What is the exact C++ signature and every overload of a Metal symbol?
- What is its Objective-C selector (the cross-surface join key)?
- Is the returned object owned (+1) or borrowed? (the most common metal-cpp bug)
- Where is it declared (`file:line`), and what's its availability + doc summary?
- What does an MSL builtin or `metal_stdlib` function look like?

Every emitted field carries provenance (`metal-cpp`, `clang/objc`,
`metal-stdlib-<v>`, `curated-msl`). Output is deterministic; ambiguous queries
return candidate symbol IDs and a non-zero exit code rather than guessing.

## Commands

```bash
metaldoc lookup MTL::Device::newBuffer                 # by C++ name (ambiguous -> candidates)
metaldoc lookup 'MTL::Device::newBuffer(NS::UInteger, MTL::ResourceOptions)'
metaldoc lookup newBufferWithLength:options:           # by ObjC selector
metaldoc search texture --format json                  # substring discovery
metaldoc msl '[[thread_position_in_grid]]'             # curated MSL builtin
metaldoc msl metal::dot                                # metal_stdlib function (overloads)
metaldoc index [--status]                              # build/inspect the cache
metaldoc doctor                                        # resolved SDK / toolchain / cache health
metaldoc init [--print] [--force]                      # scaffold AGENTS.md for agents
```

`--format json|text` on every query; JSON is a versioned, provenance-tagged
contract. Exit codes: `0` resolved, `2` ambiguous, `3` not-found, `4`
environment failure.

### Example

```text
$ metaldoc lookup 'MTL::Device::newBuffer(NS::UInteger, MTL::ResourceOptions)'
MTL::Device::newBuffer(NS::UInteger length, MTL::ResourceOptions options)

Kind:       Instance method on MTL::Device
Signature:  MTL::Buffer * newBuffer(NS::UInteger length, MTL::ResourceOptions options)
Selector:   newBufferWithLength:options:
Ownership:  owned (+1) — release it or wrap in NS::SharedPtr (NS::TransferPtr)
Summary:    Create a buffer by allocating new memory.
Availability: ios 8.0 macos 10.11
Declared:   Metal/MTLDevice.hpp:923
Provenance: metal-cpp, clang/objc
```

## How it works

Three Metal surfaces, joined on the Objective-C selector:

1. **metal-cpp** (canonical host surface) — parsed via **libclang**. Yields the
   C++ name, full signature, overloads, owning class, derived ownership, and the
   embedded ObjC selector.
2. **MSL** (shaders) — `metal_stdlib` functions extracted on demand from the
   Metal driver's JSON AST dump (the toolchain ships no libclang), plus a
   curated table of language syntax (attributes, address spaces, qualifiers).
3. **ObjC SDK headers** (enrichment) — parsed with libclang and joined on the
   selector to add doc summaries, availability, and nullability.

The resolved index is cached on disk (`~/Library/Caches/metaldoc/`), keyed by a
content hash of the headers plus SDK / libclang / toolchain versions, so a warm
run skips the reparse and the cache invalidates correctly when anything changes.

## Build

Requires [Zig](https://ziglang.org) 0.16, an Xcode SDK, and LLVM/libclang
(Homebrew `llvm@21`). metal-cpp is vendored per project — point at it with
`--metal-cpp-root <path>`.

```bash
zig build           # produces zig-out/bin/metaldoc
zig build test      # unit + golden + MSL + enrichment tests
zig build run -- lookup MTL::Device::newBuffer
```

> Implementation note: libclang paths and the metal-cpp root are currently
> pinned for the author's machine (see `build.zig` / `src/env.zig`); generalizing
> discovery and adding a `--developer-dir` flag is the main TODO before wider use.

## Status

Implemented end-to-end: metal-cpp host surface, MSL shader lookup, ObjC
enrichment, on-disk cache, and `init` scaffolding. Not yet implemented (by
design): Swift mode via `apinotes`, project `.metal` indexing, and
Rust/Zig/TypeScript interop hints. See [`metaldoc-design.md`](metaldoc-design.md).
