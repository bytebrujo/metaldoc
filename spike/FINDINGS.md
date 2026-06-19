# Phase 0 Spike — Findings

Throwaway spikes to retire the two make-or-break risks from
`metaldoc-design.md` → "Phase 0 — Spikes". Both are **retired**.

Environment used:
- Zig 0.16.0
- Homebrew LLVM 21 (`/opt/homebrew/opt/llvm@21`) — has `libclang.dylib` + `clang-c/` headers
- Xcode-beta SDK `MacOSX27.0.sdk`
- Metal toolchain `32023` (`MetalToolchain-v27.1.5194.15`)
- metal-cpp vendored in the `mlx` Python package

## Risk 1 — Zig + libclang recovers metal-cpp signatures *and* selectors ✅

`phase0/` drives libclang from Zig via `@cImport` and, for the real
`MTLDevice.hpp`, recovers every `MTL::Device::newBuffer` overload with its C++
signature, return type, **Objective-C selector** (the cross-surface join key),
derived ownership, and `file:line` — on a clean parse (0 diagnostics).

```
[1] Device::newBuffer(NS::UInteger, MTL::ResourceOptions)
     selector:  newBufferWithLength:options:            ownership: owned (+1)   MTLDevice.hpp:923
[2] Device::newBuffer(const void *, NS::UInteger, MTL::ResourceOptions)
     selector:  newBufferWithBytes:length:options:      ownership: owned (+1)   MTLDevice.hpp:929
[3] Device::newBuffer(const void *, NS::UInteger, MTL::ResourceOptions, void (^)(void *, NS::UInteger))
     selector:  newBufferWithBytesNoCopy:length:options:deallocator:  owned (+1)  MTLDevice.hpp:935
```

Run: `cd phase0 && zig build run`

### Non-obvious gotchas discovered (carry into the real implementation)

1. **libclang needs an explicit `-resource-dir`.** Homebrew LLVM does not embed
   its builtin-header path, so `objc/runtime.h` fails with `'stdarg.h' file not
   found`. Pass `-resource-dir /opt/homebrew/opt/llvm@21/lib/clang/<v>`. The real
   tool must derive this from the libclang it links (don't hardcode the version).

2. **Never parse a metal-cpp header as clang's primary input.** metal-cpp headers
   `#include` themselves (e.g. `MTLDevice.hpp` line 30 includes `MTLDevice.hpp`).
   `#pragma once` does *not* suppress this for the main file, so the TU parses the
   header twice → redefinition errors + duplicate overloads. Fix: parse a
   synthetic TU (`#include "Metal/MTLDevice.hpp"`) passed as an in-memory unsaved
   file, so the header is entered through the normal include path and pragma-once
   applies. Clean parse, exactly one cursor per overload.

3. **Selector recovery cannot use `clang_tokenize` or the cursor extent.** The
   inline definitions start with the `_MTL_INLINE` macro, so the cursor extent's
   start is a macro-expansion location: `clang_tokenize` returns **0 tokens** and
   `clang_getSpellingLocation` on the extent gives unusable offsets. What *is*
   reliable is the method-name location (`clang_getCursorLocation`). Recover the
   selector by reading the header source and scanning forward from the name offset
   to the first `_MTL_PRIVATE_SEL(accessor)`, then mapping `accessor → "selector"`
   via the `_MTL_PRIVATE_DEF_SEL(...)` table in `MTLHeaderBridge.hpp` (1174
   accessors on this toolchain). The `// method: <selector>` comments are a weaker
   fallback.

## Risk 2 — MSL parsing mechanism chosen ✅

`msl/probe.sh` confirms:

1. **The Metal toolchain ships no libclang** (no `libclang.dylib`, no `clang-c/`).
   So MSL cannot reuse Risk 1's in-process libclang path — we **must shell out**
   to the toolchain's own driver, which speaks the Metal dialect.

2. **`xcrun metal -x metal -std=metal3.2 -fsyntax-only -Xclang -ast-dump=json`**
   produces valid, parseable JSON (~161 KB for a small kernel); `add_arrays` and
   `MetalKernelAttr` are present.

3. **Stdlib symbols are enumerable.** Default `-ast-dump=json` prunes unused
   system-header decls, but `-Xclang -ast-dump-filter=<name>` over an
   `#include <metal_stdlib>`-only TU surfaces full overload sets — e.g. 12
   `FunctionDecl`s for `dot` (half2/3/4, float2/3/4, …) with signatures.

Run: `sh msl/probe.sh`

### Caveat (accepted, MSL-only)

The clang JSON AST format is explicitly **unstable across versions**. This risk
is confined to MSL (Risk 1 uses the stable libclang C API). Tag every MSL symbol
with the toolchain version (`metal-stdlib-32023`) and treat the JSON shape as a
parser we may need to adjust per toolchain release.
